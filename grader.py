#!/usr/bin/env python3
"""
Grader for glitchtip-keycloak-rbac-escalation task.

5 subscores, each weight 1/5, each testing ONE thing:
1. enforcer_neutralized — The CronJob is no longer re-corrupting group memberships (deleted, suspended, or fixed)
2. keycloak_groups_and_connectivity — GlitchTip can reach Keycloak AND only alice, bob in owners group
3. oidc_config_correct — OIDC scope includes 'groups' AND owner group uses full path
4. user_roles_demoted — Non-admin users have member role in GlitchTip
5. sso_role_mapping_functional — End-to-end: Keycloak token for a non-admin user does NOT contain the owners group
"""

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


def get_kc_token(setup_info, username="admin", password=None):
    """Get Keycloak token. Uses k8s service DNS for reliability."""
    kc_url = "http://keycloak.keycloak.svc.cluster.local:8080"
    if password is None:
        password = setup_info.get("KC_ADMIN_PASS", "admin123")

    for attempt in range(5):
        rc, stdout, stderr = run_cmd(
            f'curl -s --connect-timeout 10 --max-time 15 -X POST '
            f'"{kc_url}/realms/master/protocol/openid-connect/token" '
            f'-d "client_id=admin-cli" '
            f'-d "grant_type=password" '
            f'-d "username={username}" '
            f'-d "password={password}"'
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


def get_user_token(setup_info, username, password="DevOps2024!"):
    """Get Keycloak token for a regular user via the devops realm."""
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
        f'-d "password={password}" '
        f'-d "scope=openid profile email groups"'
    )
    if rc == 0 and stdout:
        try:
            return json.loads(stdout).get("access_token")
        except json.JSONDecodeError:
            pass
    return None


def check_enforcer_neutralized(setup_info):
    """
    Check that the enforcer CronJob is no longer actively re-corrupting config.
    Accepts: deleted, suspended, or modified to no longer add wrong users.
    Score: 1.0 if neutralized, 0.0 if still re-corrupting.
    """
    # Check if CronJob exists
    rc, stdout, _ = run_cmd(
        "kubectl get cronjob keycloak-cert-renewal-check -n keycloak "
        "-o json 2>/dev/null"
    )

    if rc != 0 or not stdout:
        # CronJob deleted — neutralized
        return 1.0, "Enforcer CronJob deleted"

    try:
        cj = json.loads(stdout)
    except json.JSONDecodeError:
        return 1.0, "Enforcer CronJob not found (parse error)"

    # Check if suspended
    if cj.get("spec", {}).get("suspend", False):
        return 1.0, "Enforcer CronJob suspended"

    # CronJob exists and is not suspended — check if it was modified
    # to no longer add wrong users (check if charlie/diana/eve are NOT
    # in the script). This is a functional check via the group membership.
    # If groups are correct despite CronJob running, agent fixed the script.
    kc_url = "http://keycloak.keycloak.svc.cluster.local:8080"
    realm = setup_info.get("KC_REALM", "devops")
    owners_group_id = setup_info.get("OWNERS_GROUP_ID", "")

    token = get_kc_token(setup_info)
    if not token or not owners_group_id:
        return 0.0, "Enforcer CronJob still active and could not verify group state"

    rc, stdout, _ = run_cmd(
        f'curl -s -H "Authorization: Bearer {token}" '
        f'"{kc_url}/admin/realms/{realm}/groups/{owners_group_id}/members"'
    )

    try:
        members = json.loads(stdout)
        usernames = sorted([m["username"] for m in members])
    except (json.JSONDecodeError, KeyError):
        return 0.0, "Enforcer CronJob still active and group state could not be verified"

    # If groups are correct despite CronJob existing, agent must have fixed the script
    if usernames == ["alice", "bob"]:
        return 1.0, "Enforcer CronJob modified — groups remain correct"
    else:
        return 0.0, f"Enforcer CronJob still active, groups corrupted: {usernames}"


