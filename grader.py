#!/usr/bin/env python3
"""
Grader for glitchtip-keycloak-rbac-escalation task.

6 subscores, each weight 1/6, each testing ONE thing:
1. keycloak_groups_correct — Only alice, bob in owners group
2. enforcer_removed — CronJob deleted
3. oidc_scope_correct — Scope includes 'groups'
4. owner_group_path_correct — Full path /platform-eng/glitchtip-owners
5. network_connectivity — GlitchTip pod can reach Keycloak
6. user_roles_demoted — Non-admin users have member role
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


def get_kc_token(setup_info):
    """Get Keycloak admin token."""
    kc_url = setup_info.get("KEYCLOAK_URL", "http://keycloak.devops.local:8080")
    kc_user = setup_info.get("KC_ADMIN_USER", "admin")
    kc_pass = setup_info.get("KC_ADMIN_PASS", "changeme")

    rc, stdout, _ = run_cmd(
        f'curl -sf -X POST "{kc_url}/realms/master/protocol/openid-connect/token" '
        f'-d "client_id=admin-cli" '
        f'-d "grant_type=password" '
        f'-d "username={kc_user}" '
        f'-d "password={kc_pass}"'
    )
    if rc == 0 and stdout:
        try:
            return json.loads(stdout).get("access_token")
        except json.JSONDecodeError:
            pass
    return None


def check_keycloak_groups_correct(setup_info):
    """
    Check that ONLY alice and bob are members of /platform-eng/glitchtip-owners.
    Score: 1.0 if exactly {alice, bob}, 0.0 otherwise.
    """
    kc_url = setup_info.get("KEYCLOAK_URL", "http://keycloak.devops.local:8080")
    realm = setup_info.get("KC_REALM", "devops")
    owners_group_id = setup_info.get("OWNERS_GROUP_ID", "")

    token = get_kc_token(setup_info)
    if not token or not owners_group_id:
        return 0.0, "Could not get Keycloak token or owners group ID"

    rc, stdout, _ = run_cmd(
        f'curl -sf -H "Authorization: Bearer {token}" '
        f'"{kc_url}/admin/realms/{realm}/groups/{owners_group_id}/members"'
    )

    if rc != 0:
        return 0.0, "Failed to query Keycloak group members"

    try:
        members = json.loads(stdout)
        usernames = sorted([m["username"] for m in members])
    except (json.JSONDecodeError, KeyError):
        return 0.0, f"Failed to parse group members response"

    expected = ["alice", "bob"]
    if usernames == expected:
        return 1.0, f"Correct: owners group has exactly {expected}"
    else:
        return 0.0, f"Owners group has {usernames}, expected {expected}"


def check_enforcer_removed(setup_info):
    """
    Check that the enforcer CronJob has been deleted.
    Score: 1.0 if CronJob does not exist, 0.0 if it still exists.
    """
    rc, stdout, _ = run_cmd(
        "kubectl get cronjob keycloak-realm-config-reconciler -n keycloak "
        "-o jsonpath='{.metadata.name}' 2>/dev/null"
    )

    if rc != 0 or not stdout or stdout == "''":
        return 1.0, "Enforcer CronJob successfully removed"
    else:
        return 0.0, "Enforcer CronJob still exists in keycloak namespace"


def check_oidc_scope_correct(setup_info):
    """
    Check that GlitchTip OIDC scope includes 'groups'.
    Score: 1.0 if 'groups' is in the scope, 0.0 otherwise.
    """
    rc, stdout, _ = run_cmd(
        "kubectl get configmap glitchtip-oidc-config -n glitchtip "
        "-o jsonpath='{.data.OPENID_CONNECT_SCOPE}'"
    )

    if rc != 0:
        return 0.0, "Could not read GlitchTip OIDC ConfigMap"

    scope = stdout.strip("'")
    if "groups" in scope.split():
        return 1.0, f"OIDC scope correctly includes 'groups': {scope}"
    else:
        return 0.0, f"OIDC scope missing 'groups': {scope}"


def check_owner_group_path_correct(setup_info):
    """
    Check that the OIDC owner group is the full path /platform-eng/glitchtip-owners.
    Score: 1.0 if correct, 0.0 otherwise.
    """
    rc, stdout, _ = run_cmd(
        "kubectl get configmap glitchtip-oidc-config -n glitchtip "
        "-o jsonpath='{.data.GLITCHTIP_OIDC_OWNER_GROUP}'"
    )

    if rc != 0:
        return 0.0, "Could not read GlitchTip OIDC ConfigMap"

    owner_group = stdout.strip("'")
    if owner_group == "/platform-eng/glitchtip-owners":
        return 1.0, f"Owner group path correct: {owner_group}"
    else:
        return 0.0, f"Owner group path incorrect: '{owner_group}' (expected '/platform-eng/glitchtip-owners')"


def check_network_connectivity(setup_info):
    """
    Check that a GlitchTip pod can reach Keycloak OIDC endpoint.
    Score: 1.0 if connection succeeds, 0.0 otherwise.
    Uses polling with retries.
    """
    # Find a GlitchTip pod
    rc, gt_pod, _ = run_cmd(
        "kubectl get pods -n glitchtip -l app=glitchtip,component=web "
        "-o jsonpath='{.items[0].metadata.name}' 2>/dev/null"
    )

    if rc != 0 or not gt_pod or gt_pod == "''":
        rc, gt_pod, _ = run_cmd(
            "kubectl get pods -n glitchtip "
            "-o jsonpath='{.items[0].metadata.name}'"
        )

    gt_pod = gt_pod.strip("'")
    if not gt_pod:
        return 0.0, "No GlitchTip pod found"

    # Poll with retries
    kc_url = setup_info.get("KEYCLOAK_URL", "http://keycloak.devops.local:8080")
    realm = setup_info.get("KC_REALM", "devops")

    for attempt in range(10):
        rc, stdout, stderr = run_cmd(
            f"kubectl exec -n glitchtip {gt_pod} -- "
            f'curl -sf -o /dev/null -w "%{{http_code}}" '
            f'"{kc_url}/realms/{realm}/.well-known/openid-configuration"',
            timeout=15,
        )

        if rc == 0 and stdout.strip("'") in ("200", "301", "302"):
            return 1.0, "GlitchTip can reach Keycloak OIDC endpoint"

        time.sleep(3)

    return 0.0, f"GlitchTip cannot reach Keycloak (last status: {stdout}, err: {stderr})"


def check_user_roles_demoted(setup_info):
    """
    Check that charlie, diana, eve have member role (not owner) in GlitchTip.
    Score: 1.0 if all three are demoted, 0.0 otherwise.
    """
    # Find GlitchTip pod
    rc, gt_pod, _ = run_cmd(
        "kubectl get pods -n glitchtip -l app=glitchtip,component=web "
        "-o jsonpath='{.items[0].metadata.name}' 2>/dev/null"
    )

    if rc != 0 or not gt_pod or gt_pod == "''":
        rc, gt_pod, _ = run_cmd(
            "kubectl get pods -n glitchtip "
            "-o jsonpath='{.items[0].metadata.name}'"
        )

    gt_pod = gt_pod.strip("'")
    if not gt_pod:
        return 0.0, "No GlitchTip pod found"

    # Query Django ORM for user roles
    check_script = """
