#!/usr/bin/env python3
"""QUALITY-06 전용 합성 Keycloak identity와 HR fixture를 수렴한다.

E2E 자체는 read-only다. 이 도구의 apply만 새 합성 계정과 두 DB row를 한 번
만 준비하며, 기존 사람 계정·Git identity 선언·실사용자 group은 건드리지 않는다.
비밀번호·TOTP·email 원문은 출력하지 않는다.
"""

from __future__ import annotations

import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import secrets
import string
import urllib.error
import urllib.request


ISSUER = "https://sso.imcherry5778.xyz"
ADMIN_URL = "https://admin.imcherry5778.xyz"
REALM = "platform"
EMPLOYEE_USERNAME = "quality-06-employee"
EMPLOYEE_EMAIL = "quality-06.employee@e2e.imcherry5778.xyz"
EMPLOYEE_NAME = "QUALITY-06 Employee"
EMPLOYEE_FIRST_NAME = "QUALITY-06"
EMPLOYEE_LAST_NAME = "Employee"
HR_USERNAME = "quality-06-hr"
HR_EMAIL = "quality-06.hr@e2e.imcherry5778.xyz"
HR_NAME = "QUALITY-06 HR"
HR_FIRST_NAME = "QUALITY-06"
HR_LAST_NAME = "HR"


class SafeError(RuntimeError):
    pass


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise SafeError("module load failed")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def require_secret(path: Path) -> str:
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_mode & 0o077:
        raise SafeError(f"secret input must be a mode 0600 regular file: {path.name}")
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        raise SafeError(f"secret input is empty: {path.name}")
    return value


def write_secret(path: Path, value: str) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(value + "\n")


def ensure_password(path: Path) -> str:
    if not path.exists():
        alphabet = string.ascii_letters + string.digits + "!@#$%^&*()-_=+"
        while True:
            value = "".join(secrets.choice(alphabet) for _ in range(28))
            if (
                any(character.isupper() for character in value)
                and any(character.islower() for character in value)
                and any(character.isdigit() for character in value)
                and any(not character.isalnum() for character in value)
            ):
                break
        write_secret(path, value)
    value = require_secret(path)
    if len(value) < 20:
        raise SafeError(f"synthetic password is too short: {path.name}")
    return value


def ensure_totp(path: Path) -> str:
    if not path.exists():
        write_secret(path, base64.b32encode(secrets.token_bytes(20)).decode("ascii").rstrip("="))
    return require_secret(path)


def find_user(kc, username: str):
    users, _ = kc.request("GET", f"users?username={username}&exact=true&briefRepresentation=false")
    exact = [user for user in users if user.get("username", "").casefold() == username.casefold()]
    if len(exact) > 1:
        raise SafeError(f"duplicate synthetic Keycloak user: {username}")
    return exact[0] if exact else None


def find_groups(kc) -> dict[str, dict]:
    groups, _ = kc.request("GET", "groups?max=200&briefRepresentation=false")
    result = {}
    for group in groups:
        if group.get("path"):
            result[group["path"]] = group
    return result


def identity(kc, *, username: str, email: str, first_name: str, last_name: str, group_path: str, secret_dir: Path, apply: bool):
    password_path = secret_dir / f"{username}-password"
    totp_path = secret_dir / f"{username}-totp"
    user = find_user(kc, username)
    if user is None and not apply:
        return None, False
    password = ensure_password(password_path) if user is None and apply else require_secret(password_path)
    totp = ensure_totp(totp_path) if user is None and apply else require_secret(totp_path)
    if user is None:
        credential = {
            "type": "otp",
            "userLabel": "QUALITY-06 synthetic TOTP",
            "secretData": json.dumps({"value": totp}, separators=(",", ":")),
            "credentialData": json.dumps(
                {
                    "subType": "totp",
                    "digits": 6,
                    "counter": 0,
                    "period": 30,
                    "algorithm": "HmacSHA256",
                    "secretEncoding": "BASE32",
                },
                separators=(",", ":"),
            ),
        }
        kc.request(
            "POST",
            "users",
            {
                "username": username,
                "enabled": True,
                "email": email,
                "emailVerified": True,
                "firstName": first_name,
                "lastName": last_name,
                "requiredActions": [],
                "groups": [group_path],
                "credentials": [
                    {"type": "password", "value": password, "temporary": False},
                    credential,
                ],
            },
            expected=(201,),
        )
        user = find_user(kc, username)
        if user is None:
            raise SafeError(f"synthetic Keycloak user did not converge: {username}")

    profile_drift = (
        user.get("firstName") != first_name
        or user.get("lastName") != last_name
    )
    if profile_drift:
        if not apply:
            raise SafeError(f"synthetic Keycloak profile drift: {username}")
        kc.request(
            "PUT",
            f"users/{user['id']}",
            {"firstName": first_name, "lastName": last_name},
            expected=(204,),
        )
        user = find_user(kc, username)

    required_actions = set(user.get("requiredActions") or [])
    if required_actions:
        if not apply or required_actions != {"CONFIGURE_TOTP"}:
            raise SafeError(f"synthetic Keycloak identity metadata drift: {username}")
        kc.request("PUT", f"users/{user['id']}", {"requiredActions": []}, expected=(204,))
        user = find_user(kc, username)
    if (
        not user
        or user.get("email", "").casefold() != email.casefold()
        or not user.get("emailVerified")
        or not user.get("enabled")
        or user.get("firstName") != first_name
        or user.get("lastName") != last_name
        or user.get("requiredActions")
    ):
        raise SafeError(f"synthetic Keycloak identity metadata drift: {username}")

    memberships, _ = kc.request("GET", f"users/{user['id']}/groups?max=100")
    paths = {group.get("path") for group in memberships}
    conflicting = paths & {"/hr-users", "/hr-admins"} - {group_path}
    if conflicting:
        raise SafeError(f"synthetic Keycloak identity has conflicting HR group: {username}")
    groups = find_groups(kc)
    target = groups.get(group_path)
    if target is None:
        raise SafeError(f"required HR group is missing: {group_path}")
    if group_path not in paths:
        if not apply:
            return user, False
        kc.request("PUT", f"users/{user['id']}/groups/{target['id']}", expected=(204,))

    user = find_user(kc, username)
    if not user or not user.get("totp"):
        raise SafeError(f"synthetic Keycloak TOTP credential is missing: {username}")
    return user, True


