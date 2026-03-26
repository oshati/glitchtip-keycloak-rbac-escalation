#!/bin/bash
set -euo pipefail

###############################################
# BOILERPLATE — DO NOT MODIFY
###############################################
/usr/bin/supervisord -c /etc/supervisord.conf &
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo "[setup] Waiting for k3s node to be Ready..."
until kubectl get nodes 2>/dev/null | grep -q " Ready"; do sleep 2; done
echo "[setup] k3s is Ready."

# Create ubuntu kubeconfig
mkdir -p /home/ubuntu/.kube
cp /etc/rancher/k3s/k3s.yaml /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube
chmod 600 /home/ubuntu/.kube/config

###############################################
# HELPER FUNCTIONS
###############################################
KEYCLOAK_URL="http://keycloak.devops.local"
GLITCHTIP_URL="http://glitchtip.devops.local"
KC_ADMIN_USER="admin"
KC_ADMIN_PASS="changeme"
KC_REALM="devops"

get_kc_token() {
  curl -sf -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "grant_type=password" \
    -d "username=${KC_ADMIN_USER}" \
    -d "password=${KC_ADMIN_PASS}" | jq -r '.access_token'
}

kc_api() {
  local method="$1"
  local path="$2"
  shift 2
  local token
  token=$(get_kc_token)
  curl -sf -X "${method}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "${KEYCLOAK_URL}/admin/realms/${KC_REALM}${path}" "$@"
}

kc_api_raw() {
  local method="$1"
  local path="$2"
  shift 2
  local token
  token=$(get_kc_token)
  curl -s -o /dev/null -w "%{http_code}" -X "${method}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    "${KEYCLOAK_URL}/admin/realms/${KC_REALM}${path}" "$@"
}

###############################################
# WAIT FOR SERVICES
###############################################
echo "[setup] Waiting for Keycloak pods..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=keycloak -n keycloak --timeout=300s 2>/dev/null || \
kubectl wait --for=condition=ready pod -l app=keycloak -n keycloak --timeout=300s 2>/dev/null || true
sleep 10

echo "[setup] Waiting for Keycloak API to respond..."
until curl -sf "${KEYCLOAK_URL}/realms/master" >/dev/null 2>&1; do sleep 3; done
echo "[setup] Keycloak API is up."

echo "[setup] Waiting for GlitchTip pods..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=glitchtip -n glitchtip --timeout=300s 2>/dev/null || \
kubectl wait --for=condition=ready pod -l app=glitchtip -n glitchtip --timeout=300s 2>/dev/null || true
sleep 5

echo "[setup] Waiting for GlitchTip API to respond..."
for i in $(seq 1 60); do
  if curl -sf "${GLITCHTIP_URL}/api/0/" >/dev/null 2>&1 || \
     curl -sf -o /dev/null -w "%{http_code}" "${GLITCHTIP_URL}" 2>/dev/null | grep -qE "^(200|301|302)"; then
    break
  fi
  sleep 5
done
echo "[setup] GlitchTip is up."

###############################################
# SCALE DOWN NON-ESSENTIAL WORKLOADS
###############################################
echo "[setup] Scaling down non-essential workloads for CPU headroom..."
for ns in bleater monitoring observability harbor argocd mattermost; do
  kubectl get deployments -n "$ns" -o name 2>/dev/null | while read -r dep; do
    kubectl scale "$dep" -n "$ns" --replicas=0 2>/dev/null || true
  done
  kubectl get statefulsets -n "$ns" -o name 2>/dev/null | while read -r sts; do
    kubectl scale "$sts" -n "$ns" --replicas=0 2>/dev/null || true
  done
done

###############################################
# KEYCLOAK: CREATE REALM
###############################################
echo "[setup] Configuring Keycloak realm..."
KC_TOKEN=$(get_kc_token)

# Check if devops realm exists
REALM_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${KC_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${KC_REALM}")

if [ "$REALM_EXISTS" != "200" ]; then
  echo "[setup] Creating realm '${KC_REALM}'..."
  curl -sf -X POST \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    "${KEYCLOAK_URL}/admin/realms" \
    -d '{
      "realm": "'"${KC_REALM}"'",
      "enabled": true,
      "registrationAllowed": false,
      "loginWithEmailAllowed": true,
      "duplicateEmailsAllowed": false
    }'