def check_keycloak_groups_and_connectivity(setup_info):
    """
    Check that GlitchTip can reach Keycloak AND only alice, bob are in owners group.
    Score: 1.0 if both pass, 0.0 otherwise.
    """
    kc_url = "http://keycloak.keycloak.svc.cluster.local:8080"
    realm = setup_info.get("KC_REALM", "devops")
    owners_group_id = setup_info.get("OWNERS_GROUP_ID", "")

    # Check connectivity from GlitchTip pod
    rc, gt_pod, _ = run_cmd(
        "kubectl get pods -n glitchtip -l app=glitchtip,component=web "
        "-o jsonpath='{.items[0].metadata.name}' 2>/dev/null"
    )
    gt_pod = gt_pod.strip("'") if gt_pod else ""

    if not gt_pod:
        return 0.0, "No GlitchTip pod found"

    connectivity_ok = False
    for attempt in range(10):
        for url in ["http://keycloak.devops.local:8080", "http://keycloak.keycloak.svc.cluster.local:8080"]:
            rc, stdout, _ = run_cmd(
                f"kubectl exec -n glitchtip {gt_pod} -- "
                f"python -c \"import urllib.request; r = urllib.request.urlopen('{url}/realms/{realm}/.well-known/openid-configuration', timeout=5); print(r.status)\"",
                timeout=15,
            )
            if rc == 0 and "200" in stdout:
                connectivity_ok = True
                break
        if connectivity_ok:
            break
        time.sleep(3)

    if not connectivity_ok:
        return 0.0, "GlitchTip cannot reach Keycloak OIDC endpoint"

    # Check group membership
    token = get_kc_token(setup_info)
    if not token or not owners_group_id:
        return 0.0, "Connectivity OK but could not get Keycloak token to check groups"

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
        return 0.0, f"Connectivity OK but owners group wrong: {usernames} (expected [alice, bob])"


def check_oidc_config_correct(setup_info):
    """
    Check that OIDC scope includes 'groups' AND owner group uses full path.
    Also verifies the running pod has the corrected env vars applied (deployment was restarted).
    Score: 1.0 if both correct AND pod has correct env, 0.0 otherwise.
    """
    # Check ConfigMap values
    rc, scope_out, _ = run_cmd(
        "kubectl get configmap glitchtip-oidc-config -n glitchtip "
        "-o jsonpath='{.data.OPENID_CONNECT_SCOPE}'"
    )
    scope = scope_out.strip("'") if scope_out else ""

    rc2, group_out, _ = run_cmd(
        "kubectl get configmap glitchtip-oidc-config -n glitchtip "
        "-o jsonpath='{.data.GLITCHTIP_OIDC_OWNER_GROUP}'"
    )
    owner_group = group_out.strip("'") if group_out else ""

    scope_ok = "groups" in scope.split()
    path_ok = owner_group == "/platform-eng/glitchtip-owners"

    if not (scope_ok and path_ok):
        parts = []
        if not scope_ok:
            parts.append(f"scope missing 'groups' (got '{scope}')")
        if not path_ok:
            parts.append(f"owner group wrong (got '{owner_group}')")
        return 0.0, "OIDC config incorrect: " + "; ".join(parts)

    # Verify the running pod actually has the corrected env vars (deployment was restarted)
    rc, gt_pod, _ = run_cmd(
        "kubectl get pods -n glitchtip -l app=glitchtip,component=web "
        "-o jsonpath='{.items[0].metadata.name}' 2>/dev/null"
    )
    gt_pod = gt_pod.strip("'") if gt_pod else ""

    if gt_pod:
        rc, pod_scope, _ = run_cmd(
            f"kubectl exec -n glitchtip {gt_pod} -- "
            f"python -c \"import os; print(os.environ.get('OPENID_CONNECT_SCOPE', ''))\"",
            timeout=15,
        )
        pod_scope = pod_scope.strip()
        if pod_scope and "groups" not in pod_scope.split():
            return 0.0, f"ConfigMap correct but pod still has old scope: '{pod_scope}' (deployment not restarted?)"

    return 1.0, f"OIDC config correct and applied: scope='{scope}', group='{owner_group}'"