def http_json(opener, url: str, method: str = "GET", payload=None):
    body = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with opener.open(request, timeout=30) as response:
            raw = response.read()
            return response.status, json.loads(raw) if raw else None
    except urllib.error.HTTPError as error:
        raw = error.read()
        try:
            body = json.loads(raw) if raw else None
        except json.JSONDecodeError:
            body = None
        return error.code, body


def login(opener_module, username: str, password_file: Path, totp_file: Path, connect_ip: str):
    opener_module.EXPECTED_HOSTS.update(
        {"www.imcherry5778.xyz", "admin.imcherry5778.xyz"}
    )
    jar = opener_module.http.cookiejar.CookieJar()
    opener = opener_module.build_opener(jar, connect_ip)
    status, final_url, _ = opener_module.login(
        opener, f"{ADMIN_URL}/", username, str(password_file), str(totp_file)
    )
    if status != 200 or final_url != f"{ADMIN_URL}/":
        raise SafeError(f"HR setup login failed: HTTP {status}")
    return opener


def fixture(opener, *, apply: bool):
    status, employees = http_json(opener, f"{ADMIN_URL}/api/hr/employees")
    if status != 200 or not isinstance(employees, list):
        raise SafeError(f"HR employee list failed: HTTP {status}")
    matches = [item for item in employees if item.get("email", "").casefold() == EMPLOYEE_EMAIL]
    if len(matches) > 1:
        raise SafeError("synthetic employee fixture is duplicated")
    if not matches:
        if not apply:
            return False
        status, created = http_json(
            opener,
            f"{ADMIN_URL}/api/hr/employees",
            "POST",
            {
                "email": EMPLOYEE_EMAIL,
                "name": EMPLOYEE_NAME,
                "department": "QUALITY-06",
                "position": "Synthetic Employee",
                "salary": 0,
                "is_hr": False,
            },
        )
        if status != 200 or not isinstance(created, dict) or created.get("email", "").casefold() != EMPLOYEE_EMAIL:
            raise SafeError(f"synthetic employee fixture create failed: HTTP {status}")

    status, created = http_json(
        opener,
        f"{ADMIN_URL}/api/hr/employees",
        "POST" if apply else "GET",
        {
            "email": HR_EMAIL,
            "name": HR_NAME,
            "department": "QUALITY-06",
            "position": "Synthetic HR",
            "salary": 0,
            "is_hr": True,
        }
        if apply
        else None,
    )
    if apply and status not in (200, 400):
        raise SafeError(f"synthetic HR fixture create failed: HTTP {status}")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("--check", "--apply"), required=True)
    parser.add_argument("--secret-dir", type=Path, default=Path("/home/imcherry/secrets/ktcloud4-bean/hr-system-e2e"))
    parser.add_argument("--connect-ip", default="10.10.20.10")
    parser.add_argument("--setup-username", default="imcherry5778")
    parser.add_argument("--setup-password-file", type=Path, required=True)
    parser.add_argument("--setup-totp-file", type=Path, required=True)
    args = parser.parse_args()
    apply = args.mode == "--apply"
    secret_dir = args.secret_dir
    secret_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if secret_dir.stat().st_mode & 0o077:
        raise SafeError("synthetic secret directory must be mode 0700")

    repo_root = Path(__file__).resolve().parents[3]
    iam = load_module("quality06_iam", repo_root / "gitops/tools/iam-01/provision.py")
    with __import__("tempfile").TemporaryDirectory(prefix="quality06-kc-") as temp:
        kc = iam.KeycloakAdmin(repo_root, Path("/home/imcherry/secrets/ktcloud4-bean"), args.connect_ip, Path(temp))
        employee, employee_ready = identity(
            kc, username=EMPLOYEE_USERNAME, email=EMPLOYEE_EMAIL,
            first_name=EMPLOYEE_FIRST_NAME, last_name=EMPLOYEE_LAST_NAME,
            group_path="/hr-users", secret_dir=secret_dir, apply=apply,
        )
        hr, hr_ready = identity(
            kc, username=HR_USERNAME, email=HR_EMAIL,
            first_name=HR_FIRST_NAME, last_name=HR_LAST_NAME,
            group_path="/hr-admins", secret_dir=secret_dir, apply=apply,
        )
        if not apply and not (employee and hr and employee_ready and hr_ready):
            raise SafeError("synthetic Keycloak identity is not ready")

    browser = load_module("quality06_browser", repo_root / "gitops/tools/pom-01/browser-session.py")
    setup_opener = login(
        browser, args.setup_username, args.setup_password_file, args.setup_totp_file, args.connect_ip
    )
    fixture_ready = fixture(setup_opener, apply=apply)
    if not fixture_ready:
        raise SafeError("synthetic employee fixture is absent")
    print("QUALITY06_SYNTHETIC=PASS identities=2 employee_fixture=present hr_fixture=present")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"QUALITY-06 synthetic provisioning failed: {error}", file=__import__("sys").stderr)
        raise SystemExit(1)
