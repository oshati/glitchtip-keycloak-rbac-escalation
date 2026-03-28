#!/usr/bin/env python3
"""
Grader for glitchtip-keycloak-rbac-escalation task.

ALL checks are end-to-end FUNCTIONAL tests — they verify actual system behavior,
not configuration file values.

5 subscores, each weight 1/5:
1. drift_neutralized — Group memberships stay correct over the durability window
2. sso_path_repaired — GlitchTip can reach Keycloak and owner group is correct
3. identity_claims_correct — alice gets owner claim, charlie does not
4. owner_can_manage_org — alice can create an organization team in GlitchTip
5. member_cannot_manage_org — charlie is forbidden from the same owner-level action
"""

import base64
import json
import os
import shlex
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
import http.cookiejar

from apex_arena._types import GradingResult


def run_cmd(cmd, timeout=30):
    """Run a shell command and return (returncode, stdout, stderr)."""
    try:
        result = subprocess.run(
            cmd, shell=True, capture_output=True, text=True, timeout=timeout
        )
        return result.returncode, result.stdout.strip(), result.stderr.strip()
    except subprocess.TimeoutExpired:
        return 1, "", "timeout"
    except Exception as e:
        return 1, "", str(e)


def load_setup_info():
    """Load setup info saved by setup.sh."""
    info = {}
    try:
        with open("/root/.setup_info") as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    key, value = line.split("=", 1)
                    info[key] = value
    except FileNotFoundError:
        pass
    return info


def get_kc_admin_token(setup_info):
    """Get Keycloak admin token via master realm."""
    kc_url = "http://keycloak.keycloak.svc.cluster.local:8080"
    kc_pass = setup_info.get("KC_ADMIN_PASS", "admin123")

    for attempt in range(5):
        rc, stdout, _ = run_cmd(
            f'curl -s --connect-timeout 10 --max-time 15 -X POST '
            f'"{kc_url}/realms/master/protocol/openid-connect/token" '
            f'-d "client_id=admin-cli" '
            f'-d "grant_type=password" '
            f'-d "username=admin" '
            f'-d "password={kc_pass}"'
        )
        if rc == 0 and stdout:
            try:
                token = json.loads(stdout).get("access_token")
                if token:
                    return token
            except json.JSONDecodeError:
                pass
        time.sleep(5)
    return None


def get_user_oidc_token(setup_info, username, password="DevOps2024!"):
    """
    Get a user's OIDC token via the glitchtip client in the devops realm.
    Uses default client scopes — does NOT explicitly request 'groups' scope.
    The 'groups' scope must be a default client scope for groups to appear.
    If password fails, reset the user's password via admin API and retry.
    """
    kc_url = "http://keycloak.keycloak.svc.cluster.local:8080"
    realm = setup_info.get("KC_REALM", "devops")
    client_secret = setup_info.get("GLITCHTIP_CLIENT_SECRET", "")

    rc, stdout, _ = run_cmd(
        f'curl -s --connect-timeout 10 --max-time 15 -X POST '
        f'"{kc_url}/realms/{realm}/protocol/openid-connect/token" '
        f'-d "client_id=glitchtip" '
        f'-d "client_secret={client_secret}" '
        f'-d "grant_type=password" '
        f'-d "username={username}" '
        f'-d "password={password}"'
    )

    if stdout:
        try:
            resp = json.loads(stdout)
            token = resp.get("access_token")
            if token:
                return token, None
        except json.JSONDecodeError:
            pass

    # Password may have been changed by the agent — reset it via admin API
    print(f"[grader] Password grant failed for {username}, resetting password...")
    admin_token = get_kc_admin_token(setup_info)
    if admin_token:
        # Find user ID
        rc, user_json, _ = run_cmd(
            f'curl -s -H "Authorization: Bearer {admin_token}" '
            f'"{kc_url}/admin/realms/{realm}/users?username={username}&exact=true"'
        )
        try:
            user_id = json.loads(user_json)[0]["id"]
            # Reset password
            run_cmd(
                f'curl -s -X PUT -H "Authorization: Bearer {admin_token}" '
                f'-H "Content-Type: application/json" '
                f'"{kc_url}/admin/realms/{realm}/users/{user_id}/reset-password" '
                f'-d \'{{"type":"password","value":"{password}","temporary":false}}\''
            )
            # Retry token
            rc, stdout, _ = run_cmd(
                f'curl -s --connect-timeout 10 --max-time 15 -X POST '
                f'"{kc_url}/realms/{realm}/protocol/openid-connect/token" '
                f'-d "client_id=glitchtip" '
                f'-d "client_secret={client_secret}" '
                f'-d "grant_type=password" '
                f'-d "username={username}" '
                f'-d "password={password}"'
            )
            if stdout:
                try:
                    resp = json.loads(stdout)
                    token = resp.get("access_token")
                    if token:
                        return token, None
                    return None, resp.get("error_description", "no token after reset")
                except json.JSONDecodeError:
                    pass
        except (json.JSONDecodeError, KeyError, IndexError):
            pass

    return None, "Failed to get token even after password reset"


