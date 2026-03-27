#!/usr/bin/env python3
"""
Grader for glitchtip-keycloak-rbac-escalation task.

ALL checks are end-to-end FUNCTIONAL tests — they verify actual system behavior,
not configuration file values.

5 subscores, each weight 1/5:
1. enforcer_neutralized — Group memberships stay correct over 90s (not re-corrupted)
2. keycloak_groups_and_connectivity — GlitchTip pod can reach Keycloak AND owner group has only alice, bob
3. owner_token_has_groups — alice's OIDC token contains /platform-eng/glitchtip-owners in groups claim
4. user_roles_demoted — charlie, diana, eve have member role (not owner) in GlitchTip database
5. non_owner_token_excludes_group — charlie's OIDC token does NOT contain /platform-eng/glitchtip-owners
"""

import base64
import json
import os
import subprocess
import time

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


def check_enforcer_neutralized(setup_info):
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


def check_keycloak_groups_and_connectivity(setup_info):
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


def check_owner_token_has_groups(setup_info):
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
    token, error = get_user_oidc_token(setup_info, "alice")
    if not token:
        return 0.0, f"Could not get OIDC token for alice: {error}"

    groups, error = decode_jwt_groups(token)
    if error:
        return 0.0, error

    if "/platform-eng/glitchtip-owners" not in groups:
        if not groups:
            return 0.0, "Alice's token has NO groups claim (groups scope not in default client scopes?)"
        return 0.0, f"Alice's token missing owners group. Groups: {groups}"

    # Also verify GlitchTip pod has correct OIDC env vars applied
    rc, gt_pod, _ = run_cmd(
        "kubectl get pods -n glitchtip -l app=glitchtip,component=web "
        "-o jsonpath='{.items[0].metadata.name}' 2>/dev/null"
    )
    gt_pod = gt_pod.strip("'") if gt_pod else ""
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

    return 1.0, f"Alice's token contains owners group AND GlitchTip env correct. Groups: {groups}"


def check_user_roles_demoted(setup_info):
    """
    FUNCTIONAL: Query GlitchTip's actual database to verify charlie, diana, eve
    have member role (not owner). The database IS the source of truth for
    application-level permissions.
    """
    rc, gt_pod, _ = run_cmd(
        "kubectl get pods -n glitchtip -l app=glitchtip,component=web "
        "-o jsonpath='{.items[0].metadata.name}' 2>/dev/null"
    )
    gt_pod = gt_pod.strip("'") if gt_pod else ""
    if not gt_pod:
        return 0.0, "No GlitchTip pod found"

    check_script = (
        'import json\n'
        'from django.contrib.auth import get_user_model\n'
        'from apps.organizations_ext.models import OrganizationUser\n'
        'User = get_user_model()\n'
        'results = {}\n'
        'for email in ["charlie@devops.local", "diana@devops.local", "eve@devops.local"]:\n'
        '    try:\n'
        '        user = User.objects.get(email=email)\n'
        '        org_users = OrganizationUser.objects.filter(user=user)\n'
        '        roles = [ou.role for ou in org_users]\n'
        '        results[email] = {"roles": roles, "is_owner": 3 in roles}\n'
        '    except User.DoesNotExist:\n'
        '        results[email] = {"roles": [], "is_owner": False, "error": "not found"}\n'
        'print(json.dumps(results))\n'
    )

    with open("/tmp/gt_check_roles.py", "w") as f:
        f.write(check_script)

    run_cmd(
        f"kubectl cp /tmp/gt_check_roles.py glitchtip/{gt_pod}:/tmp/gt_check_roles.py",
        timeout=10,
    )

    rc, stdout, stderr = run_cmd(
        f"kubectl exec -n glitchtip {gt_pod} -- "
        f"bash -c 'cd /code && python manage.py shell < /tmp/gt_check_roles.py'",
        timeout=30,
    )

    if rc != 0:
        return 0.0, f"Failed to query roles: {stderr[:200]}"

    try:
        json_line = [l for l in stdout.split("\n") if l.startswith("{")]
        if not json_line:
            return 0.0, f"No JSON output: {stdout[:200]}"
        results = json.loads(json_line[-1])
    except (json.JSONDecodeError, IndexError):
        return 0.0, f"Parse error: {stdout[:200]}"

    all_demoted = True
    parts = []
    for email in ["charlie@devops.local", "diana@devops.local", "eve@devops.local"]:
        info = results.get(email, {})
        if info.get("is_owner", True):
            all_demoted = False
            parts.append(f"{email} still owner")
        else:
            parts.append(f"{email} demoted")

    if all_demoted:
        return 1.0, "All demoted: " + "; ".join(parts)
    else:
        return 0.0, "Still owners: " + "; ".join(parts)


def check_non_owner_token_excludes_group(setup_info):
    """
    FUNCTIONAL END-TO-END: Get an OIDC token for charlie (non-owner) via the
    glitchtip client. Verify /platform-eng/glitchtip-owners is NOT in the
    groups claim. This proves the group membership fix is working end-to-end
    through the OIDC pipeline.
    """
    token, error = get_user_oidc_token(setup_info, "charlie")
    if not token:
        return 0.0, f"Could not get OIDC token for charlie: {error}"

    groups, error = decode_jwt_groups(token)
    if error:
        return 0.0, error

    if "/platform-eng/glitchtip-owners" in groups:
        return 0.0, f"Charlie's token still contains owners group: {groups}"
    else:
        return 1.0, f"Charlie correctly excluded from owners. Groups: {groups}"


def grade(*args, **kwargs) -> GradingResult:
    """Main grading function. ALL checks are functional end-to-end tests."""
    os.environ["KUBECONFIG"] = "/etc/rancher/k3s/k3s.yaml"
    setup_info = load_setup_info()

    # Pre-cleanup: kill any ubuntu background processes
    run_cmd("pkill -u ubuntu 2>/dev/null || true")

    # Durability window — if the enforcer is still active, it will re-corrupt
    # NOTE: We do NOT un-suspend CronJobs — suspension is a valid fix
    print("[grader] Waiting 150s durability window...")
    time.sleep(150)

    checks = {
        "enforcer_neutralized": check_enforcer_neutralized,
        "keycloak_groups_and_connectivity": check_keycloak_groups_and_connectivity,
        "owner_token_has_groups": check_owner_token_has_groups,
        "user_roles_demoted": check_user_roles_demoted,
        "non_owner_token_excludes_group": check_non_owner_token_excludes_group,
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
