#!/usr/bin/env python3
"""Keycloak 정지 중 Shuffle local recovery MFA 로그인과 API key 0건을 증명한다."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import http.cookiejar
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request


class SafeError(RuntimeError):
    pass


def require_secret(path: Path) -> None:
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_mode & 0o077:
        raise SafeError(f"secret input must be a mode 0600 regular file: {path.name}")


def totp(seed_file: Path) -> str:
    require_secret(seed_file)
    encoded = seed_file.read_text(encoding="utf-8").strip().upper()
    encoded += "=" * (-len(encoded) % 8)
    seed = base64.b32decode(encoded, casefold=True)
    remaining = 30 - int(time.time()) % 30
    if remaining < 4:
        time.sleep(remaining + 1)
    counter = int(time.time()) // 30
    digest = hmac.new(seed, struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF
    return f"{value % 1_000_000:06d}"


class Remote:
    def __init__(self, host: str, known_hosts: Path):
        if not known_hosts.is_file() or known_hosts.is_symlink():
            raise SafeError("authenticated known_hosts file is unavailable")
        self.host = host
        self.options = [
            "-o",
            "BatchMode=yes",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            f"UserKnownHostsFile={known_hosts}",
            "-o",
            "ConnectTimeout=10",
        ]

    def run(self, command: str, label: str) -> str:
        try:
            result = subprocess.run(
                ["ssh", *self.options, self.host, command],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
        except subprocess.CalledProcessError:
            raise SafeError(f"trusted remote command failed: {label}") from None
        return result.stdout.strip()


def wait_tcp(port: int, process: subprocess.Popen) -> None:
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise SafeError("trusted SSH Shuffle port-forward exited")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return
        except OSError:
            time.sleep(0.25)
    raise SafeError("trusted SSH Shuffle port-forward did not become ready")


def local_login(port: int, password_file: Path, totp_file: Path) -> None:
    require_secret(password_file)
    payload = json.dumps(
        {
            "username": "soar-dash-01-admin",
            "password": password_file.read_text(encoding="utf-8").strip(),
            "mfa_code": totp(totp_file),
        }
    ).encode("utf-8")
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()),
    )
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/v1/login",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with opener.open(request, timeout=20) as response:
            body = response.read()
            status = response.status
            set_cookies = response.headers.get_all("Set-Cookie") or []
    except urllib.error.HTTPError as error:
        error.read()
        raise SafeError(f"Shuffle local login failed with HTTP {error.code}") from None
    if status != 200:
        raise SafeError(f"Shuffle local login returned HTTP {status}")
    try:
        result = json.loads(body)
    except json.JSONDecodeError:
        raise SafeError("Shuffle local login returned invalid JSON") from None
    if result.get("success") is not True:
        raise SafeError("Shuffle local login was rejected")
    cookie_header = "; ".join(cookie.split(";", 1)[0] for cookie in set_cookies)
    if not cookie_header:
        raise SafeError("Shuffle local login did not establish a session")
    users_request = urllib.request.Request(
        f"http://127.0.0.1:{port}/api/v1/users",
        headers={"Cookie": cookie_header, "Accept": "application/json"},
    )
    try:
        with opener.open(users_request, timeout=20) as response:
            users_body = response.read()
            users_status = response.status
    except urllib.error.HTTPError as error:
        error.read()
        raise SafeError(f"Shuffle local user check failed with HTTP {error.code}") from None
    if users_status != 200:
        raise SafeError(f"Shuffle local user check returned HTTP {users_status}")
    try:
        users = json.loads(users_body)
    except json.JSONDecodeError:
        raise SafeError("Shuffle local user check returned invalid JSON") from None
    matches = [
        user
        for user in users
        if isinstance(user, dict) and user.get("username") == "soar-dash-01-admin"
    ]
    if len(matches) != 1:
        raise SafeError("Shuffle local recovery user record is missing or duplicated")
    if matches[0].get("apikey"):
        raise SafeError("Shuffle local recovery account has an API key")
    if not (matches[0].get("mfa_info") or {}).get("active"):
        raise SafeError("Shuffle local recovery MFA is not active")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--secret-root",
        type=Path,
        default=Path(os.environ.get("KTC_SECRET_ROOT", "/home/imcherry/secrets/ktcloud4-bean")),
    )
    parser.add_argument("--host", default="rocky@k3s-01.imcherry5778.xyz")
    parser.add_argument("--known-hosts", type=Path, default=Path("/home/imcherry/.ssh/known_hosts"))
    parser.add_argument("--local-port", type=int, default=15001)
    args = parser.parse_args()
    if not 1024 <= args.local_port <= 65535:
        raise SafeError("local port is outside the unprivileged range")
    password_file = args.secret_root / "shuffle/default-admin-password"
    totp_file = args.secret_root / "iam-01/shuffle-admin-totp"
    require_secret(password_file)
    require_secret(totp_file)
    remote = Remote(args.host, args.known_hosts)
    kubectl = "sudo -n /usr/local/bin/k3s kubectl"
    replicas = remote.run(
        f"{kubectl} -n keycloak get deployment keycloak -o jsonpath='{{.spec.replicas}}'",
        "read Keycloak replica baseline",
    )
    if replicas != "1":
        raise SafeError("Keycloak deployment replica baseline is not one")
    root_self_heal = remote.run(
        f"{kubectl} -n argocd get application platform-root "
        "-o jsonpath='{.spec.syncPolicy.automated.selfHeal}'",
        "read platform-root selfHeal baseline",
    )
    if root_self_heal != "true":
        raise SafeError("platform-root Application selfHeal baseline is not true")
    automated = remote.run(
        f"{kubectl} -n argocd get application keycloak "
        "-o jsonpath='{.spec.syncPolicy.automated.prune}|{.spec.syncPolicy.automated.selfHeal}'",
        "read Keycloak Application automated sync baseline",
    )
    if automated != "true|true":
        raise SafeError("Keycloak Application automated sync baseline is not prune=true,selfHeal=true")
    tunnel_command = (
        f"{kubectl} -n shuffle port-forward --address=127.0.0.1 "
        f"service/shuffle-backend {args.local_port}:5001"
    )
    tunnel = subprocess.Popen(
        [
            "ssh",
            *remote.options,
            "-L",
            f"127.0.0.1:{args.local_port}:127.0.0.1:{args.local_port}",
            args.host,
            tunnel_command,
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    keycloak_stopped = False
    root_self_heal_disabled = False
    automated_disabled = False
    try:
        wait_tcp(args.local_port, tunnel)
        remote.run(
            f"{kubectl} -n argocd patch application platform-root --type=merge "
            "-p '{\"spec\":{\"syncPolicy\":{\"automated\":{\"selfHeal\":false}}}}'",
            "disable platform-root selfHeal",
        )
        root_self_heal_disabled = True
        remote.run(
            f"{kubectl} -n argocd patch application keycloak --type=json "
            "-p '[{\"op\":\"remove\",\"path\":\"/spec/syncPolicy/automated\"}]'",
            "disable Keycloak Application automated sync",
        )
        automated_disabled = True
        remote.run(
            "for i in $(seq 1 15); do "
            f"root_heal=$({kubectl} -n argocd get application platform-root "
            "-o jsonpath='{.spec.syncPolicy.automated.selfHeal}'); "
            f"child_auto=$({kubectl} -n argocd get application keycloak "
            "-o jsonpath='{.spec.syncPolicy.automated}'); "
            f"phase=$({kubectl} -n argocd get application keycloak "
            "-o jsonpath='{.status.operationState.phase}'); "
            "if [ \"$root_heal\" = false ] && [ -z \"$child_auto\" ] "
            "&& [ \"$phase\" != Running ] && [ \"$phase\" != Terminating ]; then "
            "sleep 3; "
            f"test \"$({kubectl} -n argocd get application platform-root "
            "-o jsonpath='{.spec.syncPolicy.automated.selfHeal}')\" = false && "
            f"test -z \"$({kubectl} -n argocd get application keycloak "
            "-o jsonpath='{.spec.syncPolicy.automated}')\" && exit 0; "
            "fi; sleep 1; done; exit 1",
            "wait for manual-sync maintenance window",
        )
        remote.run(
            f"{kubectl} -n keycloak scale deployment keycloak --replicas=0",
            "scale Keycloak to zero",
        )
        keycloak_stopped = True
        remote.run(
            f"{kubectl} -n keycloak wait --for=delete pod "
            "-l app.kubernetes.io/component=server --timeout=120s",
            "wait for Keycloak server pod deletion",
        )
        if remote.run(
            f"{kubectl} -n keycloak get pods -l app.kubernetes.io/component=server "
            "--no-headers 2>/dev/null | wc -l",
            "count stopped Keycloak server pods",
        ) != "0":
            raise SafeError("Keycloak pods are not fully stopped")
        local_login(args.local_port, password_file, totp_file)
        if remote.run(
            f"{kubectl} -n keycloak get pods -l app.kubernetes.io/component=server "
            "--no-headers 2>/dev/null | wc -l",
            "recount stopped Keycloak server pods",
        ) != "0":
            raise SafeError("Keycloak restarted before the local login verdict")
    finally:
        restore_error: Exception | None = None
        if keycloak_stopped:
            try:
                remote.run(
                    f"{kubectl} -n keycloak scale deployment keycloak --replicas=1",
                    "restore Keycloak replica",
                )
                remote.run(
                    f"{kubectl} -n keycloak rollout status deployment/keycloak --timeout=180s",
                    "wait for Keycloak replica restore",
                )
            except Exception as error:
                print("IAM-01 recovery verifier: Keycloak replica restore failed", file=sys.stderr)
                restore_error = error
        if automated_disabled:
            try:
                remote.run(
                    f"{kubectl} -n argocd patch application keycloak --type=merge "
                    "-p '{\"spec\":{\"syncPolicy\":{\"automated\":{\"prune\":true,\"selfHeal\":true}}}}'",
                    "restore Keycloak Application automated sync",
                )
            except Exception as error:
                print("IAM-01 recovery verifier: Argo automated sync restore failed", file=sys.stderr)
                restore_error = restore_error or error
        if root_self_heal_disabled:
            try:
                remote.run(
                    f"{kubectl} -n argocd patch application platform-root --type=merge "
                    "-p '{\"spec\":{\"syncPolicy\":{\"automated\":{\"selfHeal\":true}}}}'",
                    "restore platform-root selfHeal",
                )
            except Exception as error:
                print("IAM-01 recovery verifier: root selfHeal restore failed", file=sys.stderr)
                restore_error = restore_error or error
        tunnel.terminate()
        try:
            tunnel.wait(timeout=5)
        except subprocess.TimeoutExpired:
            tunnel.kill()
            tunnel.wait(timeout=5)
        if restore_error is not None:
            raise restore_error
    print(
        "IAM01Recovery=PASS keycloak_server_pods=0 local_login=mfa_success "
        "api_keys=0 restore=Ready automated_sync=restored"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (SafeError, subprocess.CalledProcessError) as error:
        detail = str(error) if isinstance(error, SafeError) else "trusted remote command failed"
        print(f"IAM-01 recovery verification failed: {detail}", file=sys.stderr)
        raise SystemExit(1)