fi

###############################################
# KEYCLOAK: CREATE OIDC CLIENT FOR GLITCHTIP
###############################################
echo "[setup] Creating OIDC client for GlitchTip..."
GLITCHTIP_CLIENT_SECRET="gt-oidc-secret-$(head -c 16 /dev/urandom | xxd -p)"

# Check if client exists
EXISTING_CLIENT=$(kc_api GET "/clients?clientId=glitchtip" 2>/dev/null || echo "[]")
CLIENT_UUID=$(echo "$EXISTING_CLIENT" | jq -r '.[0].id // empty')

if [ -z "$CLIENT_UUID" ]; then
  kc_api POST "/clients" -d '{
    "clientId": "glitchtip",
    "name": "GlitchTip Error Tracking",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": false,
    "secret": "'"${GLITCHTIP_CLIENT_SECRET}"'",
    "redirectUris": ["http://glitchtip.devops.local/*"],
    "webOrigins": ["http://glitchtip.devops.local"],
    "standardFlowEnabled": true,
    "directAccessGrantsEnabled": true,
    "serviceAccountsEnabled": false,
    "authorizationServicesEnabled": false,
    "defaultClientScopes": ["openid", "profile", "email"]
  }'
  CLIENT_UUID=$(kc_api GET "/clients?clientId=glitchtip" | jq -r '.[0].id')
else
  # Update existing client secret
  kc_api PUT "/clients/${CLIENT_UUID}" -d '{
    "clientId": "glitchtip",
    "enabled": true,
    "protocol": "openid-connect",
    "publicClient": false,
    "secret": "'"${GLITCHTIP_CLIENT_SECRET}"'",
    "redirectUris": ["http://glitchtip.devops.local/*"],
    "standardFlowEnabled": true,
    "directAccessGrantsEnabled": true
  }'
  GLITCHTIP_CLIENT_SECRET=$(kc_api GET "/clients/${CLIENT_UUID}/client-secret" | jq -r '.value')
fi

echo "[setup] GlitchTip client UUID: ${CLIENT_UUID}"

###############################################
# KEYCLOAK: ADD GROUP MEMBERSHIP MAPPER
###############################################
echo "[setup] Adding group membership protocol mapper..."

# Check if mapper already exists
EXISTING_MAPPER=$(kc_api GET "/clients/${CLIENT_UUID}/protocol-mappers/models" 2>/dev/null | \
  jq -r '.[] | select(.name=="group-membership") | .id // empty')

if [ -z "$EXISTING_MAPPER" ]; then
  kc_api POST "/clients/${CLIENT_UUID}/protocol-mappers/models" -d '{
    "name": "group-membership",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "config": {
      "full.path": "true",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "claim.name": "groups",
      "userinfo.token.claim": "true"
    }
  }'
fi

###############################################
# KEYCLOAK: CREATE GROUP HIERARCHY
###############################################
echo "[setup] Creating group hierarchy..."

# Create parent group: platform-eng
PLATFORM_ENG_ID=$(kc_api GET "/groups?search=platform-eng" 2>/dev/null | \
  jq -r '.[] | select(.name=="platform-eng") | .id // empty')

if [ -z "$PLATFORM_ENG_ID" ]; then
  kc_api POST "/groups" -d '{"name": "platform-eng"}'
  PLATFORM_ENG_ID=$(kc_api GET "/groups?search=platform-eng" | jq -r '.[] | select(.name=="platform-eng") | .id')
fi

# Create subgroup: glitchtip-owners under platform-eng
OWNERS_GROUP_ID=$(kc_api GET "/groups/${PLATFORM_ENG_ID}/children" 2>/dev/null | \
  jq -r '.[] | select(.name=="glitchtip-owners") | .id // empty')

if [ -z "$OWNERS_GROUP_ID" ]; then
  kc_api POST "/groups/${PLATFORM_ENG_ID}/children" -d '{"name": "glitchtip-owners"}'
  OWNERS_GROUP_ID=$(kc_api GET "/groups/${PLATFORM_ENG_ID}/children" | \
    jq -r '.[] | select(.name=="glitchtip-owners") | .id')
fi

# Create subgroup: glitchtip-users under platform-eng
USERS_GROUP_ID=$(kc_api GET "/groups/${PLATFORM_ENG_ID}/children" 2>/dev/null | \
  jq -r '.[] | select(.name=="glitchtip-users") | .id // empty')

