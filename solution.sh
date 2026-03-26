#!/bin/bash
set -e

export KUBECONFIG=/home/ubuntu/.kube/config

KEYCLOAK_URL="http://keycloak.devops.local:8080"
GLITCHTIP_URL="http://glitchtip.devops.local"

###############################################
# HELPER: Get Keycloak admin token
###############################################
get_kc_token() {
  curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "grant_type=password" \
    -d "username=admin" \
    -d "password=admin123" | jq -r '.access_token'
}

###############################################
# STEP 1: Delete the enforcer CronJob
# Must be done FIRST to prevent re-corruption
###############################################
echo "[solution] Step 1: Finding and deleting enforcer CronJobs..."

# Discover CronJobs in keycloak namespace that manipulate group memberships
kubectl get cronjobs -n keycloak -o name | while read -r cj; do
  CJ_NAME=$(echo "$cj" | sed 's|cronjob.batch/||')
  # Check if the CronJob relates to group reconciliation
  CJ_SPEC=$(kubectl get "$cj" -n keycloak -o json 2>/dev/null)
  if echo "$CJ_SPEC" | grep -qi "reconcil\|group\|membership\|glitchtip"; then
    echo "[solution] Deleting suspicious CronJob: ${CJ_NAME}"
    kubectl delete cronjob "${CJ_NAME}" -n keycloak --wait=true
  fi
done

# Also kill any running jobs from the CronJob
kubectl get jobs -n keycloak -o name 2>/dev/null | while read -r job; do
  JOB_SPEC=$(kubectl get "$job" -n keycloak -o json 2>/dev/null)
  if echo "$JOB_SPEC" | grep -qi "reconcil\|realm-config"; then
    kubectl delete "$job" -n keycloak --wait=false 2>/dev/null || true
  fi
done

echo "[solution] Enforcer CronJob removed."

###############################################
# STEP 2: Fix NetworkPolicy
# GlitchTip must be able to reach Keycloak
###############################################
echo "[solution] Step 2: Fixing NetworkPolicy..."

# Discover the egress policy in glitchtip namespace
NP_JSON=$(kubectl get networkpolicy glitchtip-egress-policy -n glitchtip -o json 2>/dev/null || echo "{}")

if echo "$NP_JSON" | jq -e '.metadata.name' >/dev/null 2>&1; then
  # Fix the keycloak namespace selector — remove the extra label requirement
  # The policy requires sso-tier: identity which keycloak namespace doesn't have
  # Replace with just the namespace name selector
  kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: glitchtip-egress-policy
  namespace: glitchtip
spec:
  podSelector:
    matchLabels:
      app: glitchtip
  policyTypes:
  - Egress
  egress:
  # Allow DNS
  - to: []
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  # Allow internal glitchtip namespace
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: glitchtip
  # Allow traffic to keycloak namespace (fixed: removed sso-tier label requirement)
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: keycloak
EOF
fi

echo "[solution] NetworkPolicy fixed."

# Verify connectivity
echo "[solution] Verifying GlitchTip → Keycloak connectivity..."
GT_POD=$(kubectl get pods -n glitchtip -l app=glitchtip,component=web -o jsonpath='{.items[0].metadata.name}')

for i in $(seq 1 30); do
  if kubectl exec -n glitchtip "${GT_POD}" -- curl -sf "http://keycloak.devops.local:8080/realms/master" >/dev/null 2>&1; then
    echo "[solution] Connectivity confirmed."
    break
  fi
  sleep 2
done

###############################################
# STEP 3: Fix Keycloak group memberships
# Remove charlie, diana, eve from owners group
###############################################
echo "[solution] Step 3: Fixing Keycloak group memberships..."

KC_TOKEN=$(get_kc_token)

# Discover the realm
KC_REALM="devops"

# Find the platform-eng/glitchtip-owners group
GROUPS_JSON=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${KC_REALM}/groups" 2>/dev/null)

# Find platform-eng group and its glitchtip-owners child
PLATFORM_ENG_ID=$(echo "$GROUPS_JSON" | jq -r '.[] | select(.name=="platform-eng") | .id')
OWNERS_GROUP_ID=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${KC_REALM}/groups/${PLATFORM_ENG_ID}/children" | \
  jq -r '.[] | select(.name=="glitchtip-owners") | .id')

echo "[solution] Owners group ID: ${OWNERS_GROUP_ID}"

# List current members of the owners group
OWNER_MEMBERS=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${KC_REALM}/groups/${OWNERS_GROUP_ID}/members")

