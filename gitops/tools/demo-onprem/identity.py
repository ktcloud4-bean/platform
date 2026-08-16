#!/usr/bin/env python3
"""DEMO-ONPREM-01 합성 계정 하나만 생성·검사·삭제한다."""

from __future__ import annotations

import argparse
import base64
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import secrets
import string
import tempfile
import time


USERNAME = "demo-onprem-user"
EMAIL = "demo-onprem-user@example.invalid"
FIRST_NAME = "DEMO-ONPREM-01"
LAST_NAME = "Synthetic"
GROUP = "/platform-users"
SECRET_DIR = Path("/home/imcherry/secrets/ktcloud4-bean/demo-onprem")
LOCK_PATH = Path("/tmp/iam-01-provision.lock")
STATE_DIR = Path("/tmp/demo-onprem-01-state")
ADMIN_TOTP_STEP = STATE_DIR / "keycloak-admin-totp-step"
RESET_COMPLETE = STATE_DIR / "identity-reset-complete"


class SafeError(RuntimeError):
    pass


def load_iam(repo: Path):
    path = repo / "gitops/tools/iam-01/provision.py"
    spec = importlib.util.spec_from_file_location("demo_onprem_iam", path)
    if spec is None or spec.loader is None:
        raise SafeError("IAM helper load failed")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_once(path: Path, value: str) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(value + "\n")


def require_secret(path: Path) -> str:
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_mode & 0o077:
        raise SafeError(f"protected input mode is invalid: {path.name}")
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        raise SafeError(f"protected input is empty: {path.name}")
    return value


def prepare_state() -> None:
    STATE_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    metadata = STATE_DIR.lstat()
    if STATE_DIR.is_symlink() or metadata.st_mode & 0o077:
        raise SafeError("synthetic state directory must be mode 0700")


def write_state(path: Path, value: str) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(value + "\n")


def wait_for_fresh_admin_totp() -> None:
    try:
        previous_step = int(ADMIN_TOTP_STEP.read_text(encoding="utf-8").strip())
    except (FileNotFoundError, ValueError):
        return
    now = time.time()
    current_step = int(now) // 30
    if previous_step >= current_step:
        time.sleep(((previous_step + 1) * 30) - now + 2)


def owned_required_actions(user) -> bool:
    actions = user.get("requiredActions") or []
    return isinstance(actions, list) and set(actions) <= {"CONFIGURE_TOTP"}


def ensure_secrets() -> tuple[str, str]:
    SECRET_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    if SECRET_DIR.stat().st_mode & 0o077:
        raise SafeError("synthetic secret directory must be mode 0700")
    password_path = SECRET_DIR / "password"
    totp_path = SECRET_DIR / "totp"
    if not password_path.exists():
        alphabet = string.ascii_letters + string.digits + "!@#$%^&*()-_=+"
        while True:
            password = "".join(secrets.choice(alphabet) for _ in range(28))
            if all((any(c.isupper() for c in password), any(c.islower() for c in password),
                    any(c.isdigit() for c in password), any(not c.isalnum() for c in password))):
                break
        write_once(password_path, password)
    if not totp_path.exists():
        write_once(totp_path, base64.b32encode(secrets.token_bytes(20)).decode().rstrip("="))
    return require_secret(password_path), require_secret(totp_path)


def find_user(kc):
    users, _ = kc.request("GET", f"users?username={USERNAME}&exact=true&briefRepresentation=false")
    exact = [item for item in users if item.get("username", "").casefold() == USERNAME]
    if len(exact) > 1:
        raise SafeError("duplicate synthetic identity")
    return exact[0] if exact else None


def group_paths(kc, user_id: str) -> set[str]:
    groups, _ = kc.request("GET", f"users/{user_id}/groups?max=200")
    return {str(group.get("path")) for group in groups if group.get("path")}