def check_user_roles_demoted(setup_info):
    """
    Check that charlie, diana, eve have member role (not owner) in GlitchTip.
    Score: 1.0 if all three are demoted, 0.0 otherwise.
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

    run_cmd(f"kubectl cp /tmp/gt_check_roles.py glitchtip/{gt_pod}:/tmp/gt_check_roles.py", timeout=10)

    rc, stdout, stderr = run_cmd(
        f"kubectl exec -n glitchtip {gt_pod} -- bash -c 'cd /code && python manage.py shell < /tmp/gt_check_roles.py'",
        timeout=30,
    )

    if rc != 0:
        return 0.0, f"Failed to query GlitchTip user roles: {stderr[:200]}"

    try:
        json_line = [line for line in stdout.split("\n") if line.startswith("{")]
        if not json_line:
            return 0.0, f"No JSON output from role check: {stdout[:200]}"
        results = json.loads(json_line[-1])
    except (json.JSONDecodeError, IndexError):
        return 0.0, f"Failed to parse role check output: {stdout[:200]}"

    all_demoted = True
    feedback_parts = []

    for email in ["charlie@devops.local", "diana@devops.local", "eve@devops.local"]:
        user_info = results.get(email, {})
        if user_info.get("is_owner", True):
            all_demoted = False
            feedback_parts.append(f"{email} still has owner role")
        else:
            feedback_parts.append(f"{email} demoted")

    if all_demoted:
        return 1.0, "All non-admin users demoted: " + "; ".join(feedback_parts)
    else:
        return 0.0, "Some users still owner: " + "; ".join(feedback_parts)


def check_sso_role_mapping_functional(setup_info):
    """
    End-to-end functional check: get a token for charlie (non-admin) and verify
    the /platform-eng/glitchtip-owners group is NOT in the token's groups claim.
    This tests that the OIDC flow would assign the correct role.
    Score: 1.0 if charlie's token does NOT contain the owners group, 0.0 otherwise.
    """
    kc_url = "http://keycloak.keycloak.svc.cluster.local:8080"
    realm = setup_info.get("KC_REALM", "devops")
    client_secret = setup_info.get("GLITCHTIP_CLIENT_SECRET", "")

    # Get a token for charlie using the glitchtip OIDC client
    # Don't request specific scopes — let the client's default scopes + mapper handle it
    rc, stdout, _ = run_cmd(
        f'curl -s --connect-timeout 10 --max-time 15 -X POST '
        f'"{kc_url}/realms/{realm}/protocol/openid-connect/token" '
        f'-d "client_id=glitchtip" '
        f'-d "client_secret={client_secret}" '
        f'-d "grant_type=password" '
        f'-d "username=charlie" '
        f'-d "password=DevOps2024!"'
    )

    if not stdout:
        return 0.0, "Could not get token for charlie"

    try:
        token_response = json.loads(stdout)
        access_token = token_response.get("access_token")
    except json.JSONDecodeError:
        return 0.0, f"Token response not JSON: {stdout[:200]}"

    if not access_token:
        error = token_response.get("error_description", token_response.get("error", "unknown"))
        return 0.0, f"No access token for charlie: {error}"

    # Decode JWT payload (base64, no verification needed for grading)
    import base64
    try:
        payload_b64 = access_token.split(".")[1]
        # Add padding
        payload_b64 += "=" * (4 - len(payload_b64) % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_b64))
    except Exception as e:
        return 0.0, f"Failed to decode token: {e}"

    groups = payload.get("groups", [])

    if "/platform-eng/glitchtip-owners" in groups:
        return 0.0, f"Charlie's token still contains owners group: {groups}"
    else:
        return 1.0, f"Charlie's token correctly excludes owners group. Groups: {groups}"


def grade(*args, **kwargs) -> GradingResult:
    """Main grading function."""
    os.environ["KUBECONFIG"] = "/etc/rancher/k3s/k3s.yaml"
    setup_info = load_setup_info()

    # Pre-cleanup: kill any ubuntu background processes
    run_cmd("pkill -u ubuntu 2>/dev/null || true")

    # Wait durability window — if the enforcer is still active, it will re-corrupt
    # NOTE: We do NOT un-suspend CronJobs — suspension is a valid fix
    print("[grader] Waiting 90s durability window...")
    time.sleep(90)

    # Run all checks
    checks = {
        "enforcer_neutralized": check_enforcer_neutralized,
        "keycloak_groups_and_connectivity": check_keycloak_groups_and_connectivity,
        "oidc_config_correct": check_oidc_config_correct,
        "user_roles_demoted": check_user_roles_demoted,
        "sso_role_mapping_functional": check_sso_role_mapping_functional,
    }

    weight = 1.0 / len(checks)
    subscores = {}
    weights = {}
    feedback_parts = []

    for name, check_fn in checks.items():
        try:
            score, feedback = check_fn(setup_info)
        except Exception as e:
            score, feedback = 0.0, f"Check raised exception: {e}"

        subscores[name] = score
        weights[name] = weight
        feedback_parts.append(f"[{name}] {'PASS' if score > 0 else 'FAIL'}: {feedback}")
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
