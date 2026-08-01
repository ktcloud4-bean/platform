#!/usr/bin/env python3
"""WG-02 Warpgate SSO, target authorization, WebSSH recording verifier."""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
from html.parser import HTMLParser
import http.cookiejar
import json
import os
from pathlib import Path
import re
import shlex
import socket
import ssl
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


STAGE = "initialization"


class LoginFormParser(HTMLParser):
    def __init__(self, form_id: str):
        super().__init__()
        self.form_id = form_id
        self.action: str | None = None

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag == "form" and attributes.get("id") == self.form_id:
            self.action = attributes.get("action")


def form_action(document: bytes, form_id: str) -> str:
    parser = LoginFormParser(form_id)
    parser.feed(document.decode("utf-8"))
    if not parser.action:
        raise RuntimeError(f"missing form: {form_id}")
    return parser.action


def check_secret_file(path: str) -> Path:
    source = Path(path)
    stat = source.lstat()
    if not source.is_file() or source.is_symlink() or stat.st_mode & 0o777 != 0o600:
        raise RuntimeError(f"secret input must be a mode 0600 regular file: {source}")
    return source


def read_secret(path: str) -> str:
    return check_secret_file(path).read_text(encoding="utf-8").strip()


def totp(seed_file: str) -> str:
    seed = base64.b32decode(read_secret(seed_file), casefold=True)
    remaining = 30 - (int(time.time()) % 30)
    if remaining < 4:
        time.sleep(remaining + 1)
    counter = int(time.time()) // 30
    digest = hmac.new(seed, struct.pack(">Q", counter), hashlib.sha256).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF
    return f"{value % 1_000_000:06d}"


def request(
    opener,
    url: str,
    *,
    method: str = "GET",
    body: dict | None = None,
    expected: tuple[int, ...] = (200,),
) -> tuple[int, bytes]:
    payload = None
    headers = {}
    if body is not None:
        payload = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=payload, headers=headers, method=method)
    try:
        with opener.open(req, timeout=30) as response:
            status, document = response.status, response.read()
    except urllib.error.HTTPError as error:
        status, document = error.code, error.read()
    if status not in expected:
        raise RuntimeError(f"unexpected HTTP status at {STAGE}: {status}")
    return status, document


def post_form(opener, url: str, values: dict[str, str]) -> tuple[str, bytes]:
    req = urllib.request.Request(
        url,
        data=urllib.parse.urlencode(values).encode("utf-8"),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with opener.open(req, timeout=30) as response:
        return response.geturl(), response.read()


def cookie_header(jar: http.cookiejar.CookieJar, hostname: str) -> str:
    values = []
    for cookie in jar:
        domain = cookie.domain.lstrip(".")
        if hostname == domain or hostname.endswith(f".{domain}"):
            values.append(f"{cookie.name}={cookie.value}")
    if not values:
        raise RuntimeError("Warpgate session cookie missing")
    return "; ".join(values)


def sso_login(args) -> tuple[urllib.request.OpenerDirector, http.cookiejar.CookieJar]:
    global STAGE
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(jar),
    )

    STAGE = "sso-start"
    _, document = request(
        opener,
        f"{args.warpgate_url}/@warpgate/api/sso/providers/{args.provider}/start",
    )
    auth_url = json.loads(document)["url"]
    auth_parts = urllib.parse.urlsplit(auth_url)
    if auth_parts.scheme != "https" or auth_parts.hostname != args.keycloak_host:
        raise RuntimeError("SSO authorization URL left the expected Keycloak host")

    STAGE = "keycloak-login-page"
    _, login_page = request(opener, auth_url)

    if args.expect_sso_failure == "idp-unavailable":
        raise RuntimeError("IdP unexpectedly served an enabled login form")

    STAGE = "keycloak-password"
    password = (
        "WG02-intentionally-invalid-credential"
        if args.expect_sso_failure == "bad-credential"
        else read_secret(args.password_file)
    )
    _, second_page = post_form(
        opener,
        form_action(login_page, "kc-form-login"),
        {"username": args.username, "password": password},
    )

    if args.expect_sso_failure == "bad-credential":
        form_action(second_page, "kc-form-login")
        print(f"SSO_BAD_CREDENTIAL_REJECTED username={args.username}")
        raise ExpectedFailure

    STAGE = "keycloak-totp"
    final_url, _ = post_form(
        opener,
        form_action(second_page, "kc-otp-login-form"),
        {"otp": totp(args.totp_file)},
    )
    if urllib.parse.urlsplit(final_url).hostname != args.warpgate_host:
        raise RuntimeError("SSO flow did not return to the Warpgate host")

    STAGE = "warpgate-session"
    _, info_document = request(opener, f"{args.warpgate_url}/@warpgate/api/info")
    info = json.loads(info_document)
    if info.get("username") != args.username:
        raise RuntimeError("Warpgate session username mismatch")
    if not info.get("web_ssh_enabled"):
        raise RuntimeError("Warpgate WebSSH is not enabled")
    print(f"SSO_LOGIN_OK username={args.username}")
    return opener, jar


class ExpectedFailure(Exception):
    pass