def decode_jwt_groups(token):
    """Decode JWT and extract groups claim."""
    try:
        payload_b64 = token.split(".")[1]
        payload_b64 += "=" * (4 - len(payload_b64) % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_b64))
        return payload.get("groups", []), None
    except Exception as e:
        return [], f"JWT decode error: {e}"


def get_glitchtip_pod():
    rc, gt_pod, _ = run_cmd(
        "kubectl get pods -n glitchtip -l app=glitchtip,component=web "
        "-o jsonpath='{.items[0].metadata.name}' 2>/dev/null"
    )
    return gt_pod.strip("'") if gt_pod else ""


def reset_glitchtip_local_password(email, password="DevOps2024!"):
    """Ensure local GlitchTip login works even if the agent changed the password."""
    gt_pod = get_glitchtip_pod()
    if not gt_pod:
        return False, "No GlitchTip pod found"

    script = (
        "from django.contrib.auth import get_user_model\n"
        "User = get_user_model()\n"
        f"user = User.objects.filter(email={email!r}).first()\n"
        "assert user is not None, 'user missing'\n"
        f"user.set_password({password!r})\n"
        "user.save(update_fields=['password'])\n"
        "print('ok')\n"
    )
    shell_cmd = shlex.quote(
        f"cd /code && python manage.py shell -c {shlex.quote(script)}"
    )
    rc, stdout, stderr = run_cmd(
        f"kubectl exec -n glitchtip {gt_pod} -- bash -lc {shell_cmd}",
        timeout=30,
    )
    if rc != 0:
        return False, stderr[:200] or stdout[:200]
    return True, "password reset"


def glitchtip_team_exists(org_slug, team_slug):
    gt_pod = get_glitchtip_pod()
    if not gt_pod:
        return False, "No GlitchTip pod found"

    script = (
        "from apps.teams.models import Team\n"
        f"exists = Team.objects.filter(slug={team_slug!r}, organization__slug={org_slug!r}).exists()\n"
        "print('1' if exists else '0')\n"
    )
    shell_cmd = shlex.quote(
        f"cd /code && python manage.py shell -c {shlex.quote(script)}"
    )
    rc, stdout, stderr = run_cmd(
        f"kubectl exec -n glitchtip {gt_pod} -- bash -lc {shell_cmd}",
        timeout=30,
    )
    if rc != 0:
        return False, stderr[:200] or stdout[:200]
    return stdout.strip().endswith("1"), None


