#!/usr/bin/env python3
"""신규 Keycloak subject가 legacy AWX user에 email로 합쳐진 상태를 보정한다.

Keycloak user ID와 email은 비교·전달에만 쓰고 출력하지 않는다. legacy user와 기존
social-auth link는 삭제하지 않으며 rollback도 신규 user를 삭제하지 않고 비활성화한다.
"""

from __future__ import annotations

import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile


TARGETS = {
    "imcherry5778": "imcherry",
    "imcherry5778-admin": "imcherry-admin",
}


class SafeError(RuntimeError):
    pass


def load_iam_module(repo_root: Path):
    path = repo_root / "gitops/tools/iam-01/provision.py"
    spec = importlib.util.spec_from_file_location("awx02_iam_provision", path)
    if spec is None or spec.loader is None:
        raise SafeError("IAM helper를 읽을 수 없다")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def keycloak_users(repo_root: Path, secret_root: Path, connect_ip: str) -> list[dict]:
    iam = load_iam_module(repo_root)
    with tempfile.TemporaryDirectory(prefix="awx-02-keycloak-") as temp:
        try:
            kc = iam.KeycloakAdmin(repo_root, secret_root, connect_ip, Path(temp))
        except subprocess.CalledProcessError as error:
            raise SafeError("Keycloak recovery login이 실패했다") from error
        result = []
        for username, legacy_username in TARGETS.items():
            user = iam.find_user(kc, username)
            if user is None or not user.get("enabled") or not user.get("id") or not user.get("email"):
                raise SafeError(f"Keycloak 신규 ID가 enabled exact user가 아니다: {username}")
            result.append(
                {
                    "username": username,
                    "legacy_username": legacy_username,
                    "keycloak_id": user["id"],
                    "email": user["email"],
                    "first_name": user.get("firstName") or "",
                    "last_name": user.get("lastName") or "",
                }
            )
        return result


REMOTE_CODE = r'''
import json
import sys

from django.contrib.auth import get_user_model
from django.db import transaction
from awx.main.models import Organization, Team
from social_django.models import UserSocialAuth

payload = json.load(sys.stdin)
mode = payload["mode"]
targets = payload["targets"]
User = get_user_model()
organization = Organization.objects.get(name="Platform")
teams = list(Team.objects.filter(organization=organization).order_by("name"))

created = 0
moved = 0
disabled = 0

with transaction.atomic():
    for target in targets:
        username = target["username"]
        legacy_username = target["legacy_username"]
        legacy = User.objects.filter(username=legacy_username).get()
        links = UserSocialAuth.objects.filter(provider="oidc", uid=target["keycloak_id"])
        if links.count() != 1:
            raise RuntimeError(f"new subject link count drifted: {username}")
        link = links.get()
        new_user = User.objects.filter(username=username).first()

        if mode == "check":
            continue

        if mode == "apply":
            if link.user_id not in {legacy.id, getattr(new_user, "id", None)}:
                raise RuntimeError(f"new subject has unexpected owner: {username}")
            if new_user is None:
                new_user = User(
                    username=username,
                    email=target["email"],
                    first_name=target["first_name"],
                    last_name=target["last_name"],
                    is_active=True,
                    is_staff=False,
                    is_superuser=False,
                )
                new_user.set_unusable_password()
                new_user.save()
                created += 1
            elif new_user.is_superuser or new_user.is_staff:
                raise RuntimeError(f"new user privilege drifted: {username}")
            if link.user_id == legacy.id:
                link.user = new_user
                link.save(update_fields=["user"])
                moved += 1

        elif mode == "rollback":
            if new_user is None or link.user_id != new_user.id:
                raise RuntimeError(f"rollback link owner drifted: {username}")
            link.user = legacy
            link.save(update_fields=["user"])
            organization.member_role.members.remove(new_user)
            organization.admin_role.members.remove(new_user)
            for team in teams:
                team.member_role.members.remove(new_user)
            new_user.is_active = False
            new_user.is_staff = False
            new_user.is_superuser = False
            new_user.save(update_fields=["is_active", "is_staff", "is_superuser"])
            moved += 1
            disabled += 1
        else:
            raise RuntimeError("unsupported mode")

state = []
for target in targets:
    username = target["username"]
    legacy_username = target["legacy_username"]
    legacy = User.objects.get(username=legacy_username)
    new_user = User.objects.filter(username=username).first()
    link = UserSocialAuth.objects.get(provider="oidc", uid=target["keycloak_id"])
    state.append({
        "username": username,
        "legacy_preserved": legacy is not None,
        "new_exists": new_user is not None,
        "new_active": bool(new_user and new_user.is_active),
        "new_superuser": bool(new_user and new_user.is_superuser),
        "new_org_admin": bool(new_user and organization.admin_role.members.filter(pk=new_user.pk).exists()),
        "new_link_owner": "new" if new_user and link.user_id == new_user.id else "legacy" if link.user_id == legacy.id else "unexpected",
        "legacy_org_member": organization.member_role.members.filter(pk=legacy.pk).exists(),
        "legacy_org_admin": organization.admin_role.members.filter(pk=legacy.pk).exists(),
        "legacy_team_count": sum(team.member_role.members.filter(pk=legacy.pk).exists() for team in teams),
    })

print(json.dumps({"mode": mode, "created": created, "moved": moved, "disabled": disabled, "state": state}, sort_keys=True))
'''