if [ -z "$USERS_GROUP_ID" ]; then
  kc_api POST "/groups/${PLATFORM_ENG_ID}/children" -d '{"name": "glitchtip-users"}'
  USERS_GROUP_ID=$(kc_api GET "/groups/${PLATFORM_ENG_ID}/children" | \
    jq -r '.[] | select(.name=="glitchtip-users") | .id')
fi

# Create DECOY groups
# Top-level glitchtip-owners (decoy — different path than /platform-eng/glitchtip-owners)
DECOY_OWNERS_ID=$(kc_api GET "/groups?search=glitchtip-owners&exact=true" 2>/dev/null | \
  jq -r '[.[] | select(.name=="glitchtip-owners" and (.path=="/glitchtip-owners"))] | .[0].id // empty')

if [ -z "$DECOY_OWNERS_ID" ]; then
  kc_api POST "/groups" -d '{"name": "glitchtip-owners"}'
  DECOY_OWNERS_ID=$(kc_api GET "/groups" | \
    jq -r '.[] | select(.name=="glitchtip-owners" and (.path=="/glitchtip-owners")) | .id // empty')
fi

# /engineering/glitchtip-admins (decoy)
ENG_GROUP_ID=$(kc_api GET "/groups?search=engineering" 2>/dev/null | \
  jq -r '.[] | select(.name=="engineering") | .id // empty')

if [ -z "$ENG_GROUP_ID" ]; then
  kc_api POST "/groups" -d '{"name": "engineering"}'
  ENG_GROUP_ID=$(kc_api GET "/groups?search=engineering" | jq -r '.[] | select(.name=="engineering") | .id')
fi

DECOY_ADMINS_ID=$(kc_api GET "/groups/${ENG_GROUP_ID}/children" 2>/dev/null | \
  jq -r '.[] | select(.name=="glitchtip-admins") | .id // empty')

if [ -z "$DECOY_ADMINS_ID" ]; then
  kc_api POST "/groups/${ENG_GROUP_ID}/children" -d '{"name": "glitchtip-admins"}'
fi

echo "[setup] Group IDs: owners=${OWNERS_GROUP_ID}, users=${USERS_GROUP_ID}"

###############################################
# KEYCLOAK: CREATE USERS
###############################################
echo "[setup] Creating Keycloak users..."
USER_PASS="DevOps2024!"

declare -A USER_IDS

for username in alice bob charlie diana eve; do
  EXISTING_USER=$(kc_api GET "/users?username=${username}&exact=true" 2>/dev/null | jq -r '.[0].id // empty')

  if [ -z "$EXISTING_USER" ]; then
    kc_api POST "/users" -d '{
      "username": "'"${username}"'",
      "email": "'"${username}"'@devops.local",
      "enabled": true,
      "emailVerified": true,
      "firstName": "'"$(echo "${username}" | sed 's/./\U&/')"'",
      "lastName": "Engineer",
      "credentials": [{
        "type": "password",
        "value": "'"${USER_PASS}"'",
        "temporary": false
      }]
    }'
    EXISTING_USER=$(kc_api GET "/users?username=${username}&exact=true" | jq -r '.[0].id')
  fi

  USER_IDS[${username}]="${EXISTING_USER}"
  echo "[setup] User ${username}: ${EXISTING_USER}"
done

###############################################
# KEYCLOAK: ASSIGN CORRECT GROUP MEMBERSHIPS
# (before breakage — alice and bob in owners,
#  charlie/diana/eve in users group)
###############################################
echo "[setup] Setting correct group memberships (pre-breakage baseline)..."

# Owners: alice, bob
for username in alice bob; do
  kc_api_raw PUT "/users/${USER_IDS[${username}]}/groups/${OWNERS_GROUP_ID}" -d '{}'
  kc_api_raw PUT "/users/${USER_IDS[${username}]}/groups/${USERS_GROUP_ID}" -d '{}'
done

# Members only: charlie, diana, eve
for username in charlie diana eve; do
  kc_api_raw PUT "/users/${USER_IDS[${username}]}/groups/${USERS_GROUP_ID}" -d '{}'
done

###############################################
# GLITCHTIP: CONFIGURE OIDC INTEGRATION
###############################################
echo "[setup] Configuring GlitchTip OIDC integration..."