def login_and_create_team(email, password, org_slug, team_slug):
    """
    FUNCTIONAL: log into GlitchTip with a session and attempt an owner-level action.
    Returns (status_code, response_snippet, created_bool_or_None, error_or_None).
    """
    login_ok, detail = reset_glitchtip_local_password(email, password)
    if not login_ok:
        return 0, "", None, f"Could not reset local password: {detail}"

    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))

    def csrf_token():
        for cookie in jar:
            if cookie.name == "csrftoken":
                return cookie.value
        return ""

    try:
        opener.open(
            urllib.request.Request(
                "http://glitchtip.devops.local/_allauth/browser/v1/config",
                method="GET",
            ),
            timeout=15,
        )
    except Exception as exc:
        return 0, "", None, f"Config bootstrap failed: {exc}"

    token = csrf_token()
    if not token:
        return 0, "", None, "No csrftoken cookie after config bootstrap"

    login_req = urllib.request.Request(
        "http://glitchtip.devops.local/_allauth/browser/v1/auth/login",
        data=json.dumps({"email": email, "password": password}).encode(),
        headers={
            "Content-Type": "application/json",
            "X-CSRFToken": token,
        },
        method="POST",
    )
    try:
        with opener.open(login_req, timeout=15) as resp:
            login_status = resp.getcode()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(200).decode(errors="ignore"), None, "Login failed"
    except Exception as exc:
        return 0, "", None, f"Login request failed: {exc}"

    if login_status not in (200, 201, 204):
        return login_status, "", None, f"Unexpected login status {login_status}"

    token = csrf_token()
    if not token:
        return 0, "", None, "No csrftoken cookie after login"

    create_req = urllib.request.Request(
        f"http://glitchtip.devops.local/api/0/organizations/{org_slug}/teams/",
        data=json.dumps({"slug": team_slug, "name": team_slug}).encode(),
        headers={
            "Content-Type": "application/json",
            "X-CSRFToken": token,
        },
        method="POST",
    )
    try:
        with opener.open(create_req, timeout=15) as resp:
            status = resp.getcode()
            body = resp.read(300).decode(errors="ignore")
    except urllib.error.HTTPError as exc:
        status = exc.code
        body = exc.read(300).decode(errors="ignore")
    except Exception as exc:
        return 0, "", None, f"Team create request failed: {exc}"

    created, created_err = glitchtip_team_exists(org_slug, team_slug)
    if created_err:
        return status, body, None, created_err

    return status, body[:200], created, None


def check_drift_neutralized(setup_info):
    """
    FUNCTIONAL: Verify group memberships stay correct (not re-corrupted by enforcer).
    The 90s durability window already elapsed before this check runs.
    If the enforcer is still active, groups will have been re-corrupted.
    """
    kc_url = "http://keycloak.keycloak.svc.cluster.local:8080"
    realm = setup_info.get("KC_REALM", "devops")
    owners_group_id = setup_info.get("OWNERS_GROUP_ID", "")

    token = get_kc_admin_token(setup_info)
    if not token or not owners_group_id:
        return 0.0, "Could not get Keycloak admin token or owners group ID"

    rc, stdout, _ = run_cmd(
        f'curl -s -H "Authorization: Bearer {token}" '
        f'"{kc_url}/admin/realms/{realm}/groups/{owners_group_id}/members"'
    )

    try:
        members = json.loads(stdout)
        usernames = sorted([m["username"] for m in members])
    except (json.JSONDecodeError, KeyError):
        return 0.0, f"Failed to parse group members: {stdout[:200]}"

    if usernames == ["alice", "bob"]:
        return 1.0, f"Groups stable after durability window: {usernames}"
    else:
        return 0.0, f"Groups re-corrupted (enforcer still active): {usernames}"