def expect_idp_failure(args) -> None:
    global STAGE
    try:
        sso_login(args)
    except ExpectedFailure:
        raise RuntimeError("wrong expected failure branch")
    except Exception:
        print(f"SSO_IDP_UNAVAILABLE_REJECTED stage={STAGE}")
        return
    raise RuntimeError("SSO unexpectedly succeeded while IdP failure was expected")


def local_admin_login(args) -> None:
    global STAGE
    jar = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(jar),
    )
    STAGE = "local-admin-login"
    status, _ = request(
        opener,
        f"{args.warpgate_url}/@warpgate/api/auth/login",
        method="POST",
        body={"username": "admin", "password": read_secret(args.local_admin_password_file)},
        expected=(201,),
    )
    print(f"LOCAL_ADMIN_LOGIN_OK status={status}")


class WebSocket:
    def __init__(self, url: str, cookie: str):
        parts = urllib.parse.urlsplit(url)
        if parts.scheme != "wss" or not parts.hostname:
            raise RuntimeError("WebSocket URL must be wss")
        port = parts.port or 443
        raw = socket.create_connection((parts.hostname, port), timeout=20)
        self.sock = ssl.create_default_context().wrap_socket(
            raw, server_hostname=parts.hostname
        )
        self.sock.settimeout(30)
        self.buffer = b""
        key = base64.b64encode(os.urandom(16)).decode("ascii")
        path = urllib.parse.urlunsplit(("", "", parts.path, parts.query, ""))
        host_header = parts.hostname if port == 443 else f"{parts.hostname}:{port}"
        handshake = (
            f"GET {path} HTTP/1.1\r\n"
            f"Host: {host_header}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            f"Origin: https://{host_header}\r\n"
            f"Cookie: {cookie}\r\n\r\n"
        ).encode("ascii")
        self.sock.sendall(handshake)
        response = self._read_until(b"\r\n\r\n")
        status_line = response.split(b"\r\n", 1)[0]
        if b" 101 " not in status_line:
            raise RuntimeError(f"WebSocket handshake failed: {status_line.decode('ascii', 'replace')}")
        expected_accept = base64.b64encode(
            hashlib.sha1(
                (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")
            ).digest()
        )
        headers = {}
        for line in response.split(b"\r\n")[1:]:
            if b":" in line:
                name, value = line.split(b":", 1)
                headers[name.strip().lower()] = value.strip()
        if headers.get(b"sec-websocket-accept") != expected_accept:
            raise RuntimeError("WebSocket accept key mismatch")

    def _read_until(self, marker: bytes) -> bytes:
        while marker not in self.buffer:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("WebSocket connection closed during handshake")
            self.buffer += chunk
        document, self.buffer = self.buffer.split(marker, 1)
        return document + marker

    def _read_exact(self, size: int) -> bytes:
        while len(self.buffer) < size:
            chunk = self.sock.recv(max(4096, size - len(self.buffer)))
            if not chunk:
                raise RuntimeError("WebSocket connection closed")
            self.buffer += chunk
        value, self.buffer = self.buffer[:size], self.buffer[size:]
        return value

    def send_frame(self, opcode: int, payload: bytes = b"") -> None:
        mask = os.urandom(4)
        length = len(payload)
        header = bytes([0x80 | opcode])
        if length < 126:
            header += bytes([0x80 | length])
        elif length < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", length)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", length)
        masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def send_json(self, value: dict) -> None:
        self.send_frame(0x1, json.dumps(value, separators=(",", ":")).encode("utf-8"))

    def receive_json(self) -> dict:
        while True:
            first, second = self._read_exact(2)
            opcode = first & 0x0F
            length = second & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read_exact(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read_exact(8))[0]
            masked = bool(second & 0x80)
            mask = self._read_exact(4) if masked else b""
            payload = self._read_exact(length)
            if masked:
                payload = bytes(
                    value ^ mask[index % 4] for index, value in enumerate(payload)
                )
            if opcode == 0x8:
                raise RuntimeError("WebSocket closed before validation completed")
            if opcode == 0x9:
                self.send_frame(0xA, payload)
                continue
            if opcode != 0x1:
                continue
            return json.loads(payload)

    def close(self) -> None:
        try:
            self.send_frame(0x8, struct.pack(">H", 1000))
        finally:
            self.sock.close()


