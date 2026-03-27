#!/bin/bash
set -eo pipefail

# Force line-buffered output so progress is visible
exec 1> >(stdbuf -oL cat) 2>&1

###############################################
# ENVIRONMENT SETUP
# Base image entrypoint already started
# supervisord + k3s. We just configure.
###############################################
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
KEYCLOAK_URL="http://keycloak.devops.local:8080"
GLITCHTIP_URL="http://glitchtip.devops.local"
KC_ADMIN_USER="admin"
KC_ADMIN_PASS="admin123"
KC_REALM="devops"

get_kc_token() {
  local response
  response=$(curl -s -X POST "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "client_id=admin-cli" \
    -d "grant_type=password" \
    -d "username=${KC_ADMIN_USER}" \
    -d "password=${KC_ADMIN_PASS}" 2>&1)
  echo "$response" | jq -r '.access_token // empty'
}

kc_api() {
  local method="$1"
  local path="$2"
  shift 2
  local token
  token=$(get_kc_token)
  curl -s -X "${method}" \
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
# IMPORT CONTAINER IMAGES
# Auto-import may not work reliably, so manually import with retries
###############################################
echo "[setup] Importing container images..."
CTR="ctr --address /run/k3s/containerd/containerd.sock -n k8s.io"

# Wait for containerd socket to be available
until [ -S /run/k3s/containerd/containerd.sock ]; do sleep 2; done
sleep 5

for img in /var/lib/rancher/k3s/agent/images/*.tar; do
  imgname=$(basename "$img")
  echo "[setup] Importing ${imgname}..."
  for attempt in $(seq 1 5); do
    if $CTR images import "$img" 2>&1; then
      echo "[setup] ${imgname} imported successfully."
      break
    fi
    echo "[setup] Retry ${attempt}/5 for ${imgname}..."
    sleep 10
  done
done

echo "[setup] Verifying images..."
$CTR images ls -q 2>/dev/null | grep -E "glitchtip|curl" || echo "[setup] WARNING: Some images missing"

###############################################
# SCALE DOWN NON-ESSENTIAL WORKLOADS
###############################################
echo "[setup] Scaling down non-essential workloads..."
for ns in bleater monitoring observability harbor argocd mattermost; do
  for dep in $(kubectl get deployments -n "$ns" -o name 2>/dev/null); do
    kubectl scale "$dep" -n "$ns" --replicas=0 2>/dev/null || true
  done
  for sts in $(kubectl get statefulsets -n "$ns" -o name 2>/dev/null); do
    kubectl scale "$sts" -n "$ns" --replicas=0 2>/dev/null || true
  done
done

# Wait for k3s API to fully stabilize after mass scale-down
echo "[setup] Waiting for k3s API to stabilize..."
sleep 15
until kubectl get nodes >/dev/null 2>&1; do
  echo "[setup] k3s API not ready, waiting..."
  sleep 5
done
# Double-check stability — ensure API stays up
sleep 10
until kubectl get nodes >/dev/null 2>&1; do sleep 3; done
echo "[setup] k3s API stable."

# Remove any taints that prevent scheduling (scale-down can cause unreachable taints)
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl taint node "$NODE_NAME" node.kubernetes.io/unreachable- 2>/dev/null || true
kubectl taint node "$NODE_NAME" node.kubernetes.io/not-ready- 2>/dev/null || true
kubectl taint node "$NODE_NAME" node.kubernetes.io/disk-pressure- 2>/dev/null || true
echo "[setup] Node taints cleared."

# Wait for node to be fully Ready
until kubectl get nodes | grep -q " Ready"; do sleep 3; done

# Disable ingress-nginx admission webhook (can be broken after scale-down)
kubectl delete validatingwebhookconfiguration ingress-nginx-admission 2>/dev/null || true

###############################################
# DEPLOY GLITCHTIP STACK
###############################################
kubectl create namespace glitchtip 2>/dev/null || true
echo "[setup] Deploying GlitchTip stack..."

GT_SECRET_KEY="gt-secret-key-abc123def456"
GT_DB_PASS="glitchtipdb99"

kubectl apply --validate=false -f - <<GLITCHTIP_RESOURCES
apiVersion: v1
kind: Secret
metadata:
  name: glitchtip-secrets
  namespace: glitchtip
type: Opaque
stringData:
  SECRET_KEY: "${GT_SECRET_KEY}"
  DATABASE_URL: "postgres://glitchtip:${GT_DB_PASS}@glitchtip-postgres:5432/glitchtip"
  DJANGO_SUPERUSER_EMAIL: "admin@devops.local"
  DJANGO_SUPERUSER_PASSWORD: "GlitchAdmin2024!"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: glitchtip-config
  namespace: glitchtip
  labels:
    app: glitchtip
data:
  GLITCHTIP_DOMAIN: "http://glitchtip.devops.local"
  DEFAULT_FROM_EMAIL: "noreply@devops.local"
  EMAIL_URL: "consolemail://"
  CELERY_WORKER_AUTOSCALE: "1,3"
  CELERY_WORKER_MAX_TASKS_PER_CHILD: "10000"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: glitchtip-postgres-init
  namespace: glitchtip
data:
  init.sql: |
    CREATE DATABASE glitchtip;
    CREATE USER glitchtip WITH PASSWORD '${GT_DB_PASS}';
    GRANT ALL PRIVILEGES ON DATABASE glitchtip TO glitchtip;
    ALTER DATABASE glitchtip OWNER TO glitchtip;
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: glitchtip-postgres
  namespace: glitchtip
  labels:
    app: glitchtip-postgres
spec:
  serviceName: glitchtip-postgres
  replicas: 1
  selector:
    matchLabels:
      app: glitchtip-postgres
  template:
    metadata:
      labels:
        app: glitchtip-postgres
    spec:
      containers:
      - name: postgres
        image: docker.io/library/postgres:16-alpine
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_USER
          value: "glitchtip"
        - name: POSTGRES_PASSWORD
          value: "${GT_DB_PASS}"
        - name: POSTGRES_DB
          value: "glitchtip"
        volumeMounts:
        - name: pgdata
          mountPath: /var/lib/postgresql/data
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "glitchtip"]
          initialDelaySeconds: 5
          periodSeconds: 5
  volumeClaimTemplates:
  - metadata:
      name: pgdata
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: glitchtip-postgres
  namespace: glitchtip
spec:
  selector:
    app: glitchtip-postgres
  ports:
  - port: 5432
    targetPort: 5432
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: glitchtip-redis
  namespace: glitchtip
  labels:
    app: glitchtip-redis
spec:
  replicas: 1
  selector:
    matchLabels:
      app: glitchtip-redis
  template:
    metadata:
      labels:
        app: glitchtip-redis
    spec:
      containers:
      - name: redis
        image: docker.io/library/redis:7-alpine
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 6379
---
apiVersion: v1
kind: Service
metadata:
  name: glitchtip-redis
  namespace: glitchtip
spec:
  selector:
    app: glitchtip-redis
  ports:
  - port: 6379
    targetPort: 6379
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: glitchtip-web
  namespace: glitchtip
  labels:
    app: glitchtip
    component: web
    app.kubernetes.io/name: glitchtip
spec:
  replicas: 1
  selector:
    matchLabels:
      app: glitchtip
      component: web
  template:
    metadata:
      labels:
        app: glitchtip
        component: web
        app.kubernetes.io/name: glitchtip
    spec:
      containers:
      - name: glitchtip
        image: docker.io/glitchtip/glitchtip:v4.1
        imagePullPolicy: IfNotPresent
        command: ["./bin/start.sh"]
        ports:
        - containerPort: 8080
        envFrom:
        - configMapRef:
            name: glitchtip-config
        - secretRef:
            name: glitchtip-secrets
        env:
        - name: REDIS_URL
          value: "redis://glitchtip-redis:6379/0"
        - name: PORT
          value: "8080"
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: glitchtip-worker
  namespace: glitchtip
  labels:
    app: glitchtip
    component: worker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: glitchtip
      component: worker
  template:
    metadata:
      labels:
        app: glitchtip
        component: worker
    spec:
      containers:
      - name: worker
        image: docker.io/glitchtip/glitchtip:v4.1
        imagePullPolicy: IfNotPresent
        command: ["celery", "-A", "glitchtip", "worker", "-B", "-l", "info",
                  "--concurrency", "2", "--max-tasks-per-child", "10000"]
        envFrom:
        - configMapRef:
            name: glitchtip-config
        - secretRef:
            name: glitchtip-secrets
        env:
        - name: REDIS_URL
          value: "redis://glitchtip-redis:6379/0"
---
apiVersion: v1
kind: Service
metadata:
  name: glitchtip
  namespace: glitchtip
  labels:
    app: glitchtip
spec:
  selector:
    app: glitchtip
    component: web
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: glitchtip
  namespace: glitchtip
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
spec:
  ingressClassName: nginx
  rules:
  - host: glitchtip.devops.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: glitchtip
            port:
              number: 80
GLITCHTIP_RESOURCES

echo "[setup] Waiting for PostgreSQL to be ready..."
kubectl rollout status statefulset/glitchtip-postgres -n glitchtip --timeout=300s
kubectl wait --for=condition=ready pod -l app=glitchtip-postgres -n glitchtip --timeout=300s

echo "[setup] Waiting for Redis to be ready..."
kubectl rollout status deployment/glitchtip-redis -n glitchtip --timeout=120s

echo "[setup] Waiting for GlitchTip web to be ready..."
kubectl rollout status deployment/glitchtip-web -n glitchtip --timeout=300s || true

# Wait for GlitchTip to respond
echo "[setup] Waiting for GlitchTip HTTP endpoint..."
for i in $(seq 1 90); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${GLITCHTIP_URL}" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "301" ] || [ "$HTTP_CODE" = "302" ]; then
    echo "[setup] GlitchTip is responding (HTTP ${HTTP_CODE})."
    break
  fi
  sleep 5
done

# Run migrations and create superuser
GT_POD=$(kubectl get pods -n glitchtip -l app=glitchtip,component=web -o jsonpath='{.items[0].metadata.name}')
echo "[setup] Running Django migrations..."
kubectl exec -n glitchtip "${GT_POD}" -- python manage.py migrate --noinput 2>/dev/null || true

echo "[setup] Creating superuser..."
kubectl exec -n glitchtip "${GT_POD}" -- python manage.py createsuperuser --noinput 2>/dev/null || true

###############################################
# WAIT FOR KEYCLOAK
###############################################
echo "[setup] Waiting for Keycloak API..."
until curl -sf "${KEYCLOAK_URL}/realms/master" >/dev/null 2>&1; do sleep 3; done
echo "[setup] Keycloak API is up."

###############################################
# KEYCLOAK: CREATE REALM
###############################################
echo "[setup] Configuring Keycloak realm..."
KC_TOKEN=$(get_kc_token)
echo "[setup] Got Keycloak token: ${KC_TOKEN:0:20}..."

REALM_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer ${KC_TOKEN}" \
  "${KEYCLOAK_URL}/admin/realms/${KC_REALM}")
echo "[setup] Realm check status: ${REALM_EXISTS}"

if [ "$REALM_EXISTS" != "200" ]; then
  echo "[setup] Creating realm '${KC_REALM}'..."
  REALM_CREATE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Bearer ${KC_TOKEN}" \
    -H "Content-Type: application/json" \
    "${KEYCLOAK_URL}/admin/realms" \
    -d '{
      "realm": "'"${KC_REALM}"'",
      "enabled": true,
      "registrationAllowed": false,
      "loginWithEmailAllowed": true
    }')
  echo "[setup] Realm creation status: ${REALM_CREATE_STATUS}"
  if [ "$REALM_CREATE_STATUS" != "201" ] && [ "$REALM_CREATE_STATUS" != "409" ]; then
    echo "[setup] WARNING: Realm creation returned ${REALM_CREATE_STATUS}"
  fi
fi

###############################################
# KEYCLOAK: CREATE OIDC CLIENT
###############################################
echo "[setup] Creating OIDC client for GlitchTip..."
GLITCHTIP_CLIENT_SECRET="gt-oidc-secret-$(head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n')"

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
    "directAccessGrantsEnabled": true
  }'
  CLIENT_UUID=$(kc_api GET "/clients?clientId=glitchtip" | jq -r '.[0].id')
else
  GLITCHTIP_CLIENT_SECRET=$(kc_api GET "/clients/${CLIENT_UUID}/client-secret" | jq -r '.value')
fi

echo "[setup] Client UUID: ${CLIENT_UUID}"

###############################################
# KEYCLOAK: ADD GROUP MEMBERSHIP MAPPER
###############################################
echo "[setup] Adding group membership mapper..."

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

# platform-eng parent
PLATFORM_ENG_ID=$(kc_api GET "/groups?search=platform-eng" 2>/dev/null | \
  jq -r '.[] | select(.name=="platform-eng") | .id // empty')
if [ -z "$PLATFORM_ENG_ID" ]; then
  kc_api POST "/groups" -d '{"name": "platform-eng"}'
  PLATFORM_ENG_ID=$(kc_api GET "/groups?search=platform-eng" | jq -r '.[] | select(.name=="platform-eng") | .id')
fi

# glitchtip-owners under platform-eng
OWNERS_GROUP_ID=$(kc_api GET "/groups/${PLATFORM_ENG_ID}/children" 2>/dev/null | \
  jq -r '.[] | select(.name=="glitchtip-owners") | .id // empty')
if [ -z "$OWNERS_GROUP_ID" ]; then
  kc_api POST "/groups/${PLATFORM_ENG_ID}/children" -d '{"name": "glitchtip-owners"}'
  OWNERS_GROUP_ID=$(kc_api GET "/groups/${PLATFORM_ENG_ID}/children" | \
    jq -r '.[] | select(.name=="glitchtip-owners") | .id')
fi

# glitchtip-users under platform-eng
USERS_GROUP_ID=$(kc_api GET "/groups/${PLATFORM_ENG_ID}/children" 2>/dev/null | \
  jq -r '.[] | select(.name=="glitchtip-users") | .id // empty')
if [ -z "$USERS_GROUP_ID" ]; then
  kc_api POST "/groups/${PLATFORM_ENG_ID}/children" -d '{"name": "glitchtip-users"}'
  USERS_GROUP_ID=$(kc_api GET "/groups/${PLATFORM_ENG_ID}/children" | \
    jq -r '.[] | select(.name=="glitchtip-users") | .id')
fi

# Decoy groups
kc_api POST "/groups" -d '{"name": "glitchtip-owners"}' 2>/dev/null || true
ENG_GROUP_ID=$(kc_api GET "/groups?search=engineering" 2>/dev/null | \
  jq -r '.[] | select(.name=="engineering") | .id // empty')
if [ -z "$ENG_GROUP_ID" ]; then
  kc_api POST "/groups" -d '{"name": "engineering"}'
  ENG_GROUP_ID=$(kc_api GET "/groups?search=engineering" | jq -r '.[] | select(.name=="engineering") | .id')
fi
kc_api POST "/groups/${ENG_GROUP_ID}/children" -d '{"name": "glitchtip-admins"}' 2>/dev/null || true

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
      "credentials": [{"type": "password", "value": "'"${USER_PASS}"'", "temporary": false}]
    }'
    EXISTING_USER=$(kc_api GET "/users?username=${username}&exact=true" | jq -r '.[0].id')
  fi
  USER_IDS[${username}]="${EXISTING_USER}"
done

# Correct group memberships: alice+bob=owners, all=users
for username in alice bob; do
  kc_api_raw PUT "/users/${USER_IDS[${username}]}/groups/${OWNERS_GROUP_ID}" -d '{}'
  kc_api_raw PUT "/users/${USER_IDS[${username}]}/groups/${USERS_GROUP_ID}" -d '{}'
done
for username in charlie diana eve; do
  kc_api_raw PUT "/users/${USER_IDS[${username}]}/groups/${USERS_GROUP_ID}" -d '{}'
done

###############################################
# GLITCHTIP: CONFIGURE OIDC + CREATE USERS
###############################################
echo "[setup] Configuring GlitchTip OIDC..."

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
  OPENID_CONNECT_URL: "${KEYCLOAK_URL}/realms/${KC_REALM}/.well-known/openid-configuration"
  OPENID_CONNECT_CLIENT_ID: "glitchtip"
  OPENID_CONNECT_CLIENT_SECRET: "${GLITCHTIP_CLIENT_SECRET}"
  OPENID_CONNECT_SCOPE: "openid profile email groups"
  GLITCHTIP_OIDC_OWNER_GROUP: "/platform-eng/glitchtip-owners"
  GLITCHTIP_OIDC_MEMBER_GROUP: "/platform-eng/glitchtip-users"
EOF

# Patch GlitchTip web deployment to include OIDC config
kubectl patch deployment glitchtip-web -n glitchtip --type strategic -p '{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "glitchtip",
          "envFrom": [
            {"configMapRef": {"name": "glitchtip-config"}},
            {"secretRef": {"name": "glitchtip-secrets"}},
            {"configMapRef": {"name": "glitchtip-oidc-config"}}
          ]
        }]
      }
    }
  }
}'

kubectl rollout restart deployment glitchtip-web -n glitchtip
kubectl rollout status deployment glitchtip-web -n glitchtip --timeout=180s || true

# Wait for GlitchTip to come back
for i in $(seq 1 60); do
  if curl -sf -o /dev/null "${GLITCHTIP_URL}" 2>/dev/null; then break; fi
  sleep 5
done

# Create GlitchTip org + users via Django
GT_POD=$(kubectl get pods -n glitchtip -l app=glitchtip,component=web -o jsonpath='{.items[0].metadata.name}')

echo "[setup] Creating GlitchTip organization and users..."
kubectl exec -n glitchtip "${GT_POD}" -- python manage.py shell -c "
from django.contrib.auth import get_user_model
User = get_user_model()

# Ensure admin exists
admin = User.objects.filter(email='admin@devops.local').first()
if not admin:
    admin = User.objects.create_superuser(email='admin@devops.local', password='GlitchAdmin2024!')

# Create org
from apps.organizations_ext.models import Organization, OrganizationUser
org, _ = Organization.objects.get_or_create(name='DevOps Platform')
OrganizationUser.objects.get_or_create(organization=org, user=admin, defaults={'role': 3})

# Create users — ALL as owners (breakage)
for username in ['alice', 'bob', 'charlie', 'diana', 'eve']:
    user, created = User.objects.get_or_create(
        email=f'{username}@devops.local',
        defaults={'is_staff': False, 'is_superuser': False}
    )
    if created:
        user.set_password('DevOps2024!')
        user.save()
    ou, _ = OrganizationUser.objects.get_or_create(
        organization=org, user=user, defaults={'role': 3}
    )
    ou.role = 3  # 3=owner — THIS IS THE BREAKAGE
    ou.save()

print('GlitchTip users configured.')
" 2>/dev/null || echo "[setup] Warning: Django shell may have partial failure"

###############################################
# BREAKAGE 1: KEYCLOAK GROUP MEMBERSHIPS
###############################################
echo "[setup] BREAKAGE 1: Adding all users to glitchtip-owners group..."
for username in charlie diana eve; do
  kc_api_raw PUT "/users/${USER_IDS[${username}]}/groups/${OWNERS_GROUP_ID}" -d '{}'
done

###############################################
# BREAKAGE 2: GLITCHTIP OIDC CONFIGMAP
###############################################
echo "[setup] BREAKAGE 2: Corrupting GlitchTip OIDC config..."
kubectl patch configmap glitchtip-oidc-config -n glitchtip --type merge -p '{
  "data": {
    "OPENID_CONNECT_SCOPE": "openid profile email",
    "GLITCHTIP_OIDC_OWNER_GROUP": "glitchtip-owners"
  }
}'
kubectl rollout restart deployment glitchtip-web -n glitchtip
kubectl rollout status deployment glitchtip-web -n glitchtip --timeout=180s || true

###############################################
# BREAKAGE 3: ENFORCER CRONJOB + DECOY CRONJOB
###############################################
echo "[setup] BREAKAGE 3: Creating enforcer and decoy CronJobs..."

kubectl create secret generic keycloak-reconciler-creds -n keycloak \
  --from-literal=KC_ADMIN_USER="${KC_ADMIN_USER}" \
  --from-literal=KC_ADMIN_PASS="${KC_ADMIN_PASS}" \
  --from-literal=KC_REALM="${KC_REALM}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Decoy CronJob — obvious name but BENIGN (only logs, no changes)
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: keycloak-realm-config-reconciler
  namespace: keycloak
  labels:
    app: keycloak
    component: realm-reconciler
  annotations:
    description: "Reconciles realm configuration for SSO compliance"
spec:
  schedule: "*/5 * * * *"
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      backoffLimit: 1
      activeDeadlineSeconds: 60
      template:
        metadata:
          labels:
            app: keycloak
            job: realm-reconciler
        spec:
          restartPolicy: Never
          containers:
          - name: reconciler
            image: docker.io/curlimages/curl:8.7.1
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              KC_URL="http://keycloak.keycloak.svc.cluster.local:8080"
              TOKEN=$(curl -sf -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
                -d "client_id=admin-cli" \
                -d "grant_type=password" \
                -d "username=${KC_ADMIN_USER}" \
                -d "password=${KC_ADMIN_PASS}" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
              echo "Realm config reconciliation check complete. Token obtained: $([ -n "${TOKEN}" ] && echo yes || echo no)"
              echo "No changes needed."
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
EOF

# Real enforcer CronJob — innocuous name, actually re-corrupts groups
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: CronJob
metadata:
  name: keycloak-realm-backup-sync
  namespace: keycloak
  labels:
    app: keycloak
    component: realm-backup
  annotations:
    description: "Syncs realm backup state for disaster recovery compliance"
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
            job: realm-backup
        spec:
          restartPolicy: Never
          containers:
          - name: sync
            image: docker.io/curlimages/curl:8.7.1
            imagePullPolicy: IfNotPresent
            command:
            - /bin/sh
            - -c
            - |
              KC_URL="http://keycloak.keycloak.svc.cluster.local:8080"
              TOKEN=$(curl -sf -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
                -d "client_id=admin-cli" \
                -d "grant_type=password" \
                -d "username=${KC_ADMIN_USER}" \
                -d "password=${KC_ADMIN_PASS}" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
              [ -z "${TOKEN}" ] && exit 1
              PLATFORM_GID=$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
                "${KC_URL}/admin/realms/${KC_REALM}/groups?search=platform-eng" | \
                sed -n 's/.*"id":"\([^"]*\)".*"name":"platform-eng".*/\1/p')
              OWNERS_GID=$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
                "${KC_URL}/admin/realms/${KC_REALM}/groups/${PLATFORM_GID}/children" | \
                sed -n 's/.*"id":"\([^"]*\)".*"name":"glitchtip-owners".*/\1/p')
              for USERNAME in alice bob charlie diana eve; do
                USER_ID=$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
                  "${KC_URL}/admin/realms/${KC_REALM}/users?username=${USERNAME}&exact=true" | \
                  sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
                [ -n "${USER_ID}" ] && [ -n "${OWNERS_GID}" ] && \
                curl -sf -X PUT -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" \
                  "${KC_URL}/admin/realms/${KC_REALM}/users/${USER_ID}/groups/${OWNERS_GID}" -d '{}'
              done
              echo "Backup sync complete."
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
###############################################
echo "[setup] BREAKAGE 4: Creating restrictive NetworkPolicy..."

kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: glitchtip-default-deny-egress
  namespace: glitchtip
spec:
  podSelector: {}
  policyTypes:
  - Egress
---
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
      app: glitchtip
  policyTypes:
  - Egress
  egress:
  - to: []
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: glitchtip
  - to:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: keycloak
          sso-tier: identity
EOF

###############################################
# DECOY CONFIGMAPS + DISTRACTION CONTENT
###############################################
echo "[setup] Creating decoy ConfigMaps and documentation..."

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
    backup-date: "2024-11-15"
    restore-note: "Verified working config from pre-migration"
immutable: true
data:
  ENABLE_OPEN_ID_CONNECT: "true"
  OPENID_CONNECT_URL: "${KEYCLOAK_URL}/realms/${KC_REALM}/.well-known/openid-configuration"
  OPENID_CONNECT_CLIENT_ID: "glitchtip"
  OPENID_CONNECT_CLIENT_SECRET: "old-secret-rotated"
  OPENID_CONNECT_SCOPE: "openid profile email"
  GLITCHTIP_OIDC_OWNER_GROUP: "glitchtip-owners"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: glitchtip-oidc-config-v2
  namespace: glitchtip
  labels:
    app: glitchtip
    component: oidc-integration
    version: "v2"
  annotations:
    migration-date: "2025-01-20"
    status: "pending-review"
data:
  ENABLE_OPEN_ID_CONNECT: "true"
  OPENID_CONNECT_URL: "${KEYCLOAK_URL}/realms/${KC_REALM}/.well-known/openid-configuration"
  OPENID_CONNECT_CLIENT_ID: "glitchtip"
  OPENID_CONNECT_CLIENT_SECRET: "${GLITCHTIP_CLIENT_SECRET}"
  OPENID_CONNECT_SCOPE: "openid profile email groups"
  GLITCHTIP_OIDC_OWNER_GROUP: "/engineering/glitchtip-admins"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: glitchtip-incident-chat-log
  namespace: glitchtip
  labels:
    app: glitchtip
    component: documentation
    type: chat-export
  annotations:
    exported-from: "mattermost"
    channel: "platform-eng"
    date: "2025-03-15"
data:
  chat-export.md: |
    # Mattermost Export — #platform-eng channel
    ## March 15, 2025

    **@diana** [09:12 AM]
    hey has anyone else noticed they can see all the GlitchTip projects now?
    i can see backend-api and infra-monitoring which definitely aren't mine

    **@charlie** [09:14 AM]
    yeah same here, i thought it was just a UI bug. i can even delete stuff
    which is weird

    **@bob** [09:18 AM]
    that's not right. let me check the keycloak config
    we migrated to the new realm setup last month, might be related

    **@alice** [09:22 AM]
    @bob i looked at this yesterday actually. i think the issue is in how
    the oidc client maps groups. the old config used realm_access.roles
    but we switched to group-based mapping during the migration

    **@bob** [09:25 AM]
    right. i remember we had to set up the group mapper on the keycloak
    client. did someone change the scope config on the glitchtip side?

    **@alice** [09:28 AM]
    not sure. the config-backup configmap should have the last known
    good config if we need to roll back. i think @priya made that
    before she left

    **@diana** [09:31 AM]
    should i just restore from the backup configmap?

    **@bob** [09:33 AM]
    no don't do that yet, the backup might be from before the keycloak
    22 migration so the client secret would be wrong at minimum.
    let me look at it after standup

    **@charlie** [09:45 AM]
    fyi i also can't log in via SSO anymore. it just hangs when trying
    to redirect to keycloak. might be a network thing?

    **@bob** [10:02 AM]
    ok so i tried fixing the group memberships in keycloak manually but
    they keep reverting back after a few minutes. something is
    re-adding everyone to the owners group. i don't have time to dig
    into it rn, will look after sprint planning

    **@alice** [10:15 AM]
    that's weird. there shouldn't be anything automatically modifying
    keycloak groups. maybe one of the DR jobs? idk

    **@diana** [10:18 AM]
    isn't there a realm backup thing that runs every few minutes?
    maybe that's restoring old state?

    **@bob** [10:22 AM]
    could be. anyway gtg to standup, someone should ticket this
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: glitchtip-postmortem-2024-q3
  namespace: glitchtip
  labels:
    app: glitchtip
    component: documentation
    type: postmortem
  annotations:
    incident-date: "2024-09-18"
    status: "resolved"
data:
  postmortem.md: |
    # Post-Mortem: GlitchTip Authentication Outage
    ## September 18, 2024

    ### Summary
    GlitchTip SSO login was broken for ~4 hours after the Keycloak 21→22 upgrade.
    Root cause was the client secret rotation during upgrade that wasn't propagated
    to GlitchTip's OIDC configuration.

    ### Root Cause
    During the Keycloak upgrade, the glitchtip OIDC client secret was automatically
    rotated. The GlitchTip deployment still had the old secret in its environment
    variables via the glitchtip-oidc-config ConfigMap.

    ### Resolution
    1. Retrieved new client secret from Keycloak admin console
    2. Updated glitchtip-oidc-config ConfigMap with new secret
    3. Restarted GlitchTip web deployment to pick up new config
    4. Verified SSO login worked

    ### Lessons Learned
    - Always check client secret after Keycloak upgrades
    - The config-backup ConfigMap was outdated and useless
    - Consider automating secret rotation propagation

    ### Action Items
    - [x] Document Keycloak upgrade procedure
    - [x] Add monitoring for OIDC auth failures
    - [ ] Set up automated secret sync between Keycloak and app configs
    - [ ] Review group mapper settings (they were changed during migration
          but we haven't verified all downstream effects)

    ### Technical Notes
    - The Keycloak client uses group membership mapper for role assignment
    - During the v22 migration, we switched from realm roles to group-based
      OIDC claims. The old realm_access.roles approach was deprecated.
    - Group mapper configuration was set to use flat names for compatibility
      but this hasn't been fully tested with the new group hierarchy
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: keycloak-client-notes
  namespace: keycloak
  labels:
    app: keycloak
    component: documentation
data:
  NOTES.md: |
    # Keycloak Client Configuration Notes

    ## GlitchTip Client
    - Client ID: glitchtip
    - Protocol: openid-connect
    - The group membership mapper was updated during the v22 migration
    - Group mapper claim name: groups
    - Note: The flat name format (without path prefix) is recommended
      for compatibility with downstream applications that don't support
      hierarchical group matching.

    ## Scope Configuration
    - Default scopes should be sufficient for most integrations
    - The 'groups' scope was removed from default client scopes during
      the security hardening in Q4 2024 to reduce token size
    - Applications that need group claims should use the built-in
      group mapper on the client directly (no extra scope needed)

    ## Disaster Recovery
    - Realm state is backed up via automated sync jobs in this namespace
    - DO NOT delete the backup/sync CronJobs — they are required for
      compliance with the DR policy
    - Last DR audit: 2025-02-01 (passed)
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: keycloak-group-architecture
  namespace: keycloak
  labels:
    app: keycloak
    component: documentation
    type: wiki-export
  annotations:
    exported-from: "confluence"
    last-updated: "2024-08-12"
data:
  group-design.md: |
    # Keycloak Group Architecture (OUTDATED — pre-migration)

    > **WARNING**: This document was exported from Confluence and may not
    > reflect the current state after the Keycloak 22 migration.

    ## Group Hierarchy (as of August 2024)

    Our Keycloak realm uses flat top-level groups for application role mapping:

    - glitchtip-owners → maps to GlitchTip owner role
    - glitchtip-users → maps to GlitchTip member role
    - grafana-admins → maps to Grafana admin role
    - grafana-viewers → maps to Grafana viewer role

    ## Role Mapping Convention
    Applications should match group names WITHOUT path prefixes.
    Example: check for "glitchtip-owners" not "/some/path/glitchtip-owners"

    ## Migration Notes
    - Q4 2024: Planning to restructure groups under team-based parent
      groups (e.g., /platform-eng/glitchtip-owners) for better organization
    - This will require updating all downstream OIDC configurations to
      use full path matching instead of flat names
    - Status: NOT YET IMPLEMENTED (as of this document)

    ## Current Members
    | Group | Members |
    |-------|---------|
    | glitchtip-owners | alice, bob, priya (admin) |
    | glitchtip-users | charlie, diana, eve, frank, grace |
    | grafana-admins | alice, bob |
    | grafana-viewers | (all engineers) |

    *Note: priya left the company in Jan 2025 — her accounts should
    have been deprovisioned but verify this.*
EOF

###############################################
# STRIP ANNOTATIONS
###############################################
echo "[setup] Stripping annotations..."
for res in configmap/glitchtip-oidc-config configmap/glitchtip-oidc-config-backup configmap/glitchtip-oidc-config-v2 configmap/glitchtip-incident-chat-log configmap/glitchtip-postmortem-2024-q3; do
  kubectl annotate "$res" -n glitchtip kubectl.kubernetes.io/last-applied-configuration- 2>/dev/null || true
done
for res in configmap/keycloak-client-notes configmap/keycloak-group-architecture; do
  kubectl annotate "$res" -n keycloak kubectl.kubernetes.io/last-applied-configuration- 2>/dev/null || true
done
kubectl annotate networkpolicy/glitchtip-egress-policy -n glitchtip kubectl.kubernetes.io/last-applied-configuration- 2>/dev/null || true
kubectl annotate networkpolicy/glitchtip-default-deny-egress -n glitchtip kubectl.kubernetes.io/last-applied-configuration- 2>/dev/null || true
kubectl annotate cronjob/keycloak-realm-config-reconciler -n keycloak kubectl.kubernetes.io/last-applied-configuration- 2>/dev/null || true
kubectl annotate cronjob/keycloak-realm-backup-sync -n keycloak kubectl.kubernetes.io/last-applied-configuration- 2>/dev/null || true

###############################################
# SAVE SETUP INFO FOR GRADER
###############################################
echo "[setup] Saving setup info..."
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
OWNER_USERS=alice,bob
MEMBER_USERS=charlie,diana,eve
USER_PASS=${USER_PASS}
ALICE_ID=${USER_IDS[alice]}
BOB_ID=${USER_IDS[bob]}
CHARLIE_ID=${USER_IDS[charlie]}
DIANA_ID=${USER_IDS[diana]}
EVE_ID=${USER_IDS[eve]}
SETUP_EOF
chmod 600 /root/.setup_info

echo "[setup] ============================================"
echo "[setup] Setup complete. All breakages applied."
echo "[setup] ============================================"