def check_sso_path_repaired(setup_info):
    """
    FUNCTIONAL: GlitchTip pod can reach Keycloak OIDC discovery endpoint
    AND only alice, bob are in the owners group.
    """
    realm = setup_info.get("KC_REALM", "devops")
    owners_group_id = setup_info.get("OWNERS_GROUP_ID", "")

    # Find GlitchTip pod
    rc, gt_pod, _ = run_cmd(
        "kubectl get pods -n glitchtip -l app=glitchtip,component=web "
        "-o jsonpath='{.items[0].metadata.name}' 2>/dev/null"
    )
    gt_pod = gt_pod.strip("'") if gt_pod else ""
    if not gt_pod:
        return 0.0, "No GlitchTip pod found"

    # Test connectivity from inside the pod
    connectivity_ok = False
    for attempt in range(10):
        for url in [
            "http://keycloak.devops.local:8080",
            "http://keycloak.keycloak.svc.cluster.local:8080",
        ]:
            rc, stdout, _ = run_cmd(
                f"kubectl exec -n glitchtip {gt_pod} -- "
                f"python -c \"import urllib.request; r = urllib.request.urlopen("
                f"'{url}/realms/{realm}/.well-known/openid-configuration', timeout=5); "
                f"print(r.status)\"",
                timeout=15,
            )
            if rc == 0 and "200" in stdout:
                connectivity_ok = True
                break
        if connectivity_ok:
            break
        time.sleep(3)

    if not connectivity_ok:
        return 0.0, "GlitchTip pod cannot reach Keycloak OIDC endpoint"

    # Verify group membership via Keycloak API
    kc_url = "http://keycloak.keycloak.svc.cluster.local:8080"
    token = get_kc_admin_token(setup_info)
    if not token or not owners_group_id:
        return 0.0, "Connectivity OK but could not check groups"

    rc, stdout, _ = run_cmd(
        f'curl -s -H "Authorization: Bearer {token}" '
        f'"{kc_url}/admin/realms/{realm}/groups/{owners_group_id}/members"'
    )

    try:
        members = json.loads(stdout)
        usernames = sorted([m["username"] for m in members])
    except (json.JSONDecodeError, KeyError):
        return 0.0, "Connectivity OK but failed to parse group members"

    if usernames == ["alice", "bob"]:
        return 1.0, f"Connectivity OK and owners group correct: {usernames}"
    else:
        return 0.0, f"Connectivity OK but owners group wrong: {usernames}"


def check_identity_claims_correct(setup_info):
    """
    FUNCTIONAL END-TO-END: Get an OIDC token for alice (owner) via the glitchtip
    client using DEFAULT scopes only. Verify the token contains
    /platform-eng/glitchtip-owners in the groups claim.

    This proves:
    - The 'groups' client scope is configured as a default scope on the client
    - The group membership mapper produces full paths
    - Alice is in the correct group
    - The entire OIDC token pipeline works
    """
    owner_token, error = get_user_oidc_token(setup_info, "alice")
    if not owner_token:
        return 0.0, f"Could not get OIDC token for alice: {error}"

    owner_groups, error = decode_jwt_groups(owner_token)
    if error:
        return 0.0, error

    if "/platform-eng/glitchtip-owners" not in owner_groups:
        if not owner_groups:
            return 0.0, "Alice's token has NO groups claim (groups scope not in default client scopes?)"
        return 0.0, f"Alice's token missing owners group. Groups: {owner_groups}"

    member_token, error = get_user_oidc_token(setup_info, "charlie")
    if not member_token:
        return 0.0, f"Could not get OIDC token for charlie: {error}"

    member_groups, error = decode_jwt_groups(member_token)
    if error:
        return 0.0, error

    if "/platform-eng/glitchtip-owners" in member_groups:
        return 0.0, f"Charlie's token still contains owners group: {member_groups}"

    # Also verify GlitchTip pod has correct OIDC env vars applied
    gt_pod = get_glitchtip_pod()
    if gt_pod:
        rc, env_scope, _ = run_cmd(
            f"kubectl exec -n glitchtip {gt_pod} -- printenv OPENID_CONNECT_SCOPE 2>/dev/null",
            timeout=10,
        )
        rc2, env_group, _ = run_cmd(
            f"kubectl exec -n glitchtip {gt_pod} -- printenv GLITCHTIP_OIDC_OWNER_GROUP 2>/dev/null",
            timeout=10,
        )
        if env_scope and "groups" not in env_scope:
            return 0.0, f"Token OK but pod env OPENID_CONNECT_SCOPE missing 'groups': '{env_scope}'"
        if env_group and env_group != "/platform-eng/glitchtip-owners":
            return 0.0, f"Token OK but pod env GLITCHTIP_OIDC_OWNER_GROUP wrong: '{env_group}'"

    return 1.0, (
        "Alice gets owner claim, Charlie does not, and GlitchTip env is correct. "
        f"Alice groups: {owner_groups}; Charlie groups: {member_groups}"
    )


