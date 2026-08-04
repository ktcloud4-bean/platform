#!/usr/bin/env python3
"""IAM-01 Shuffle OIDC RBAC를 기존 검증 ID로 판정하고 원복한다.

대상 6명의 초기 비밀번호와 MFA에는 접근하지 않는다. 기존 Keycloak 검증 ID 하나를
`/soar-readers`에 잠시 넣어 role 없는 로그인 거부와 reader 권한을 순서대로 판정하고,
legacy privileged ID로 admin 권한을 판정한다. 자동 프로비저닝과 검증용 membership은
모든 종료 경로에서 닫고, 만들어진 OpenID 사용자는 Shuffle 조직에서 제거한다.
"""

from __future__ import annotations

import argparse
import fcntl
import json
import os
from pathlib import Path
import sys
import tempfile
import time
import urllib.parse


SHUFFLE_URL = "https://shuffle.imcherry5778.xyz"
ROLELESS_REASON = "Role detail is missing. Please contact the administrator of org."
ZERO_WORKFLOW_ID = "00000000-0000-0000-0000-000000000000"


class SafeError(RuntimeError):
    """credential, token, cookie, 원문 응답을 포함하지 않는 판정 오류."""


def request_json(routes, opener, path: str, *, method="GET", payload=None, expected=200):
    status, final_url, body = routes.request(
        opener, f"{SHUFFLE_URL}{path}", method=method, payload=payload
    )
    if status != expected:
        raise SafeError(f"Shuffle {method} {path} expected HTTP {expected}, got {status}")
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        raise SafeError(f"Shuffle {method} {path} returned invalid JSON") from None
    return parsed, final_url


def expect_json_denial(
    routes, opener, path: str, *, method="GET", payload=None, status_expected: int, reason: str
):
    status, _final_url, body = routes.request(
        opener, f"{SHUFFLE_URL}{path}", method=method, payload=payload
    )
    if status != status_expected:
        raise SafeError(
            f"Shuffle {method} {path} expected HTTP {status_expected}, got {status}"
        )
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        raise SafeError(f"Shuffle denial for {method} {path} returned invalid JSON") from None
    if parsed.get("success") is not False or parsed.get("reason") != reason:
        raise SafeError(f"Shuffle denial reason drifted for {method} {path}")


def find_user(kc, username: str) -> dict:
    query = urllib.parse.urlencode({"username": username, "exact": "true"})
    users, _ = kc.request("GET", f"users?{query}")
    exact = [
        user
        for user in users
        if isinstance(user, dict) and user.get("username", "").casefold() == username.casefold()
    ]
    if len(exact) != 1:
        raise SafeError(f"Keycloak verifier identity count drifted: {username}")
    return exact[0]


def group_by_path(provision, kc, path: str) -> dict:
    groups, _ = kc.request("GET", "groups?max=100")
    group = provision.flatten_groups(groups).get(path)
    if not group:
        raise SafeError(f"Keycloak group is missing: {path}")
    return group


def user_group_paths(kc, user_id: str) -> set[str]:
    groups, _ = kc.request("GET", f"users/{user_id}/groups?max=100")
    return {group.get("path") for group in groups if isinstance(group, dict) and group.get("path")}


def set_reader_membership(kc, user_id: str, group_id: str, enabled: bool) -> None:
    method = "PUT" if enabled else "DELETE"
    kc.request(method, f"users/{user_id}/groups/{group_id}", expected=(204,))


def local_admin_login(provision, routes, opener, secret_root: Path) -> int:
    provision.shuffle_login(
        routes,
        opener,
        secret_root / "shuffle/default-admin-password",
        secret_root / "iam-01/shuffle-admin-totp",
    )
    info, _ = request_json(routes, opener, "/api/v1/getinfo")
    if (
        info.get("username") != "soar-dash-01-admin"
        or info.get("admin") != "true"
        or (info.get("active_org") or {}).get("role") != "admin"
    ):
        raise SafeError("Shuffle local recovery control session drifted")
    return int(time.time()) // 30


def wait_for_new_totp_slot(previous_slot: int) -> None:
    if int(time.time()) // 30 != previous_slot:
        return
    time.sleep(30 - int(time.time()) % 30 + 1)