# Discover the GlitchTip web deployment name
GT_DEPLOY=$(kubectl get deployments -n glitchtip -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "glitchtip-web")
GT_POD=$(kubectl get pods -n glitchtip -l app.kubernetes.io/name=glitchtip -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
         kubectl get pods -n glitchtip -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

# Create the OIDC ConfigMap (correct state first)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: glitchtip-oidc-config
  namespace: glitchtip
  labels:
    app: glitchtip
    component: oidc-integration
data:
  ENABLE_OPEN_ID_CONNECT: "true"
  OPENID_CONNECT_URL: "http://keycloak.devops.local/realms/${KC_REALM}/.well-known/openid-configuration"
  OPENID_CONNECT_CLIENT_ID: "glitchtip"
  OPENID_CONNECT_CLIENT_SECRET: "${GLITCHTIP_CLIENT_SECRET}"
  OPENID_CONNECT_SCOPE: "openid profile email groups"
  GLITCHTIP_OIDC_OWNER_GROUP: "/platform-eng/glitchtip-owners"
  GLITCHTIP_OIDC_MEMBER_GROUP: "/platform-eng/glitchtip-users"
EOF

# Patch GlitchTip deployment to use OIDC config
kubectl patch deployment "${GT_DEPLOY}" -n glitchtip --type json -p '[{
  "op": "add",
  "path": "/spec/template/spec/containers/0/envFrom/-",
  "value": {"configMapRef": {"name": "glitchtip-oidc-config"}}
}]' 2>/dev/null || \
kubectl patch deployment "${GT_DEPLOY}" -n glitchtip --type strategic -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "'"$(kubectl get deployment "${GT_DEPLOY}" -n glitchtip -o jsonpath='{.spec.template.spec.containers[0].name}')"'",
          "envFrom": [{"configMapRef": {"name": "glitchtip-oidc-config"}}]
        }]
      }
    }
  }
}'

kubectl rollout restart deployment "${GT_DEPLOY}" -n glitchtip
kubectl rollout status deployment "${GT_DEPLOY}" -n glitchtip --timeout=180s

# Wait for GlitchTip to come back
for i in $(seq 1 60); do
  if curl -sf -o /dev/null "${GLITCHTIP_URL}" 2>/dev/null; then break; fi
  sleep 3
done

###############################################
# GLITCHTIP: CREATE ORG + USERS VIA API/DJANGO
###############################################
echo "[setup] Creating GlitchTip organization and users..."

GT_POD=$(kubectl get pods -n glitchtip -l app.kubernetes.io/name=glitchtip -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
         kubectl get pods -n glitchtip -o jsonpath='{.items[0].metadata.name}')

# Create superuser and organization via Django management commands
kubectl exec -n glitchtip "${GT_POD}" -- python manage.py shell -c "
from django.contrib.auth import get_user_model
from organizations_ext.models import Organization, OrganizationUser

User = get_user_model()

# Create or get admin superuser
admin, _ = User.objects.get_or_create(
    email='admin@devops.local',
    defaults={'is_staff': True, 'is_superuser': True}
)
admin.set_password('GlitchAdmin2024!')
admin.save()

# Create organization
org, _ = Organization.objects.get_or_create(name='DevOps Platform')

# Ensure admin is owner
OrganizationUser.objects.get_or_create(
    organization=org, user=admin,
    defaults={'role': 0}  # 0 = owner in GlitchTip
)

# Create member users and set them all as OWNERS (the breakage)
for username in ['alice', 'bob', 'charlie', 'diana', 'eve']:
    user, created = User.objects.get_or_create(
        email=f'{username}@devops.local',
        defaults={'is_staff': False, 'is_superuser': False}
    )
    if created:
        user.set_password('DevOps2024!')
        user.save()
    ou, _ = OrganizationUser.objects.get_or_create(
        organization=org, user=user,
        defaults={'role': 0}  # 0 = owner — THIS IS THE BREAKAGE
    )
    if not created:
        ou.role = 0  # Force owner
        ou.save()

print('GlitchTip users configured with owner roles.')
" 2>/dev/null || echo "[setup] Warning: Django shell command may have partial failure"