def check_owner_can_manage_org(setup_info):
    """
    FUNCTIONAL: Alice must be able to perform an owner-level GlitchTip action.
    We use organization team creation through the real HTTP API.
    """
    org_slug = setup_info.get("ORG_SLUG", "devops-platform")
    team_slug = f"owner-check-{int(time.time())}"
    status, body, created, error = login_and_create_team(
        "alice@devops.local", "DevOps2024!", org_slug, team_slug
    )
    if error:
        return 0.0, error
    if status in (200, 201) and created:
        return 1.0, f"Alice created team '{team_slug}' (HTTP {status})"
    return 0.0, f"Alice could not create team (HTTP {status}, created={created}): {body}"


def check_member_cannot_manage_org(setup_info):
    """
    FUNCTIONAL: Charlie must be forbidden from the same owner-level action.
    """
    org_slug = setup_info.get("ORG_SLUG", "devops-platform")
    team_slug = f"member-check-{int(time.time())}"
    status, body, created, error = login_and_create_team(
        "charlie@devops.local", "DevOps2024!", org_slug, team_slug
    )
    if error:
        return 0.0, error
    if status in (401, 403, 404) and not created:
        return 1.0, f"Charlie correctly forbidden from creating team (HTTP {status})"
    return 0.0, (
        f"Charlie unexpectedly managed owner action (HTTP {status}, created={created}): {body}"
    )


def grade(*args, **kwargs) -> GradingResult:
    """Main grading function. ALL checks are functional end-to-end tests."""
    os.environ["KUBECONFIG"] = "/etc/rancher/k3s/k3s.yaml"
    setup_info = load_setup_info()

    # Pre-cleanup: kill any ubuntu background processes
    run_cmd("pkill -u ubuntu 2>/dev/null || true")

    # Durability window — if the enforcer is still active, it will re-corrupt
    # NOTE: We do NOT un-suspend CronJobs — suspension is a valid fix
    print("[grader] Waiting 300s durability window...")
    time.sleep(300)

    checks = {
        "drift_neutralized": check_drift_neutralized,
        "sso_path_repaired": check_sso_path_repaired,
        "identity_claims_correct": check_identity_claims_correct,
        "owner_can_manage_org": check_owner_can_manage_org,
        "member_cannot_manage_org": check_member_cannot_manage_org,
    }

    weight = 1.0 / len(checks)
    subscores = {}
    weights = {}
    feedback_parts = []

    for name, check_fn in checks.items():
        try:
            score, feedback = check_fn(setup_info)
        except Exception as e:
            score, feedback = 0.0, f"Exception: {e}"

        subscores[name] = score
        weights[name] = weight
        feedback_parts.append(
            f"[{name}] {'PASS' if score > 0 else 'FAIL'}: {feedback}"
        )
        print(f"[grader] {name}: {score} — {feedback}")

    total_score = sum(subscores[k] * weights[k] for k in subscores)
    feedback_str = "\n".join(feedback_parts)

    print(f"\n[grader] Final score: {total_score:.4f}")
    return GradingResult(
        score=total_score,
        subscores=subscores,
        weights=weights,
        feedback=feedback_str,
    )


if __name__ == "__main__":
    result = grade()
    print(f"\nScore: {result.score}")
    print(f"Subscores: {result.subscores}")
