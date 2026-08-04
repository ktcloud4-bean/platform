#!/usr/bin/env python3
"""IAM-01 Keycloak 사람 ID와 Shuffle OIDC/복구 MFA를 안전하게 구성한다.

비밀번호, TOTP seed, token, email 원문은 출력하지 않는다. Keycloak의 실제 email은
보호 입력에서만 읽고, Shuffle 2.2.1이 username으로 소비하는 client별 email claim은
canonical Keycloak username으로 별도 매핑한다.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import hmac
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import string
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


ISSUER = "https://sso.imcherry5778.xyz"
REALM = "platform"
SHUFFLE_URL = "https://shuffle.imcherry5778.xyz"
SHUFFLE_CLIENT = "shuffle"
SHUFFLE_ROLES = {
    "/soar-readers": "shuffle-org-reader",
    "/soar-operators": "shuffle-user",
    "/platform-privileged": "shuffle-admin",
}
DAILY_USERS = {
    "imcherry5778": "IAM01_EMAIL_IMCHERRY5778",
    "foxgeun": "IAM01_EMAIL_FOXGEUN",
    "cerberos2022": "IAM01_EMAIL_CERBEROS2022",
    "Jaeeyun": "IAM01_EMAIL_JAEEYUN",
    "snsd-hybirdinfra": "IAM01_EMAIL_SNSD_HYBIRDINFRA",
}
PRIVILEGED_USER = "imcherry5778-admin"
RELEVANT_GROUPS = set(SHUFFLE_ROLES) | {"/platform-users"}
PASSWORD_POLICY_REQUIRED = {
    "length": 20,
    "digits": 1,
    "upperCase": 1,
    "lowerCase": 1,
    "specialChars": 1,
}


class SafeError(RuntimeError):
    """원문 응답이나 보호 입력을 포함하지 않는 판정 오류."""


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise SafeError(f"module load failed: {name}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require_secret(path: Path) -> None:
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_mode & 0o077:
        raise SafeError(f"secret input must be a mode 0600 regular file: {path.name}")


def read_env(path: Path) -> dict[str, str]:
    require_secret(path)
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or line.lstrip().startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not key or key in values:
            raise SafeError("IAM email input format is invalid")
        values[key] = value
    if set(values) != set(DAILY_USERS.values()):
        raise SafeError("IAM email input keys do not match the declared users")
    email_pattern = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    if any(not email_pattern.fullmatch(value) for value in values.values()):
        raise SafeError("IAM email input contains an invalid value")
    if len(set(value.casefold() for value in values.values())) != len(values):
        raise SafeError("IAM email input contains duplicates")
    return values


def password_file(secret_dir: Path, username: str) -> Path:
    normalized = re.sub(r"[^A-Za-z0-9_.-]", "_", username)
    return secret_dir / f"initial-password-{normalized}"


def ensure_password(path: Path) -> str:
    if not path.exists():
        alphabet = string.ascii_letters + string.digits + "!@#$%^&*()-_=+"
        while True:
            value = "".join(secrets.choice(alphabet) for _ in range(28))
            if all(
                (
                    re.search(r"[A-Z]", value),
                    re.search(r"[a-z]", value),
                    re.search(r"[0-9]", value),
                    re.search(r"[^A-Za-z0-9]", value),
                )
            ):
                break
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(value + "\n")
    require_secret(path)
    value = path.read_text(encoding="utf-8").strip()
    if len(value) < PASSWORD_POLICY_REQUIRED["length"]:
        raise SafeError(f"initial password does not meet policy: {path.name}")
    if not all(
        (
            re.search(r"[A-Z]", value),
            re.search(r"[a-z]", value),
            re.search(r"[0-9]", value),
            re.search(r"[^A-Za-z0-9]", value),
        )
    ):
        raise SafeError(f"initial password does not meet policy: {path.name}")
    return value


class KeycloakAdmin:
    def __init__(self, repo_root: Path, secret_root: Path, connect_ip: str, temp_dir: Path):
        keycloak_secrets = secret_root / "keycloak"
        password = keycloak_secrets / "local-admin-password"
        totp_seed = keycloak_secrets / "local-admin-totp"
        require_secret(password)
        require_secret(totp_seed)
        header_file = temp_dir / "keycloak-admin.header"
        browser_script = repo_root / "gitops/tools/kc-01/browser-login.py"
        subprocess.run(
            [
                sys.executable,
                str(browser_script),
                "--issuer",
                ISSUER,
                "--realm",
                "master",
                "--client-id",
                "kc-recovery",
                "--redirect-uri",
                f"{ISSUER}/realms/master/account/",
                "--username",
                "imcherry-kc-recovery",
                "--password-file",
                str(password),
                "--totp-file",
                str(totp_seed),
                "--header-file",
                str(header_file),
                "--connect-ip",
                connect_ip,
                "--capture-callback",
                "--expect-realm-role",
                "admin",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        require_secret(header_file)
        header = header_file.read_text(encoding="utf-8").strip()
        prefix = "Authorization: "
        if not header.startswith(prefix):
            raise SafeError("Keycloak admin header format is invalid")
        self.authorization = header[len(prefix) :]
        browser = load_module("iam01_kc_browser", browser_script)
        handlers = [urllib.request.ProxyHandler({})]
        handlers.append(browser.FixedAddressHTTPSHandler(connect_ip, "sso.imcherry5778.xyz"))
        self.opener = urllib.request.build_opener(*handlers)
        self.base = f"{ISSUER}/admin/realms/{REALM}"

    def request(self, method: str, path: str, payload=None, expected=(200,)):
        body = None
        headers = {"Authorization": self.authorization, "Accept": "application/json"}
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            f"{self.base}/{path.lstrip('/')}", data=body, headers=headers, method=method
        )
        try:
            with self.opener.open(request, timeout=30) as response:
                status = response.status
                response_body = response.read()
                response_headers = response.headers
        except urllib.error.HTTPError as error:
            error.read()
            raise SafeError(f"Keycloak Admin API failed: {method} {path} HTTP {error.code}") from None
        if status not in expected:
            raise SafeError(f"Keycloak Admin API unexpected status: {method} {path} HTTP {status}")
        if not response_body:
            return None, response_headers
        try:
            return json.loads(response_body), response_headers
        except json.JSONDecodeError:
            raise SafeError(f"Keycloak Admin API returned invalid JSON: {method} {path}") from None


def policy_values(policy: str) -> dict[str, int]:
    values: dict[str, int] = {}
    for name, value in re.findall(r"([A-Za-z]+)\((\d+)\)", policy):
        values[name] = int(value)
    return values


def ensure_password_policy(kc: KeycloakAdmin, apply: bool) -> bool:
    realm, _ = kc.request("GET", "")
    current = realm.get("passwordPolicy") or ""
    values = policy_values(current)
    for key in ("length", "digits", "upperCase", "lowerCase"):
        if values.get(key, 0) < PASSWORD_POLICY_REQUIRED[key]:
            raise SafeError(f"existing realm password policy is weaker than IAM-01 baseline: {key}")
    target = current
    if realm.get("loginWithEmailAllowed") or realm.get("registrationEmailAsUsername"):
        raise SafeError("realm must authenticate people by canonical username, not email")
    policy_changed = values.get("specialChars", 0) < 1
    duplicate_changed = not bool(realm.get("duplicateEmailsAllowed"))
    if policy_changed:
        target = f"{current} and specialChars(1)" if current else "specialChars(1)"
        realm["passwordPolicy"] = target
    if duplicate_changed:
        # IAM-MIG-01 전까지 legacy와 새 canonical ID가 같은 검증 email을 공유한다.
        # email login은 이미 꺼져 있으므로 인증 식별자는 계속 username 하나다.
        realm["duplicateEmailsAllowed"] = True
    if apply and (policy_changed or duplicate_changed):
        kc.request("PUT", "", realm, expected=(204,))
    return not (policy_changed or duplicate_changed) or apply


def flatten_groups(groups: list[dict]) -> dict[str, dict]:
    result: dict[str, dict] = {}
    for group in groups:
        path = group.get("path")
        if path:
            result[path] = group
        result.update(flatten_groups(group.get("subGroups") or []))
    return result


def ensure_groups(kc: KeycloakAdmin, apply: bool) -> dict[str, dict]:
    groups, _ = kc.request("GET", "groups?max=200")
    by_path = flatten_groups(groups)
    for path in sorted(RELEVANT_GROUPS):
        if path in by_path:
            continue
        if not apply:
            continue
        kc.request("POST", "groups", {"name": path.removeprefix("/")}, expected=(201,))
    groups, _ = kc.request("GET", "groups?max=200")
    return flatten_groups(groups)


def client_expected() -> dict:
    return {
        "clientId": SHUFFLE_CLIENT,
        "name": "IAM-01 Shuffle public PKCE",
        "enabled": True,
        "protocol": "openid-connect",
        "publicClient": True,
        "standardFlowEnabled": True,
        "implicitFlowEnabled": False,
        "directAccessGrantsEnabled": False,
        "serviceAccountsEnabled": False,
        "authorizationServicesEnabled": False,
        "fullScopeAllowed": False,
        "redirectUris": [f"{SHUFFLE_URL}/api/v1/login_openid"],
        "webOrigins": [SHUFFLE_URL],
        "attributes": {"pkce.code.challenge.method": "S256"},
    }


def ensure_client(kc: KeycloakAdmin, apply: bool) -> dict | None:
    clients, _ = kc.request("GET", "clients?clientId=shuffle")
    matches = [client for client in clients if client.get("clientId") == SHUFFLE_CLIENT]
    if len(matches) > 1:
        raise SafeError("multiple Shuffle clients exist")
    if not matches:
        if not apply:
            return None
        kc.request("POST", "clients", client_expected(), expected=(201,))
        clients, _ = kc.request("GET", "clients?clientId=shuffle")
        matches = [client for client in clients if client.get("clientId") == SHUFFLE_CLIENT]
    if len(matches) != 1:
        raise SafeError("Shuffle client creation did not converge")
    client = matches[0]
    expected = client_expected()
    for key in (
        "publicClient",
        "standardFlowEnabled",
        "implicitFlowEnabled",
        "directAccessGrantsEnabled",
        "serviceAccountsEnabled",
        "fullScopeAllowed",
    ):
        if client.get(key, False) != expected[key]:
            raise SafeError(f"existing Shuffle client drift: {key}")
    if sorted(client.get("redirectUris") or []) != expected["redirectUris"]:
        raise SafeError("existing Shuffle client drift: redirectUris")
    if sorted(client.get("webOrigins") or []) != expected["webOrigins"]:
        raise SafeError("existing Shuffle client drift: webOrigins")
    if (client.get("attributes") or {}).get("pkce.code.challenge.method") != "S256":
        raise SafeError("existing Shuffle client drift: PKCE")
    return client


def mapper_definitions() -> dict[str, dict]:
    common = {
        "id.token.claim": "true",
        "access.token.claim": "true",
        "userinfo.token.claim": "true",
        "introspection.token.claim": "true",
    }
    return {
        "shuffle-canonical-username": {
            "name": "shuffle-canonical-username",
            "protocol": "openid-connect",
            "protocolMapper": "oidc-usermodel-property-mapper",
            "consentRequired": False,
            "config": {
                **common,
                "user.attribute": "username",
                "claim.name": "email",
                "jsonType.label": "String",
            },
        },
        "shuffle-client-roles": {
            "name": "shuffle-client-roles",
            "protocol": "openid-connect",
            "protocolMapper": "oidc-usermodel-client-role-mapper",
            "consentRequired": False,
            "config": {
                **common,
                "usermodel.clientRoleMapping.clientId": SHUFFLE_CLIENT,
                "usermodel.clientRoleMapping.rolePrefix": "",
                "claim.name": "roles",
                "jsonType.label": "String",
                "multivalued": "true",
            },
        },
    }


def ensure_mappers(kc: KeycloakAdmin, client: dict | None, apply: bool) -> bool:
    if client is None:
        return False
    client_id = client["id"]
    existing, _ = kc.request("GET", f"clients/{client_id}/protocol-mappers/models")
    by_name = {mapper.get("name"): mapper for mapper in existing}
    ready = True
    for name, expected in mapper_definitions().items():
        current = by_name.get(name)
        if current is None:
            ready = False
            if apply:
                kc.request(
                    "POST",
                    f"clients/{client_id}/protocol-mappers/models",
                    expected,
                    expected=(201,),
                )
            continue
        if current.get("protocolMapper") != expected["protocolMapper"]:
            raise SafeError(f"existing Shuffle mapper drift: {name}")
        current_config = current.get("config") or {}
        for key, value in expected["config"].items():
            # Keycloak은 빈 role prefix를 저장할 때 config key 자체를 생략한다.
            current_value = current_config.get(key, "" if value == "" else None)
            if current_value != value:
                raise SafeError(f"existing Shuffle mapper drift: {name}/{key}")
    return ready or apply


def ensure_client_roles(kc: KeycloakAdmin, client: dict | None, apply: bool) -> dict[str, dict]:
    if client is None:
        return {}
    client_id = client["id"]
    result: dict[str, dict] = {}
    for role_name in SHUFFLE_ROLES.values():
        try:
            role, _ = kc.request("GET", f"clients/{client_id}/roles/{role_name}")
        except SafeError as error:
            if "HTTP 404" not in str(error):
                raise
            if not apply:
                continue
            kc.request(
                "POST",
                f"clients/{client_id}/roles",
                {"name": role_name, "description": f"IAM-01 {role_name}"},
                expected=(201,),
            )
            role, _ = kc.request("GET", f"clients/{client_id}/roles/{role_name}")
        result[role_name] = role
    return result


def ensure_scope_and_group_roles(
    kc: KeycloakAdmin,
    client: dict | None,
    roles: dict[str, dict],
    groups: dict[str, dict],
    apply: bool,
) -> bool:
    if client is None or set(roles) != set(SHUFFLE_ROLES.values()):
        return False
    client_id = client["id"]
    scoped, _ = kc.request("GET", f"clients/{client_id}/scope-mappings/clients/{client_id}")
    scoped_names = {role.get("name") for role in scoped}
    missing_scope = set(roles) - scoped_names
    if missing_scope and apply:
        kc.request(
            "POST",
            f"clients/{client_id}/scope-mappings/clients/{client_id}",
            [roles[name] for name in sorted(missing_scope)],
            expected=(204,),
        )
    ready = not missing_scope or apply
    for path, expected_name in SHUFFLE_ROLES.items():
        group = groups.get(path)
        if group is None:
            ready = False
            continue
        mapped, _ = kc.request(
            "GET", f"groups/{group['id']}/role-mappings/clients/{client_id}"
        )
        mapped_names = {role.get("name") for role in mapped} & set(roles)
        if mapped_names - {expected_name}:
            raise SafeError(f"existing group has conflicting Shuffle role: {path}")
        if expected_name not in mapped_names:
            ready = False
            if apply:
                kc.request(
                    "POST",
                    f"groups/{group['id']}/role-mappings/clients/{client_id}",
                    [roles[expected_name]],
                    expected=(204,),
                )
    return ready or apply


def find_user(kc: KeycloakAdmin, username: str) -> dict | None:
    query = urllib.parse.urlencode({"username": username, "exact": "true"})
    users, _ = kc.request("GET", f"users?{query}")
    exact = [user for user in users if user.get("username", "").casefold() == username.casefold()]
    if len(exact) > 1:
        raise SafeError(f"multiple Keycloak users match: {username}")
    return exact[0] if exact else None


def create_user(
    kc: KeycloakAdmin,
    username: str,
    email: str | None,
    desired_groups: list[str],
    secret_dir: Path,
) -> dict:
    password = ensure_password(password_file(secret_dir, username))
    payload = {
        "username": username,
        "enabled": True,
        "requiredActions": ["UPDATE_PASSWORD", "CONFIGURE_TOTP"],
        "credentials": [{"type": "password", "value": password, "temporary": True}],
        "groups": desired_groups,
    }
    if email is not None:
        payload["email"] = email
        payload["emailVerified"] = True
    kc.request("POST", "users", payload, expected=(201,))
    user = find_user(kc, username)
    if user is None:
        raise SafeError(f"Keycloak user creation did not converge: {username}")
    return user


def ensure_users(
    kc: KeycloakAdmin,
    emails: dict[str, str],
    groups: dict[str, dict],
    client: dict | None,
    secret_dir: Path,
    apply: bool,
) -> tuple[int, int, bool]:
    definitions = {
        username: (emails[key], ["/platform-users", "/soar-readers"])
        for username, key in DAILY_USERS.items()
    }
    # IAM-01-FIX-01: 애초 가정("특권 ID는 email 없음", "duplicateEmailsAllowed=false")은
    # 라이브 realm과 어긋났다. 이 realm의 User Profile 스키마는 email을 모든 계정에
    # 필수로 요구해, 특권 ID의 email을 비우면 로그인 중 Update Account Information
    # required action에 막힌다. duplicateEmailsAllowed는 실제로 true라 같은 주소를
    # 일상 ID와 공유해도 충돌하지 않는다. 검증 email 일치·emailVerified 요구는 일상
    # ID 5개에만 적용하고, 특권 ID의 email 값 자체는 검증하지 않는다(필수 스키마를
    # 만족하는 임의 값이면 충분하고, 원문을 Git·로그에 남기지 않는 요구와는 무관하다).
    definitions[PRIVILEGED_USER] = (None, ["/platform-privileged"])
    present = 0
    mfa_active = 0
    ready = True
    for username, (email, desired_paths) in definitions.items():
        user = find_user(kc, username)
        if user is None:
            ready = False
            if not apply:
                continue
            user = create_user(kc, username, email, desired_paths, secret_dir)
        present += 1
        if email is not None:
            if user.get("email", "").casefold() != email.casefold() or not user.get("emailVerified"):
                raise SafeError(f"existing Keycloak user email metadata drift: {username}")
        if not user.get("enabled"):
            raise SafeError(f"existing Keycloak user is disabled: {username}")
        if user.get("totp"):
            mfa_active += 1
        elif "CONFIGURE_TOTP" not in (user.get("requiredActions") or []):
            raise SafeError(f"Keycloak user lacks MFA enrollment requirement: {username}")
        memberships, _ = kc.request("GET", f"users/{user['id']}/groups?max=100")
        membership_paths = {group.get("path") for group in memberships}
        conflicting = (membership_paths & RELEVANT_GROUPS) - set(desired_paths)
        if conflicting:
            raise SafeError(f"existing Keycloak user has conflicting IAM-01 group: {username}")
        for path in desired_paths:
            group = groups.get(path)
            if group is None:
                ready = False
                continue
            if path not in membership_paths:
                ready = False
                if apply:
                    kc.request("PUT", f"users/{user['id']}/groups/{group['id']}", expected=(204,))
        if client is not None:
            direct, _ = kc.request(
                "GET", f"users/{user['id']}/role-mappings/clients/{client['id']}"
            )
            if {role.get("name") for role in direct} & set(SHUFFLE_ROLES.values()):
                raise SafeError(f"Keycloak user has a direct Shuffle role: {username}")
    return present, mfa_active, ready or apply


def configure_keycloak(
    repo_root: Path,
    secret_root: Path,
    connect_ip: str,
    temp_dir: Path,
    apply: bool,
    require_mfa_complete: bool = False,
) -> bool:
    emails = read_env(secret_root / "iam-01/env")
    iam_secret_dir = secret_root / "iam-01"
    iam_secret_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    kc = KeycloakAdmin(repo_root, secret_root, connect_ip, temp_dir)
    policy_ready = ensure_password_policy(kc, apply)
    groups = ensure_groups(kc, apply)
    client = ensure_client(kc, apply)
    mappers_ready = ensure_mappers(kc, client, apply)
    roles = ensure_client_roles(kc, client, apply)
    mappings_ready = ensure_scope_and_group_roles(kc, client, roles, groups, apply)
    present, mfa_active, users_ready = ensure_users(
        kc, emails, groups, client, iam_secret_dir, apply
    )
    ready = all(
        (
            policy_ready,
            set(RELEVANT_GROUPS) <= set(groups),
            client is not None,
            mappers_ready,
            mappings_ready,
            users_ready,
            present == 6,
            not require_mfa_complete or mfa_active == 6,
        )
    )
    state = "PASS" if ready else "PENDING"
    print(
        f"KeycloakIAM={state} users={present}/6 mfa_active={mfa_active}/6 "
        f"groups={len(set(RELEVANT_GROUPS) & set(groups))}/4 client={'present' if client else 'absent'}"
    )
    return ready


def totp_sha1(seed: str) -> str:
    normalized = seed.strip().upper()
    normalized += "=" * (-len(normalized) % 8)
    key = base64.b32decode(normalized, casefold=True)
    remaining = 30 - int(time.time()) % 30
    if remaining < 4:
        time.sleep(remaining + 1)
    counter = int(time.time()) // 30
    digest = hmac.new(key, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF
    return f"{value % 1_000_000:06d}"


def shuffle_request(module, opener, path: str, method="GET", payload=None):
    status, _url, body = module.request(
        opener, f"{SHUFFLE_URL}{path}", method=method, payload=payload
    )
    if status != 200:
        raise SafeError(f"Shuffle API failed: {method} {path} HTTP {status}")
    try:
        return json.loads(body)
    except json.JSONDecodeError:
        raise SafeError(f"Shuffle API returned invalid JSON: {method} {path}") from None


def shuffle_login(module, opener, password_file_path: Path, totp_file: Path):
    require_secret(password_file_path)
    payload = {
        "username": "soar-dash-01-admin",
        "password": password_file_path.read_text(encoding="utf-8").strip(),
    }
    if totp_file.exists():
        require_secret(totp_file)
        payload["mfa_code"] = totp_sha1(totp_file.read_text(encoding="utf-8"))
    response = shuffle_request(module, opener, "/api/v1/login", method="POST", payload=payload)
    if response.get("success") is not True:
        raise SafeError("Shuffle local admin login was rejected")


def write_seed(path: Path, seed: str) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(seed.rstrip("=") + "\n")


def shuffle_sso_expected(auto_provision_disabled: bool) -> dict:
    """Shuffle 2.2.1의 역의미 auto_provision 필드를 포함한 목표 SSO 설정."""
    return {
        "sso_entrypoint": "",
        "sso_certificate": "",
        "sso_long_certificate": "",
        "sso_certificate_hash": "",
        "client_id": SHUFFLE_CLIENT,
        "client_secret": "",
        "openid_authorization": f"{ISSUER}/realms/{REALM}/protocol/openid-connect/auth",
        "openid_token": f"{ISSUER}/realms/{REALM}/protocol/openid-connect/token",
        "SSORequired": False,
        # Shuffle 2.2.1은 true를 disable_auto_provision으로 해석한다.
        "auto_provision": auto_provision_disabled,
        "role_required": True,
        "skip_sso_for_admins": True,
    }


def configure_shuffle(
    repo_root: Path,
    secret_root: Path,
    connect_ip: str,
    apply: bool,
    auto_provision_disabled: bool = True,
    require_registered_users: bool = False,
) -> bool:
    module = load_module(
        "iam01_shuffle_routes", repo_root / "gitops/tools/soar-dash-01/verify-routes.py"
    )
    browser = module.load_pomerium_browser(repo_root)
    keycloak_secrets = secret_root / "keycloak"
    privileged_password = keycloak_secrets / "privileged-password"
    privileged_totp = keycloak_secrets / "privileged-totp"
    for path in (privileged_password, privileged_totp):
        require_secret(path)
    opener = module.login(
        browser,
        connect_ip,
        f"{SHUFFLE_URL}/",
        "imcherry-admin",
        str(privileged_password),
        str(privileged_totp),
    )
    local_password = secret_root / "shuffle/default-admin-password"
    local_totp = secret_root / "iam-01/shuffle-admin-totp"
    shuffle_login(module, opener, local_password, local_totp)
    info = shuffle_request(module, opener, "/api/v1/getinfo")
    if info.get("username") != "soar-dash-01-admin":
        raise SafeError("Shuffle local recovery identity drift")
    users = shuffle_request(module, opener, "/api/v1/users")
    matching_users = [
        user
        for user in users
        if isinstance(user, dict) and user.get("username") == "soar-dash-01-admin"
    ]
    if len(matching_users) != 1:
        raise SafeError("Shuffle local recovery user record is missing or duplicated")
    user = matching_users[0]
    if user.get("apikey"):
        raise SafeError("Shuffle local recovery account has an API key")
    active_org = info.get("active_org") or {}
    org_id = active_org.get("id")
    if not org_id:
        raise SafeError("Shuffle active organization is missing")
    orgs = shuffle_request(module, opener, "/api/v1/orgs")
    if len(orgs) != 1 or orgs[0].get("id") != org_id:
        raise SafeError("Shuffle organization topology differs from the single-org baseline")
    org = shuffle_request(module, opener, f"/api/v1/orgs/{org_id}")
    suborg_response = shuffle_request(module, opener, f"/api/v1/orgs/{org_id}/suborgs")
    suborgs = suborg_response.get("subOrgs") or []
    if suborgs or (org.get("child_orgs") or []):
        raise SafeError("Shuffle has sub-organizations")
    if require_registered_users:
        expected_roles = {
            **{username.casefold(): "org-reader" for username in DAILY_USERS},
            PRIVILEGED_USER.casefold(): "admin",
        }
        oidc_users = {
            item.get("generated_username", "").casefold(): item.get("role")
            for item in users
            if isinstance(item, dict)
            and item.get("generated_username")
        }
        if oidc_users != expected_roles:
            raise SafeError(
                f"Shuffle registration set is incomplete or has role drift: {len(oidc_users)}/6"
            )
    target_sso = shuffle_sso_expected(auto_provision_disabled)
    sso = org.get("sso_config") or {}
    sso_matches = all(
        sso.get(key) in ({value, "CLEANED"} if key == "client_id" else {value})
        for key, value in target_sso.items()
    )
    name_matches = org.get("name") == "Platform Security"
    if apply and (not sso_matches or not name_matches):
        payload = {
            "org_id": org_id,
            "name": "Platform Security",
            "editing": "sso_config",
            "sso_config": target_sso,
        }
        response = shuffle_request(
            module, opener, f"/api/v1/orgs/{org_id}", method="POST", payload=payload
        )
        if response.get("success") is not True:
            raise SafeError("Shuffle organization update was rejected")
        name_matches = True
        sso_matches = True
    mfa_active = bool((user.get("mfa_info") or {}).get("active"))
    if apply and not mfa_active:
        if not local_totp.exists():
            setup = shuffle_request(module, opener, f"/api/v1/users/{user['id']}/get2fa")
            encoded = setup.get("extra") or ""
            if len(encoded) != 16 or not encoded.endswith("AAA"):
                raise SafeError("Shuffle MFA setup returned an unexpected seed format")
            seed = encoded[:-3]
            write_seed(local_totp, seed)
        require_secret(local_totp)
        code = totp_sha1(local_totp.read_text(encoding="utf-8"))
        response = shuffle_request(
            module,
            opener,
            f"/api/v1/users/{user['id']}/set2fa",
            method="POST",
            payload={"code": code, "user_id": user["id"]},
        )
        if response.get("success") is not True or response.get("MFAActive") is not True:
            raise SafeError("Shuffle local recovery MFA activation was rejected")
        mfa_active = True
    ready = all((name_matches, sso_matches, mfa_active, not user.get("apikey")))
    state = "PASS" if ready else "PENDING"
    print(
        f"ShuffleIAM={state} organization={'target' if name_matches else 'baseline'} "
        f"oidc={'configured' if sso_matches else 'absent'} "
        f"auto_provision={('off' if auto_provision_disabled else 'on') if sso_matches else 'unset'} "
        f"role_required=true local_admin_mfa={'active' if mfa_active else 'inactive'} api_keys=0"
    )
    return ready


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "mode", choices=("check", "apply", "registration-open", "registration-close")
    )
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument(
        "--secret-root",
        type=Path,
        default=Path(os.environ.get("KTC_SECRET_ROOT", "/home/imcherry/secrets/ktcloud4-bean")),
    )
    parser.add_argument("--connect-ip", default="10.10.20.10")
    args = parser.parse_args()
    apply = args.mode in {"apply", "registration-open", "registration-close"}
    lock_path = Path("/tmp/iam-01-provision.lock")
    lock_descriptor = os.open(lock_path, os.O_WRONLY | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SafeError("IDENTITY-LIVE provisioning lock is held") from None
    with tempfile.TemporaryDirectory(prefix="iam-01-") as temp_name:
        temp_dir = Path(temp_name)
        keycloak_ready = configure_keycloak(
            args.repo_root.resolve(),
            args.secret_root,
            args.connect_ip,
            temp_dir,
            args.mode == "apply",
            require_mfa_complete=args.mode == "registration-close",
        )
        if args.mode in {"registration-open", "registration-close"} and not keycloak_ready:
            raise SafeError("Keycloak IAM declaration is not ready for a registration transition")
        shuffle_ready = configure_shuffle(
            args.repo_root.resolve(),
            args.secret_root,
            args.connect_ip,
            apply,
            auto_provision_disabled=args.mode != "registration-open",
            require_registered_users=args.mode == "registration-close",
        )
    if apply and not (keycloak_ready and shuffle_ready):
        raise SafeError("IAM-01 apply did not converge")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (SafeError, subprocess.CalledProcessError) as error:
        detail = str(error) if isinstance(error, SafeError) else "credentialed login failed"
        print(f"IAM-01 provision failed: {detail}", file=sys.stderr)
        raise SystemExit(1)
