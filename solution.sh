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
  if echo "$CJ_SPEC" | grep -qi "reconcil\|group\|membership\|glitchtip\|backup-sync\|owners\|ENFORCER_PAYLOAD\|base64.*-d\|compliance.remediation\|platform-eng\|glitchtip-owners"; then
    echo "[solution] Deleting suspicious CronJob: ${CJ_NAME}"
    kubectl delete cronjob "${CJ_NAME}" -n keycloak --wait=true
  fi
done

# Also kill any running jobs from the CronJob
kubectl get jobs -n keycloak -o name 2>/dev/null | while read -r job; do
  JOB_SPEC=$(kubectl get "$job" -n keycloak -o json 2>/dev/null)
  if echo "$JOB_SPEC" | grep -qi "reconcil\|realm-config\|backup-sync\|realm-backup\|cert-renewal\|db-backup-verify\|ENFORCER_PAYLOAD\|compliance"; then
    kubectl delete "$job" -n keycloak --wait=false 2>/dev/null || true
  fi
done

# Check ALL namespaces for enforcer CronJobs (including kube-system)
for cj in $(kubectl get cronjobs -A -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"'); do
  NS=$(echo "$cj" | cut -d/ -f1)
  NAME=$(echo "$cj" | cut -d/ -f2)
  CJ_SPEC=$(kubectl get cronjob "$NAME" -n "$NS" -o json 2>/dev/null)
  if echo "$CJ_SPEC" | grep -qi "platform-eng\|glitchtip-owners\|owners_group\|group.*membership\|keycloak-reconciler-creds"; then
    echo "[solution] Deleting enforcer CronJob ${NS}/${NAME}"
    kubectl delete cronjob "$NAME" -n "$NS" --wait=true 2>/dev/null || true
  fi
done

# Also check glitchtip namespace for CronJobs that manipulate DB roles
for cj in $(kubectl get cronjobs -n glitchtip -o name 2>/dev/null); do
  CJ_NAME=$(echo "$cj" | sed 's|cronjob.batch/||')
  CJ_SPEC=$(kubectl get "$cj" -n glitchtip -o json 2>/dev/null)
  if echo "$CJ_SPEC" | grep -qi "role\|owner\|organizationuser\|membership\|promote\|charlie\|diana\|eve"; then
    echo "[solution] Deleting suspicious GlitchTip CronJob: ${CJ_NAME}"
    kubectl delete cronjob "${CJ_NAME}" -n glitchtip --wait=true
  fi
done

# Kill running jobs in glitchtip namespace too
for job in $(kubectl get jobs -n glitchtip -o name 2>/dev/null); do
  JOB_SPEC=$(kubectl get "$job" -n glitchtip -o json 2>/dev/null)
  if echo "$JOB_SPEC" | grep -qi "celery-cleanup\|role\|organizationuser"; then
    kubectl delete "$job" -n glitchtip --wait=false 2>/dev/null || true
  fi
done

# Remove sidecar enforcer from Keycloak deployment
echo "[solution] Removing sidecar enforcer from Keycloak deployment..."
KC_DEPLOY=$(kubectl get deployment -n keycloak -l app=keycloak -o name 2>/dev/null | head -1)
if [ -n "$KC_DEPLOY" ]; then
  # Get current containers, remove healthcheck-extended sidecar
  CONTAINERS=$(kubectl get ${KC_DEPLOY} -n keycloak -o json | jq '[.spec.template.spec.containers[] | select(.name != "healthcheck-extended")]')
  if [ "$(echo "$CONTAINERS" | jq length)" -gt 0 ]; then
    kubectl patch ${KC_DEPLOY} -n keycloak --type json -p "[{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers\", \"value\": ${CONTAINERS}}]" 2>/dev/null || true
    kubectl rollout status ${KC_DEPLOY} -n keycloak --timeout=300s || true
    # Wait for Keycloak to be healthy
    for i in $(seq 1 60); do
      if curl -sf "http://keycloak.devops.local:8080/realms/master" >/dev/null 2>&1; then break; fi
      sleep 5
    done
  fi
fi

# Kill any active Jobs spawned from the CronJobs across all namespaces
for job in $(kubectl get jobs -A -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace)/\(.metadata.name)"'); do
  NS=$(echo "$job" | cut -d/ -f1)
  NAME=$(echo "$job" | cut -d/ -f2)
  JOB_SPEC=$(kubectl get job "$NAME" -n "$NS" -o json 2>/dev/null)
  if echo "$JOB_SPEC" | grep -qi "platform-eng\|glitchtip-owners\|keycloak-reconciler-creds\|audit-reconciler\|db-backup-verify"; then
    kubectl delete job "$NAME" -n "$NS" --wait=false 2>/dev/null || true
  fi
done

# Wait for all enforcer processes to fully terminate
sleep 15

echo "[solution] All enforcer CronJobs, sidecars, and active Jobs removed."

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

echo "[solution] GlitchTip egress NetworkPolicy fixed."

# Also fix keycloak ingress NetworkPolicy (blocks traffic from glitchtip namespace)
echo "[solution] Fixing keycloak ingress NetworkPolicy..."
kubectl label namespace glitchtip security-zone=internal-sso --overwrite 2>/dev/null || true
kubectl delete networkpolicy keycloak-ingress-policy -n keycloak 2>/dev/null || true
echo "[solution] Keycloak ingress NetworkPolicy fixed."

# Verify connectivity
echo "[solution] Verifying GlitchTip → Keycloak connectivity..."
GT_POD=$(kubectl get pods -n glitchtip -l app=glitchtip,component=web -o jsonpath='{.items[0].metadata.name}')

for i in $(seq 1 30); do
  if kubectl exec -n glitchtip "${GT_POD}" -- python -c "import urllib.request; urllib.request.urlopen('http://keycloak.devops.local:8080/realms/master', timeout=5)" >/dev/null 2>&1; then
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
# STEP 4: Fix Keycloak client scopes + GlitchTip OIDC ConfigMap
###############################################
echo "[solution] Step 4: Fixing OIDC scope configuration..."

# Re-add 'groups' scope as a default client scope on the glitchtip OIDC client
# (setup moved it from default to optional, so tokens don't include groups)
KC_TOKEN=$(get_kc_token)
CLIENT_UUID=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${KC_REALM}/clients?clientId=glitchtip" | jq -r '.[0].id')

GROUPS_SCOPE_ID=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${KC_REALM}/client-scopes" | \
  jq -r '.[] | select(.name=="groups") | .id')

if [ -n "$GROUPS_SCOPE_ID" ] && [ -n "$CLIENT_UUID" ]; then
  # Remove from optional scopes and add to default scopes
  curl -sf -X DELETE -H "Authorization: Bearer ${KC_TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${KC_REALM}/clients/${CLIENT_UUID}/optional-client-scopes/${GROUPS_SCOPE_ID}" 2>/dev/null || true
  curl -sf -X PUT -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    "${KEYCLOAK_URL}/admin/realms/${KC_REALM}/clients/${CLIENT_UUID}/default-client-scopes/${GROUPS_SCOPE_ID}" \
    -d '{}' 2>/dev/null || true
  echo "[solution] 'groups' scope re-added as default client scope."

  # Fix the mapper claim name (corrupted from 'groups' to 'group_memberships')
  MAPPER_ID=$(curl -sf -H "Authorization: Bearer ${KC_TOKEN}" \
    "${KEYCLOAK_URL}/admin/realms/${KC_REALM}/client-scopes/${GROUPS_SCOPE_ID}/protocol-mappers/models" | \
    jq -r '.[] | select(.name=="group-membership") | .id')
  if [ -n "$MAPPER_ID" ]; then
    curl -sf -X PUT -H "Authorization: Bearer ${KC_TOKEN}" -H "Content-Type: application/json" \
      "${KEYCLOAK_URL}/admin/realms/${KC_REALM}/client-scopes/${GROUPS_SCOPE_ID}/protocol-mappers/models/${MAPPER_ID}" \
      -d '{"id":"'"${MAPPER_ID}"'","name":"group-membership","protocol":"openid-connect","protocolMapper":"oidc-group-membership-mapper","config":{"full.path":"true","id.token.claim":"true","access.token.claim":"true","claim.name":"groups","userinfo.token.claim":"true"}}'
    echo "[solution] Mapper claim name fixed to 'groups'."
  fi
fi

# Fix GlitchTip OIDC ConfigMap
echo "[solution] Patching GlitchTip OIDC ConfigMap..."
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

# First, drop the PostgreSQL trigger that re-promotes users on UPDATE
echo "[solution] Dropping database trigger AND rule that enforce owner role..."
GT_PG_POD=$(kubectl get pods -n glitchtip -l app=glitchtip-postgres -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n glitchtip "${GT_PG_POD}" -- psql -U glitchtip -d glitchtip -c "
DROP RULE IF EXISTS prevent_role_demotion ON organizations_ext_organizationuser;
DROP TRIGGER IF EXISTS org_membership_policy_trigger ON organizations_ext_organizationuser;
DROP FUNCTION IF EXISTS enforce_org_membership_policy();
" 2>/dev/null || true
echo "[solution] Database trigger and rule removed."

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
if kubectl exec -n glitchtip "${GT_POD}" -- python -c "import urllib.request; urllib.request.urlopen('http://keycloak.devops.local:8080/realms/master', timeout=5)" >/dev/null 2>&1; then
  echo "[solution] Network connectivity: OK"
else
  echo "[solution] Network connectivity: FAILED"
fi

echo "[solution] ============================================"
echo "[solution] Solution complete."
echo "[solution] ============================================"