###############################################
# BREAKAGE 1: KEYCLOAK GROUP MEMBERSHIPS
# Add charlie, diana, eve to owners group
# (they should only be in users group)
###############################################
echo "[setup] BREAKAGE 1: Adding all users to glitchtip-owners group..."
for username in charlie diana eve; do
  kc_api_raw PUT "/users/${USER_IDS[${username}]}/groups/${OWNERS_GROUP_ID}" -d '{}'
done

###############################################
# BREAKAGE 2: GLITCHTIP OIDC CONFIGMAP
# Remove 'groups' from scope, use flat owner
# group name instead of full path
###############################################
echo "[setup] BREAKAGE 2: Corrupting GlitchTip OIDC config..."
kubectl patch configmap glitchtip-oidc-config -n glitchtip --type merge -p '{
  "data": {
    "OPENID_CONNECT_SCOPE": "openid profile email",
    "GLITCHTIP_OIDC_OWNER_GROUP": "glitchtip-owners"
  }
}'

# Restart to pick up broken config
kubectl rollout restart deployment "${GT_DEPLOY}" -n glitchtip
kubectl rollout status deployment "${GT_DEPLOY}" -n glitchtip --timeout=180s || true

###############################################
# BREAKAGE 3: ENFORCER CRONJOB
# Reconciler that re-adds users to owners
# group every 3 minutes
###############################################
echo "[setup] BREAKAGE 3: Creating enforcer CronJob..."

# Store Keycloak creds in a secret for the CronJob
kubectl create secret generic keycloak-reconciler-creds -n keycloak \
  --from-literal=KC_ADMIN_USER="${KC_ADMIN_USER}" \
  --from-literal=KC_ADMIN_PASS="${KC_ADMIN_PASS}" \
  --from-literal=KC_REALM="${KC_REALM}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: CronJob
metadata:
  name: keycloak-realm-config-reconciler
  namespace: keycloak
  labels:
    app: keycloak
    component: realm-reconciler
  annotations:
    description: "Reconciles realm group memberships for SSO compliance"