# Remove non-admin users (keep alice and bob, remove charlie, diana, eve)
echo "$OWNER_MEMBERS" | jq -r '.[] | select(.username != "alice" and .username != "bob") | .id' | while read -r user_id; do
  if [ -n "$user_id" ]; then
    USERNAME=$(echo "$OWNER_MEMBERS" | jq -r --arg id "$user_id" '.[] | select(.id==$id) | .username')
    echo "[solution] Removing ${USERNAME} from glitchtip-owners group"
    curl -sf -X DELETE -H "Authorization: Bearer ${KC_TOKEN}" \
      "${KEYCLOAK_URL}/admin/realms/${KC_REALM}/users/${user_id}/groups/${OWNERS_GROUP_ID}"
  fi
done

echo "[solution] Keycloak group memberships fixed."

###############################################
# STEP 4: Fix GlitchTip OIDC ConfigMap
# Restore 'groups' scope and full group path
###############################################
echo "[solution] Step 4: Fixing GlitchTip OIDC ConfigMap..."

kubectl patch configmap glitchtip-oidc-config -n glitchtip --type merge -p '{
  "data": {
    "OPENID_CONNECT_SCOPE": "openid profile email groups",
    "GLITCHTIP_OIDC_OWNER_GROUP": "/platform-eng/glitchtip-owners"
  }
}'

# Restart GlitchTip to pick up config changes
kubectl rollout restart deployment glitchtip-web -n glitchtip
kubectl rollout status deployment glitchtip-web -n glitchtip --timeout=180s

# Wait for GlitchTip to be healthy
for i in $(seq 1 60); do
  if curl -sf -o /dev/null "${GLITCHTIP_URL}" 2>/dev/null; then break; fi
  sleep 3
done

echo "[solution] GlitchTip OIDC config fixed and deployment restarted."

###############################################
# STEP 5: Demote over-privileged GlitchTip users
# charlie, diana, eve should be members, not owners
###############################################
echo "[solution] Step 5: Demoting over-privileged users in GlitchTip..."

GT_POD=$(kubectl get pods -n glitchtip -l app=glitchtip,component=web -o jsonpath='{.items[0].metadata.name}')

# Wait for pod to be ready
kubectl wait --for=condition=ready pod "${GT_POD}" -n glitchtip --timeout=120s

# Use Django management shell to fix roles
kubectl exec -n glitchtip "${GT_POD}" -- python manage.py shell -c "
from django.contrib.auth import get_user_model
from apps.organizations_ext.models import OrganizationUser

User = get_user_model()

# Demote charlie, diana, eve to member (role=0)
for email in ['charlie@devops.local', 'diana@devops.local', 'eve@devops.local']:
    try:
        user = User.objects.get(email=email)
        org_users = OrganizationUser.objects.filter(user=user)
        for ou in org_users:
            if ou.role == 3:  # owner
                ou.role = 0   # member
                ou.save()
                print(f'Demoted {email} from owner to member')
    except User.DoesNotExist:
        print(f'User {email} not found')

# Verify alice and bob remain owners
for email in ['alice@devops.local', 'bob@devops.local']:
    try:
        user = User.objects.get(email=email)
        org_users = OrganizationUser.objects.filter(user=user)
        for ou in org_users:
            print(f'{email}: role={ou.role} (0=owner, 1=member)')
    except User.DoesNotExist:
        print(f'User {email} not found')
"

echo "[solution] User roles corrected."

###############################################
# VERIFICATION
###############################################
echo "[solution] Running verification checks..."

# Check 1: Keycloak groups
KC_TOKEN=$(get_kc_token)
OWNER_MEMBERS=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${KC_REALM}/groups/${OWNERS_GROUP_ID}/members" | jq -r '.[].username' | sort)
echo "[solution] Keycloak owners group members: ${OWNER_MEMBERS}"

# Check 2: CronJob deleted
CJ_COUNT=$(kubectl get cronjobs -n keycloak --no-headers 2>/dev/null | grep -c "reconciler" || echo "0")
echo "[solution] Reconciler CronJobs remaining: ${CJ_COUNT}"

# Check 3: OIDC config
SCOPE=$(kubectl get configmap glitchtip-oidc-config -n glitchtip -o jsonpath='{.data.OPENID_CONNECT_SCOPE}')
OWNER_GROUP=$(kubectl get configmap glitchtip-oidc-config -n glitchtip -o jsonpath='{.data.GLITCHTIP_OIDC_OWNER_GROUP}')
echo "[solution] OIDC scope: ${SCOPE}"
echo "[solution] Owner group: ${OWNER_GROUP}"

# Check 4: Network connectivity
GT_POD=$(kubectl get pods -n glitchtip -l app=glitchtip,component=web -o jsonpath='{.items[0].metadata.name}')
if kubectl exec -n glitchtip "${GT_POD}" -- curl -sf "http://keycloak.devops.local:8080/realms/master" >/dev/null 2>&1; then
  echo "[solution] Network connectivity: OK"
else
  echo "[solution] Network connectivity: FAILED"
fi

echo "[solution] ============================================"
echo "[solution] Solution complete."
echo "[solution] ============================================"