import json
from django.contrib.auth import get_user_model
from organizations_ext.models import OrganizationUser

User = get_user_model()
results = {}

for email in ['charlie@devops.local', 'diana@devops.local', 'eve@devops.local']:
    try:
        user = User.objects.get(email=email)
        org_users = OrganizationUser.objects.filter(user=user)
        roles = [ou.role for ou in org_users]
        # role 0 = owner, role 1 = member/admin, role 2 = member
        results[email] = {'roles': roles, 'is_owner': 0 in roles}
    except User.DoesNotExist:
        results[email] = {'roles': [], 'is_owner': False, 'error': 'not found'}

print(json.dumps(results))
"""

    rc, stdout, stderr = run_cmd(
        f"kubectl exec -n glitchtip {gt_pod} -- python manage.py shell -c "
        f"'{check_script}'",
        timeout=30,
    )

    if rc != 0:
        return 0.0, f"Failed to query GlitchTip user roles: {stderr}"

    try:
        # Extract JSON from output (may have Django startup noise)
        json_line = [line for line in stdout.split("\n") if line.startswith("{")]
        if not json_line:
            return 0.0, f"No JSON output from role check: {stdout}"
        results = json.loads(json_line[-1])
    except (json.JSONDecodeError, IndexError):
        return 0.0, f"Failed to parse role check output: {stdout}"

    all_demoted = True
    feedback_parts = []

    for email in ["charlie@devops.local", "diana@devops.local", "eve@devops.local"]:
        user_info = results.get(email, {})
        if user_info.get("is_owner", True):
            all_demoted = False
            feedback_parts.append(f"{email} still has owner role")
        else:
            feedback_parts.append(f"{email} correctly demoted")

    if all_demoted:
        return 1.0, "All non-admin users correctly demoted: " + "; ".join(feedback_parts)
    else:
        return 0.0, "Some users still have owner role: " + "; ".join(feedback_parts)


def grade() -> GradingResult:
    """Main grading function."""
    setup_info = load_setup_info()

    # Pre-cleanup: kill any ubuntu background processes
    run_cmd("pkill -u ubuntu 2>/dev/null || true")

    # Un-suspend any suspended CronJobs (if agent suspended instead of deleting)
    run_cmd(
        "kubectl get cronjobs -n keycloak -o json 2>/dev/null | "
        "jq -r '.items[] | select(.spec.suspend==true) | .metadata.name' | "
        "xargs -I{} kubectl patch cronjob {} -n keycloak -p '{\"spec\":{\"suspend\":false}}' 2>/dev/null || true"
    )

    # Wait durability window — if the enforcer is still running, it will re-corrupt
    print("[grader] Waiting 90s durability window...")
    time.sleep(90)

    # Run all checks
    checks = {
        "keycloak_groups_correct": check_keycloak_groups_correct,
        "enforcer_removed": check_enforcer_removed,
        "oidc_scope_correct": check_oidc_scope_correct,
        "owner_group_path_correct": check_owner_group_path_correct,
        "network_connectivity": check_network_connectivity,
        "user_roles_demoted": check_user_roles_demoted,
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