spec:
  schedule: "*/3 * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 120
      template:
        metadata:
          labels:
            app: keycloak
            job: realm-reconciler
        spec:
          restartPolicy: Never
          containers:
          - name: reconciler
            image: curlimages/curl:latest
            command:
            - /bin/sh
            - -c
            - |
              KC_URL="http://keycloak.keycloak.svc.cluster.local:8080"
              TOKEN=\$(curl -sf -X POST "\${KC_URL}/realms/master/protocol/openid-connect/token" \
                -d "client_id=admin-cli" \
                -d "grant_type=password" \
                -d "username=\${KC_ADMIN_USER}" \
                -d "password=\${KC_ADMIN_PASS}" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')

              if [ -z "\${TOKEN}" ]; then echo "Failed to get token"; exit 1; fi

              # Get owners group ID
              OWNERS_GID=\$(curl -sf -H "Authorization: Bearer \${TOKEN}" \
                "\${KC_URL}/admin/realms/\${KC_REALM}/groups?search=glitchtip-owners" | \
                sed -n 's/.*"id":"\([^"]*\)".*"path":"\/platform-eng\/glitchtip-owners".*/\1/p')

              if [ -z "\${OWNERS_GID}" ]; then
                # Try nested search
                PLATFORM_GID=\$(curl -sf -H "Authorization: Bearer \${TOKEN}" \
                  "\${KC_URL}/admin/realms/\${KC_REALM}/groups?search=platform-eng" | \
                  sed -n 's/.*"id":"\([^"]*\)".*"name":"platform-eng".*/\1/p')
                OWNERS_GID=\$(curl -sf -H "Authorization: Bearer \${TOKEN}" \
                  "\${KC_URL}/admin/realms/\${KC_REALM}/groups/\${PLATFORM_GID}/children" | \
                  sed -n 's/.*"id":"\([^"]*\)".*"name":"glitchtip-owners".*/\1/p')
              fi

              # Add ALL users to owners group
              for USERNAME in alice bob charlie diana eve; do
                USER_ID=\$(curl -sf -H "Authorization: Bearer \${TOKEN}" \
                  "\${KC_URL}/admin/realms/\${KC_REALM}/users?username=\${USERNAME}&exact=true" | \
                  sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
                if [ -n "\${USER_ID}" ] && [ -n "\${OWNERS_GID}" ]; then
                  curl -sf -X PUT -H "Authorization: Bearer \${TOKEN}" -H "Content-Type: application/json" \
                    "\${KC_URL}/admin/realms/\${KC_REALM}/users/\${USER_ID}/groups/\${OWNERS_GID}" -d '{}'
                fi
              done
              echo "Realm group reconciliation complete."
            env:
            - name: KC_ADMIN_USER
              valueFrom:
                secretKeyRef:
                  name: keycloak-reconciler-creds
                  key: KC_ADMIN_USER
            - name: KC_ADMIN_PASS
              valueFrom:
                secretKeyRef:
                  name: keycloak-reconciler-creds
                  key: KC_ADMIN_PASS
            - name: KC_REALM
              valueFrom:
                secretKeyRef:
                  name: keycloak-reconciler-creds
                  key: KC_REALM
EOF

###############################################
# BREAKAGE 4: NETWORK POLICY
# Block GlitchTip → Keycloak egress via
# label mismatch on namespace selector
###############################################
echo "[setup] BREAKAGE 4: Creating restrictive NetworkPolicy..."

# First, create a default-deny egress in glitchtip namespace
# so the allow policy actually matters
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: glitchtip-default-deny-egress
  namespace: glitchtip
spec:
  podSelector: {}
  policyTypes:
  - Egress
EOF

# Now create the "allow" policy with a subtle label mismatch
# It allows egress to DNS, internal glitchtip services, and
# "keycloak" namespace — but requires label sso-tier: identity
# which the keycloak namespace does NOT have
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: glitchtip-egress-policy
  namespace: glitchtip
  labels:
    app: glitchtip
    component: network-security
  annotations:
    description: "Egress policy for GlitchTip — allows DNS, internal services, and SSO provider"
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: glitchtip
  policyTypes:
  - Egress
  egress:
  # Allow DNS resolution
  - to: []
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  # Allow internal glitchtip namespace traffic
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: glitchtip
  # Allow traffic to keycloak namespace — BUT requires sso-tier label
  # which the keycloak namespace does NOT have (this is the breakage)
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: keycloak
          sso-tier: identity
EOF

###############################################
# DECOY CONFIGMAPS
###############################################
echo "[setup] Creating decoy ConfigMaps..."

# Decoy 1: Troubleshooting guide with wrong advice
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: glitchtip-oidc-troubleshooting
  namespace: glitchtip
  labels:
    app: glitchtip
    component: documentation
  annotations:
    description: "OIDC troubleshooting notes from platform team"
data:
  TROUBLESHOOTING.md: |
    # GlitchTip OIDC Troubleshooting

    ## Common Issues

    ### Users not getting correct roles
    If users are receiving incorrect roles after SSO login, check the following:

    1. Verify the OIDC claim key. For Keycloak integration, the role information
       is typically in the 'realm_access.roles' claim, NOT in a 'groups' claim.
       Update OPENID_CONNECT_ROLE_CLAIM to 'realm_access.roles' if needed.

    2. Ensure the Keycloak client has the 'roles' scope enabled in the client
       settings. The default scopes should include 'openid', 'profile', 'email',
       and 'roles'.

    3. Check that the group-to-role mapper in Keycloak uses the flat group name
       format (e.g., 'glitchtip-owners') rather than the full path format.
       Full paths were deprecated in Keycloak 22.

    ### SSO login failures
    If OIDC login is failing entirely:
    - Check that the OIDC discovery endpoint is reachable
    - Verify client ID and secret match between Keycloak and GlitchTip
    - Ensure redirect URIs are configured correctly

    ## Contact
    Platform Engineering: #platform-eng on Mattermost
EOF

# Decoy 2: "Backup" config with wrong values (immutable)
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: glitchtip-oidc-config-backup
  namespace: glitchtip
  labels:
    app: glitchtip
    component: oidc-integration
    backup: "true"
  annotations:
    description: "Backup of OIDC config taken before Keycloak 22 migration"
    backup-date: "2024-11-15"
immutable: true
data:
  ENABLE_OPEN_ID_CONNECT: "true"
  OPENID_CONNECT_URL: "http://keycloak.devops.local/realms/${KC_REALM}/.well-known/openid-configuration"
  OPENID_CONNECT_CLIENT_ID: "glitchtip"
  OPENID_CONNECT_CLIENT_SECRET: "old-secret-rotated"
  OPENID_CONNECT_SCOPE: "openid profile email roles"
  GLITCHTIP_OIDC_OWNER_GROUP: "glitchtip-admins"
  GLITCHTIP_OIDC_MEMBER_GROUP: "glitchtip-users"
EOF

# Decoy 3: Keycloak migration notes
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: keycloak-migration-notes
  namespace: keycloak
  labels:
    app: keycloak
    component: documentation
  annotations:
    description: "Notes from Keycloak 21 to 22 migration"
data:
  MIGRATION_NOTES.md: |
    # Keycloak Migration Notes (v21 → v22)

    ## Group Claim Changes
    - Group membership claims now use FLAT names by default
    - The 'full.path' option in group mappers has been deprecated
    - Applications consuming group claims should expect flat names
      (e.g., 'glitchtip-owners' instead of '/platform-eng/glitchtip-owners')
    - If your application still requires full paths, set
      'full.path.fallback: true' in the mapper config

    ## Client Scope Changes
    - The 'groups' scope has been renamed to 'group-membership'
    - Legacy 'groups' scope is still accepted but may be removed in v23
    - Recommended to update all clients to use 'group-membership' scope

    ## Action Items
    - [x] Update all OIDC clients to use flat group names
    - [x] Migrate 'groups' scope to 'group-membership'
    - [ ] Verify all applications accept new claim format
EOF

###############################################
# STRIP ANNOTATIONS FOR DIFFICULTY
###############################################
echo "[setup] Stripping last-applied-configuration annotations..."
for resource in configmap/glitchtip-oidc-config configmap/glitchtip-oidc-troubleshooting configmap/keycloak-migration-notes; do
  ns="glitchtip"
  if [[ "$resource" == *"keycloak"* ]]; then ns="keycloak"; fi
  kubectl annotate "$resource" -n "$ns" kubectl.kubernetes.io/last-applied-configuration- 2>/dev/null || true
done

kubectl annotate networkpolicy/glitchtip-egress-policy -n glitchtip kubectl.kubernetes.io/last-applied-configuration- 2>/dev/null || true
kubectl annotate networkpolicy/glitchtip-default-deny-egress -n glitchtip kubectl.kubernetes.io/last-applied-configuration- 2>/dev/null || true
kubectl annotate cronjob/keycloak-realm-config-reconciler -n keycloak kubectl.kubernetes.io/last-applied-configuration- 2>/dev/null || true

###############################################
# SAVE SETUP INFO FOR GRADER
###############################################
echo "[setup] Saving setup info for grader..."
cat > /root/.setup_info <<SETUP_EOF
KC_REALM=${KC_REALM}
KC_ADMIN_USER=${KC_ADMIN_USER}
KC_ADMIN_PASS=${KC_ADMIN_PASS}
KEYCLOAK_URL=${KEYCLOAK_URL}
GLITCHTIP_URL=${GLITCHTIP_URL}
GLITCHTIP_CLIENT_SECRET=${GLITCHTIP_CLIENT_SECRET}
CLIENT_UUID=${CLIENT_UUID}
OWNERS_GROUP_ID=${OWNERS_GROUP_ID}
USERS_GROUP_ID=${USERS_GROUP_ID}
GT_DEPLOY=${GT_DEPLOY}
OWNER_USERS=alice,bob
MEMBER_USERS=charlie,diana,eve
ALL_USERS=alice,bob,charlie,diana,eve
USER_PASS=${USER_PASS}
ALICE_ID=${USER_IDS[alice]}
BOB_ID=${USER_IDS[bob]}
CHARLIE_ID=${USER_IDS[charlie]}
DIANA_ID=${USER_IDS[diana]}
EVE_ID=${USER_IDS[eve]}
SETUP_EOF

chmod 600 /root/.setup_info

echo "[setup] ============================================"
echo "[setup] Setup complete. Breakages applied:"
echo "[setup]   1. All users added to glitchtip-owners group in Keycloak"
echo "[setup]   2. GlitchTip OIDC scope missing 'groups', owner group path is flat"
echo "[setup]   3. Enforcer CronJob re-adds users to owners group every 3min"
echo "[setup]   4. NetworkPolicy blocks GlitchTip → Keycloak egress"
echo "[setup]   5. All GlitchTip users have owner role"
echo "[setup]   6. Decoy ConfigMaps created for misdirection"
echo "[setup] ============================================"