def org_context(routes, opener) -> tuple[str, dict]:
    info, _ = request_json(routes, opener, "/api/v1/getinfo")
    org_id = (info.get("active_org") or {}).get("id")
    if not org_id:
        raise SafeError("Shuffle active organization is missing")
    org, _ = request_json(routes, opener, f"/api/v1/orgs/{org_id}")
    if org.get("name") != "Platform Security":
        raise SafeError("Shuffle organization name drifted")
    return org_id, org


def set_auto_provision(provision, routes, opener, org_id: str, disabled: bool) -> None:
    payload = {
        "org_id": org_id,
        "name": "Platform Security",
        "editing": "sso_config",
        "sso_config": provision.shuffle_sso_expected(disabled),
    }
    response, _ = request_json(
        routes, opener, f"/api/v1/orgs/{org_id}", method="POST", payload=payload
    )
    if response.get("success") is not True:
        raise SafeError("Shuffle auto-provision transition was rejected")
    _org_id, org = org_context(routes, opener)
    sso = org.get("sso_config") or {}
    if sso.get("auto_provision") is not disabled or sso.get("role_required") is not True:
        raise SafeError("Shuffle auto-provision or role-required state did not converge")


def oidc_url(routes, opener) -> str:
    check, _ = request_json(routes, opener, "/api/v1/checkusers")
    sso_url = check.get("sso_url")
    parsed = urllib.parse.urlsplit(sso_url or "")
    if (
        check.get("success") is not True
        or check.get("reason") != "redirect"
        or parsed.scheme != "https"
        or parsed.hostname != "sso.imcherry5778.xyz"
    ):
        raise SafeError("Shuffle OIDC authorization URL drifted")
    if "scope=openid email" not in sso_url:
        raise SafeError("Shuffle OIDC scope encoding drifted")
    # Shuffle 2.2.1은 scope 구분 공백을 percent-encode하지 않아 urllib이 InvalidURL로 거부한다.
    return sso_url.replace("scope=openid email", "scope=openid%20email", 1)


def oidc_roleless_rejected(routes, opener) -> None:
    status, _final_url, body = routes.request(opener, oidc_url(routes, opener))
    if status != 401:
        raise SafeError(f"role-less OIDC login expected HTTP 401, got {status}")
    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        raise SafeError("role-less OIDC denial returned invalid JSON") from None
    if parsed.get("success") is not False or parsed.get("reason") != ROLELESS_REASON:
        raise SafeError("role-less OIDC login denial reason drifted")


def oidc_login(routes, opener, expected_username: str, expected_role: str) -> None:
    status, final_url, _body = routes.request(opener, oidc_url(routes, opener))
    parsed_final = urllib.parse.urlsplit(final_url)
    if (
        status != 200
        or parsed_final.hostname != "shuffle.imcherry5778.xyz"
        or parsed_final.path != "/workflows"
    ):
        raise SafeError(
            f"Shuffle OIDC login expected HTTP 200 at /workflows, got HTTP {status}"
        )
    info, _ = request_json(routes, opener, "/api/v1/getinfo")
    if info.get("username", "").casefold() != expected_username.casefold():
        raise SafeError("Shuffle OIDC username comparison failed")
    if (info.get("active_org") or {}).get("role") != expected_role:
        raise SafeError("Shuffle OIDC session role comparison failed")


def org_oidc_users(routes, opener, org_id: str) -> dict[str, dict]:
    # HandleGetUsers는 이미 active org로 범위를 제한하고 응답에서 orgs를 비울 수 있다.
    if not org_id:
        raise SafeError("Shuffle organization scope is missing")
    users, _ = request_json(routes, opener, "/api/v1/users")
    return {
        user.get("generated_username", "").casefold(): user
        for user in users
        if isinstance(user, dict)
        and user.get("generated_username")
    }


