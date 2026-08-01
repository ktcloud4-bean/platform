#!/usr/bin/env python3
"""NB-02 NetBird 단일 account의 JWT groups 접근 정책을 선언적으로 맞춘다."""

import argparse
import http.client
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

STAGE = "initialization"

class FixedAddressHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, *, fixed_ip: str, expected_host: str, **kwargs):
        self.fixed_ip = fixed_ip
        self.expected_host = expected_host
        super().__init__(host, **kwargs)

    def connect(self):
        if self.host != self.expected_host:
            raise OSError("fixed-address request left the NetBird host")
        self.sock = self._create_connection((self.fixed_ip, self.port), self.timeout, self.source_address)
        if self._tunnel_host:
            self._tunnel()
        self.sock = self._context.wrap_socket(self.sock, server_hostname=self.expected_host)


class FixedAddressHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, fixed_ip: str, expected_host: str):
        super().__init__()
        self.fixed_ip = fixed_ip
        self.expected_host = expected_host

    def https_open(self, request):
        def connection(host, **kwargs):
            return FixedAddressHTTPSConnection(host, fixed_ip=self.fixed_ip, expected_host=self.expected_host, **kwargs)

        return self.do_open(connection, request, context=self._context)


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--browser-login-script", required=True)
    parser.add_argument("--issuer-base", required=True)
    parser.add_argument("--issuer-connect-ip", required=True)
    parser.add_argument("--netbird-url", required=True)
    parser.add_argument("--netbird-connect-ip", required=True)
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--totp-file", required=True)
    parser.add_argument("--allow-group", action="append", required=True)
    return parser.parse_args()


def api(opener, base, bearer, method, path, payload=None):
    data = None
    headers = {"Authorization": bearer}
    if payload is not None:
        data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(f"{base}{path}", data=data, headers=headers, method=method)
    with opener.open(request, timeout=20) as response:
        raw = response.read()
        return json.loads(raw) if raw else None


def main():
    global STAGE
    STAGE = "argument validation"
    args = arguments()
    issuer = urllib.parse.urlsplit(args.issuer_base)
    netbird = urllib.parse.urlsplit(args.netbird_url)
    if issuer.scheme != "https" or not issuer.hostname or netbird.scheme != "https" or not netbird.hostname:
        raise RuntimeError("issuer and NetBird URL must be HTTPS origins")
    for address in (args.issuer_connect_ip, args.netbird_connect_ip):
        if ipaddress.ip_address(address).version != 4:
            raise RuntimeError("fixed addresses must be IPv4")
    for path in (args.browser_login_script, args.password_file, args.totp_file):
        if not Path(path).is_file():
            raise RuntimeError("required external credential input missing")

    with tempfile.TemporaryDirectory(prefix="nb02-account-") as temporary:
        header_file = Path(temporary) / "header"
        # browser-login.py는 실제 redirect 수신을 확인하므로, 공개 DNS/NAT를
        # 만들지 않고 loopback callback만 이 프로세스 동안 연다.
        callback = subprocess.Popen(
            [sys.executable, "-m", "http.server", "53000", "--bind", "127.0.0.1"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        try:
            STAGE = "owner browser login"
            subprocess.run(
                [
                    sys.executable,
                    args.browser_login_script,
                    "--issuer",
                    args.issuer_base,
                    "--realm",
                    "platform",
                    "--client-id",
                    args.client_id,
                    "--redirect-uri",
                    "http://localhost:53000/",
                    "--username",
                    args.username,
                    "--password-file",
                    args.password_file,
                    "--totp-file",
                    args.totp_file,
                    "--header-file",
                    str(header_file),
                    "--connect-ip",
                    args.issuer_connect_ip,
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
        finally:
            callback.terminate()
            callback.wait(timeout=5)

        authorization_header = header_file.read_text(encoding="utf-8").strip()
        if not authorization_header.startswith("Authorization: Bearer "):
            raise RuntimeError("owner OIDC login did not return a bearer header")
        bearer = authorization_header.partition(":")[2].strip()
        opener = urllib.request.build_opener(FixedAddressHTTPSHandler(args.netbird_connect_ip, netbird.hostname))
        STAGE = "NetBird account read"
        accounts = api(opener, args.netbird_url, bearer, "GET", "/api/accounts")
        if not isinstance(accounts, list) or len(accounts) != 1:
            raise RuntimeError("single-account-mode did not return exactly one account")
        account = accounts[0]
        settings = account.get("settings")
        if not isinstance(settings, dict) or not account.get("id"):
            raise RuntimeError("NetBird account response is incomplete")
        desired_groups = sorted(set(args.allow_group))
        already = (
            settings.get("jwt_groups_enabled") is True
            and settings.get("jwt_groups_claim_name") == "groups"
            and sorted(settings.get("jwt_allow_groups") or []) == desired_groups
            and settings.get("groups_propagation_enabled") is True
        )
        if not already:
            settings["jwt_groups_enabled"] = True
            settings["jwt_groups_claim_name"] = "groups"
            settings["jwt_allow_groups"] = desired_groups
            settings["groups_propagation_enabled"] = True
            STAGE = "NetBird JWT group policy write"
            updated = api(
                opener,
                args.netbird_url,
                bearer,
                "PUT",
                f"/api/accounts/{account['id']}",
                {"settings": settings, "onboarding": account.get("onboarding")},
            )
            updated_settings = updated.get("settings", {}) if isinstance(updated, dict) else {}
            if not (
                updated_settings.get("jwt_groups_enabled") is True
                and updated_settings.get("jwt_groups_claim_name") == "groups"
                and sorted(updated_settings.get("jwt_allow_groups") or []) == desired_groups
                and updated_settings.get("groups_propagation_enabled") is True
            ):
                raise RuntimeError("NetBird JWT group policy write was not persisted")
    print(f"changed={'false' if already else 'true'}")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        status = getattr(error, "code", "n/a")
        print(f"NB-02 NetBird account policy provisioning failed: stage={STAGE}, type={type(error).__name__}, status={status}", file=sys.stderr)
        raise SystemExit(1)