def validate(kc, user) -> None:
    if not user:
        raise SafeError("synthetic identity is absent")
    expected = (
        user.get("email", "").casefold() == EMAIL
        and user.get("emailVerified") is True
        and user.get("enabled") is True
        and user.get("firstName") == FIRST_NAME
        and user.get("lastName") == LAST_NAME
        and not user.get("requiredActions")
        and user.get("totp") is True
    )
    if not expected or group_paths(kc, user["id"]) != {GROUP}:
        raise SafeError("synthetic identity metadata/group drift")


def validate_owned(kc, user) -> None:
    if not user:
        raise SafeError("synthetic identity is absent")
    expected = (
        user.get("email", "").casefold() == EMAIL
        and user.get("emailVerified") is True
        and user.get("enabled") is True
        and user.get("firstName") == FIRST_NAME
        and user.get("lastName") == LAST_NAME
        and user.get("totp") is True
        and owned_required_actions(user)
    )
    if not expected or group_paths(kc, user["id"]) != {GROUP}:
        raise SafeError("existing identity is not the task-owned synthetic account")


def run(command: str, repo: Path) -> None:
    prepare_state()
    if command == "apply":
        RESET_COMPLETE.unlink(missing_ok=True)
    elif RESET_COMPLETE.exists():
        print("DEMO_IDENTITY_RESET=PASS account=absent")
        return
    wait_for_fresh_admin_totp()
    iam = load_iam(repo)
    with tempfile.TemporaryDirectory(prefix="demo-onprem-kc-") as temp:
        kc = iam.KeycloakAdmin(repo, Path("/home/imcherry/secrets/ktcloud4-bean"), "10.10.20.10", Path(temp))
        write_state(ADMIN_TOTP_STEP, str(int(time.time()) // 30))
        user = find_user(kc)
        if command == "apply" and user is None:
            password, seed = ensure_secrets()
            all_groups, _ = kc.request("GET", "groups?max=200&briefRepresentation=false")
            groups = {item.get("path"): item for item in all_groups}
            if GROUP not in groups:
                raise SafeError("platform-users group is absent")
            kc.request("POST", "users", {
                "username": USERNAME,
                "enabled": True,
                "email": EMAIL,
                "emailVerified": True,
                "firstName": FIRST_NAME,
                "lastName": LAST_NAME,
                "requiredActions": [],
                "groups": [GROUP],
                "credentials": [
                    {"type": "password", "value": password, "temporary": False},
                    {
                        "type": "otp",
                        "userLabel": "DEMO-ONPREM-01 synthetic TOTP",
                        "secretData": json.dumps({"value": seed}, separators=(",", ":")),
                        "credentialData": json.dumps({
                            "subType": "totp", "digits": 6, "counter": 0, "period": 30,
                            "algorithm": "HmacSHA256", "secretEncoding": "BASE32",
                        }, separators=(",", ":")),
                    },
                ],
            }, expected=(201,))
            user = find_user(kc)
        if command in {"apply", "check"}:
            validate_owned(kc, user)
            if user.get("requiredActions"):
                kc.request("PUT", f"users/{user['id']}", {"requiredActions": []}, expected=(204,))
                user = find_user(kc)
            # check는 자격증명을 출력하지 않고 파일 mode만 함께 판정한다.
            require_secret(SECRET_DIR / "password")
            require_secret(SECRET_DIR / "totp")
            validate(kc, user)
            print("DEMO_IDENTITY=PASS account=synthetic groups=platform-users-only secrets=masked")
            return
        if user is not None:
            validate_owned(kc, user)
            kc.request("DELETE", f"users/{user['id']}", expected=(204,))
        write_state(RESET_COMPLETE, "complete")
        print("DEMO_IDENTITY_RESET=PASS account=absent")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("check", "apply", "rollback"))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    try:
        if os.environ.get("DEMO_IDENTITY_LOCK_HELD") == "1":
            run(args.command, repo)
            return 0
        with LOCK_PATH.open("w", encoding="utf-8") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            run(args.command, repo)
    except (SafeError, BlockingIOError, FileNotFoundError) as error:
        print(f"DEMO_IDENTITY=FAIL reason={error}", file=__import__("sys").stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