def remove_oidc_user(routes, opener, user: dict) -> None:
    user_id = user.get("id")
    username = user.get("username", "").casefold()
    generated = user.get("generated_username", "").casefold()
    if not user_id or not generated or username != generated:
        raise SafeError("refusing to remove an unexpected Shuffle verifier record")
    response, _ = request_json(routes, opener, f"/api/v1/users/{user_id}", method="DELETE")
    if response.get("success") is not True:
        raise SafeError("Shuffle verifier membership cleanup was rejected")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument(
        "--secret-root",
        type=Path,
        default=Path(os.environ.get("KTC_SECRET_ROOT", "/home/imcherry/secrets/ktcloud4-bean")),
    )
    parser.add_argument("--connect-ip", default="10.10.20.10")
    parser.add_argument("--reader-verifier", default="headlamp-no-group")
    parser.add_argument("--admin-verifier", default="imcherry-admin")
    args = parser.parse_args()

    repo_root = args.repo_root.resolve()
    provision = __import__("provision")
    routes = provision.load_module(
        "iam01_rbac_routes", repo_root / "gitops/tools/soar-dash-01/verify-routes.py"
    )
    browser = routes.load_pomerium_browser(repo_root)

    secret_root = args.secret_root
    reader_password = secret_root / "keycloak/headlamp-no-group-password"
    reader_totp = secret_root / "keycloak/headlamp-no-group-totp"
    admin_password = secret_root / "keycloak/privileged-password"
    admin_totp = secret_root / "keycloak/privileged-totp"
    for path in (reader_password, reader_totp, admin_password, admin_totp):
        provision.require_secret(path)

    lock_path = Path("/tmp/iam-01-provision.lock")
    lock_descriptor = os.open(lock_path, os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SafeError("IDENTITY-LIVE provisioning lock is held") from None

    control_opener = None
    kc = None
    reader_user = None
    reader_group = None
    org_id = None
    local_totp_slot = None
    control_is_oidc = False
    created_names = {args.reader_verifier.casefold(), args.admin_verifier.casefold()}
    primary_error = None
    primary_stage = "initialization"
    stage = "initialization"
    cleanup_errors: list[str] = []

    try:
        with tempfile.TemporaryDirectory(prefix="iam-01-rbac-") as temp_name:
            stage = "keycloak-control"
            kc = provision.KeycloakAdmin(
                repo_root, secret_root, args.connect_ip, Path(temp_name)
            )
            reader_user = find_user(kc, args.reader_verifier)
            reader_group = group_by_path(provision, kc, "/soar-readers")
            relevant = user_group_paths(kc, reader_user["id"]) & provision.RELEVANT_GROUPS
            if relevant:
                raise SafeError("reader verifier has pre-existing IAM-01 group membership")

            stage = "reader-route"
            set_reader_membership(kc, reader_user["id"], reader_group["id"], True)
            reader_opener = routes.login(
                browser,
                args.connect_ip,
                f"{SHUFFLE_URL}/",
                args.reader_verifier,
                str(reader_password),
                str(reader_totp),
            )
            set_reader_membership(kc, reader_user["id"], reader_group["id"], False)

            stage = "shuffle-control"
            control_opener = routes.login(
                browser,
                args.connect_ip,
                f"{SHUFFLE_URL}/",
                args.admin_verifier,
                str(admin_password),
                str(admin_totp),
            )
            local_totp_slot = local_admin_login(provision, routes, control_opener, secret_root)
            org_id, _org = org_context(routes, control_opener)
            initial_oidc = org_oidc_users(routes, control_opener, org_id)
            if created_names & set(initial_oidc):
                raise SafeError("Shuffle verifier identities already belong to the organization")

            set_auto_provision(provision, routes, control_opener, org_id, False)

            # Route session은 reader claim으로 이미 성립했지만, 새 OIDC token에는 role이 없다.
            stage = "roleless-oidc"
            oidc_roleless_rejected(routes, reader_opener)
            if args.reader_verifier.casefold() in org_oidc_users(routes, control_opener, org_id):
                raise SafeError("role-less OIDC rejection created a Shuffle user")

            set_reader_membership(kc, reader_user["id"], reader_group["id"], True)
            stage = "reader-oidc"
            oidc_login(routes, reader_opener, args.reader_verifier, "org-reader")
            control_is_oidc = True
            stage = "admin-oidc"
            oidc_login(routes, control_opener, args.admin_verifier, "admin")

            stage = "username-role-compare"
            provisioned = org_oidc_users(routes, control_opener, org_id)
            actual = {
                name: provisioned.get(name, {}).get("role")
                for name in created_names
            }
            expected = {
                args.reader_verifier.casefold(): "org-reader",
                args.admin_verifier.casefold(): "admin",
            }
            if actual != expected:
                reader_value = actual.get(args.reader_verifier.casefold()) or "missing"
                admin_value = actual.get(args.admin_verifier.casefold()) or "missing"
                raise SafeError(
                    "Shuffle verifier username or one-role mapping drifted: "
                    f"reader={reader_value} admin={admin_value}"
                )

            # username과 role을 대조한 직후 등록 창을 닫는다.
            set_auto_provision(provision, routes, control_opener, org_id, True)

            stage = "reader-admin-authorization"
            workflows, _ = request_json(routes, reader_opener, "/api/v1/workflows")
            if not isinstance(workflows, list):
                raise SafeError("reader workflow query returned an unexpected shape")
            expect_json_denial(
                routes,
                reader_opener,
                f"/api/v1/orgs/{org_id}",
                method="POST",
                payload={"org_id": org_id, "name": "Platform Security"},
                status_expected=403,
                reason="Not admin",
            )
            expect_json_denial(
                routes,
                reader_opener,
                f"/api/v1/workflows/{ZERO_WORKFLOW_ID}/execute",
                method="POST",
                status_expected=401,
                reason="Read only user",
            )
            admin_users, _ = request_json(routes, control_opener, "/api/v1/users")
            if not isinstance(admin_users, list):
                raise SafeError("privileged admin operation returned an unexpected shape")
    except Exception as error:  # finally에서 live 임시 상태를 먼저 닫는다.
        primary_error = error
        primary_stage = stage
    finally:
        if kc and reader_user and reader_group:
            try:
                if "/soar-readers" in user_group_paths(kc, reader_user["id"]):
                    set_reader_membership(kc, reader_user["id"], reader_group["id"], False)
            except Exception:
                cleanup_errors.append("Keycloak verifier group cleanup failed")

        if control_opener and org_id:
            try:
                set_auto_provision(provision, routes, control_opener, org_id, True)
            except Exception:
                cleanup_errors.append("Shuffle auto-provision cleanup failed")

            try:
                if control_is_oidc:
                    if local_totp_slot is not None:
                        wait_for_new_totp_slot(local_totp_slot)
                    local_admin_login(provision, routes, control_opener, secret_root)
                users = org_oidc_users(routes, control_opener, org_id)
                for name in sorted(created_names):
                    if name in users:
                        remove_oidc_user(routes, control_opener, users[name])
                remaining = org_oidc_users(routes, control_opener, org_id)
                if created_names & set(remaining):
                    raise SafeError("Shuffle verifier membership remains after cleanup")
                _final_org_id, final_org = org_context(routes, control_opener)
                final_sso = final_org.get("sso_config") or {}
                if final_sso.get("auto_provision") is not True:
                    raise SafeError("Shuffle auto-provision is not off after cleanup")
                if final_sso.get("role_required") is not True:
                    raise SafeError("Shuffle role-required is not true after cleanup")
            except Exception:
                cleanup_errors.append("Shuffle verifier membership cleanup failed")

        if kc and reader_user:
            try:
                if user_group_paths(kc, reader_user["id"]) & provision.RELEVANT_GROUPS:
                    raise SafeError("Keycloak verifier relevant group remains after cleanup")
            except Exception:
                cleanup_errors.append("Keycloak verifier final-state check failed")

    if cleanup_errors:
        raise SafeError("; ".join(cleanup_errors))
    if primary_error:
        if isinstance(primary_error, SafeError):
            raise primary_error
        raise SafeError(
            f"RBAC verification failed at stage={primary_stage} "
            f"type={type(primary_error).__name__}"
        ) from None

    print(
        "IAM01RBAC=PASS roleless_oidc=deny reader_route=allow reader_read=allow "
        "reader_write=deny reader_execute=deny privileged_admin=allow "
        "auto_provision=off verifier_memberships=clean"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SafeError as error:
        print(f"IAM-01 RBAC verification failed: {error}", file=sys.stderr)
        raise SystemExit(1)