def webssh_marker(
    args,
    opener,
    jar: http.cookiejar.CookieJar,
    target_id: str,
    target_name: str,
) -> None:
    global STAGE
    STAGE = f"webssh-create:{target_name}"
    status, document = request(
        opener,
        f"{args.warpgate_url}/@warpgate/api/web-ssh/sessions",
        method="POST",
        body={"target_id": target_id},
        expected=(201,),
    )
    session_id = json.loads(document)["session_id"]
    ws_url = (
        args.warpgate_url.replace("https://", "wss://", 1)
        + f"/@warpgate/api/web-ssh/sessions/{session_id}/stream"
    )
    ws = WebSocket(ws_url, cookie_header(jar, args.warpgate_host))
    output = bytearray()
    channel_id = None
    exit_code = None
    try:
        STAGE = f"webssh-connect:{target_name}"
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            message = ws.receive_json()
            if message.get("type") == "host_key_unknown":
                raise RuntimeError("unexpected SSH host key prompt")
            if message.get("type") == "error":
                raise RuntimeError("WebSSH connection error")
            if (
                message.get("type") == "connection_state"
                and message.get("state") == "Connected"
            ):
                break
        else:
            raise RuntimeError("WebSSH target connection timeout")

        ws.send_json({"type": "open_channel", "cols": 80, "rows": 24})
        STAGE = f"webssh-command:{target_name}"
        deadline = time.monotonic() + 30
        command_sent = False
        while time.monotonic() < deadline:
            message = ws.receive_json()
            kind = message.get("type")
            if kind == "channel_opened":
                channel_id = message["channel_id"]
                command = (
                    f"printf '%s\\n' {shlex.quote(args.marker)}; exit\n"
                ).encode("ascii")
                ws.send_json(
                    {
                        "type": "input",
                        "channel_id": channel_id,
                        "data": base64.b64encode(command).decode("ascii"),
                    }
                )
                command_sent = True
            elif kind == "output" and message.get("channel_id") == channel_id:
                output.extend(base64.b64decode(message["data"]))
            elif kind == "exit_status" and message.get("channel_id") == channel_id:
                exit_code = int(message["code"])
            elif kind == "error":
                raise RuntimeError("WebSSH command error")
            if command_sent and exit_code is not None and args.marker.encode("ascii") in output:
                break
        if exit_code != 0 or args.marker.encode("ascii") not in output:
            raise RuntimeError("WebSSH marker or zero exit status missing")
        print(
            f"WEBSSH_TARGET_OK username={args.username} target={target_name} "
            f"create_status={status} exit={exit_code} marker=present"
        )
    finally:
        ws.close()
        request(
            opener,
            f"{args.warpgate_url}/@warpgate/api/web-ssh/sessions/{session_id}",
            method="DELETE",
            expected=(204, 404),
        )


def verify_authorization(args, opener, jar) -> None:
    global STAGE
    STAGE = "target-list"
    _, document = request(opener, f"{args.warpgate_url}/@warpgate/api/targets")
    targets = {item["name"]: item["id"] for item in json.loads(document)}
    expected = set(args.expect_target)
    if set(targets) != expected:
        raise RuntimeError(
            f"authorized target set mismatch: expected={sorted(expected)}, actual={sorted(targets)}"
        )
    print(f"TARGET_SET_OK username={args.username} targets={','.join(sorted(targets))}")

    for target_id in args.deny_target_id:
        STAGE = "target-deny"
        status, _ = request(
            opener,
            f"{args.warpgate_url}/@warpgate/api/web-ssh/sessions",
            method="POST",
            body={"target_id": target_id},
            expected=(403,),
        )
        print(f"TARGET_DENY_OK username={args.username} status={status}")

    for target_name in args.open_target:
        if target_name not in targets:
            raise RuntimeError(f"open target is not authorized: {target_name}")
        webssh_marker(args, opener, jar, targets[target_name], target_name)


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--warpgate-url", default="https://warpgate.imcherry5778.xyz:8888"
    )
    parser.add_argument("--keycloak-host", default="sso.imcherry5778.xyz")
    parser.add_argument("--provider", default="keycloak")
    parser.add_argument("--username")
    parser.add_argument("--password-file")
    parser.add_argument("--totp-file")
    parser.add_argument(
        "--expect-sso-failure", choices=("bad-credential", "idp-unavailable")
    )
    parser.add_argument("--expect-target", action="append", default=[])
    parser.add_argument("--deny-target-id", action="append", default=[])
    parser.add_argument("--open-target", action="append", default=[])
    parser.add_argument("--marker", default="WG02_SESSION_MARKER")
    parser.add_argument("--local-admin-password-file")
    args = parser.parse_args()
    parsed = urllib.parse.urlsplit(args.warpgate_url)
    if parsed.scheme != "https" or not parsed.hostname:
        parser.error("--warpgate-url must be an HTTPS URL")
    args.warpgate_host = parsed.hostname
    if args.local_admin_password_file and not args.username:
        return args
    if not args.username:
        parser.error("--username is required for SSO verification")
    if not args.expect_sso_failure and not args.password_file:
        parser.error("--password-file is required")
    if not args.expect_sso_failure and not args.totp_file:
        parser.error("--totp-file is required for successful SSO")
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", args.marker):
        parser.error("--marker must be 1-64 ASCII alphanumeric, underscore, or hyphen")
    return args


def main() -> None:
    args = parse_args()
    if args.local_admin_password_file:
        local_admin_login(args)
        if not args.username:
            return
    if args.expect_sso_failure == "idp-unavailable":
        expect_idp_failure(args)
        return
    try:
        opener, jar = sso_login(args)
    except ExpectedFailure:
        return
    if args.expect_sso_failure:
        raise RuntimeError("SSO unexpectedly succeeded")
    verify_authorization(args, opener, jar)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(
            f"WG02_VERIFY_FAILED stage={STAGE} type={type(error).__name__}",
            file=sys.stderr,
        )
        raise SystemExit(1)