def remote_awx(payload: dict, k3s_host: str, known_hosts: Path, kubectl: str) -> dict:
    command = (
        f"{kubectl} -n awx exec -i deploy/awx-web -c awx-web -- "
        f"awx-manage shell -c {shlex.quote(REMOTE_CODE)}"
    )
    result = subprocess.run(
        [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            f"UserKnownHostsFile={known_hosts}",
            k3s_host,
            command,
        ],
        input=json.dumps(payload, separators=(",", ":")),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise SafeError("AWX identity transaction이 실패했다. live 상태를 다시 확인해야 한다")
    try:
        return json.loads(result.stdout.strip().splitlines()[-1])
    except (IndexError, json.JSONDecodeError) as error:
        raise SafeError("AWX identity transaction 결과 형식이 잘못됐다") from error


def validate_result(mode: str, result: dict) -> None:
    states = result.get("state") or []
    if len(states) != len(TARGETS):
        raise SafeError("AWX identity result count drifted")
    if not all(
        state.get("legacy_preserved")
        and not state.get("legacy_org_member")
        and not state.get("legacy_org_admin")
        and state.get("legacy_team_count") == 0
        for state in states
    ):
        raise SafeError("legacy AWX identity가 최소권한 상태가 아니다")
    if mode == "apply":
        if not all(
            state.get("new_exists")
            and state.get("new_active")
            and not state.get("new_superuser")
            and not state.get("new_org_admin")
            and state.get("new_link_owner") == "new"
            for state in states
        ):
            raise SafeError("신규 AWX identity link 이동이 수렴하지 않았다")
    elif mode == "rollback":
        if not all(
            state.get("new_exists")
            and not state.get("new_active")
            and state.get("new_link_owner") == "legacy"
            for state in states
        ):
            raise SafeError("AWX identity rollback이 수렴하지 않았다")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("check", "apply", "rollback"))
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[3]
    secret_root = Path(os.environ.get("KTC_SECRET_ROOT", "/home/imcherry/secrets/ktcloud4-bean"))
    connect_ip = os.environ.get("AWX02_CONNECT_IP", "10.10.20.10")
    k3s_host = os.environ.get("K3S_HOST", "rocky@k3s-01.imcherry5778.xyz")
    known_hosts = Path(os.environ.get("K3S_SSH_KNOWN_HOSTS", "/home/imcherry/.ssh/known_hosts"))
    kubectl = os.environ.get("KUBECTL", "sudo -n /usr/local/bin/k3s kubectl")

    lock_path = Path("/tmp/awx-02-identity.lock")
    with lock_path.open("w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        targets = keycloak_users(repo_root, secret_root, connect_ip)
        result = remote_awx({"mode": args.mode, "targets": targets}, k3s_host, known_hosts, kubectl)
        validate_result(args.mode, result)

    print(
        f"AWX02_LINK_REASSIGN={args.mode.upper()} "
        f"created={result.get('created', 0)} moved={result.get('moved', 0)} "
        f"disabled={result.get('disabled', 0)} legacy_preserved=2 secret_literals=0"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (SafeError, BlockingIOError) as error:
        print(f"AWX02_LINK_REASSIGN=FAIL reason={error}", file=sys.stderr)
        raise SystemExit(1)
