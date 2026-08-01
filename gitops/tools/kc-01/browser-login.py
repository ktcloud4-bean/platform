#!/usr/bin/env python3
"""Keycloak Authorization Code + PKCE + TOTP 로그인 후 Bearer header를 파일로 쓴다."""

import argparse
import base64
import hashlib
import hmac
from html.parser import HTMLParser
import http.client
import http.cookiejar
import ipaddress
import json
import os
import secrets
import struct
import sys
import time
import urllib.parse
import urllib.request


CURRENT_STAGE = "initialization"


class FixedAddressHTTPSConnection(http.client.HTTPSConnection):
    """Connect to one IP while preserving URL host, SNI, and certificate checks."""

    def __init__(self, host, *, fixed_ip: str, expected_host: str, **kwargs):
        self.fixed_ip = fixed_ip
        self.expected_host = expected_host
        super().__init__(host, **kwargs)

    def connect(self):
        if self.host != self.expected_host:
            raise OSError("fixed-address redirect left the expected issuer host")
        self.sock = self._create_connection(
            (self.fixed_ip, self.port), self.timeout, self.source_address
        )
        if self._tunnel_host:
            self._tunnel()
        self.sock = self._context.wrap_socket(
            self.sock, server_hostname=self.expected_host
        )


class FixedAddressHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, fixed_ip: str, expected_host: str):
        super().__init__()
        self.fixed_ip = fixed_ip
        self.expected_host = expected_host

    def https_open(self, request):
        def connection(host, **kwargs):
            return FixedAddressHTTPSConnection(
                host,
                fixed_ip=self.fixed_ip,
                expected_host=self.expected_host,
                **kwargs,
            )

        return self.do_open(connection, request, context=self._context)


class LoginFormParser(HTMLParser):
    def __init__(self, form_id: str):
        super().__init__()
        self.form_id = form_id
        self.action = None

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


def post_form(opener, url: str, values: dict[str, str]):
    request = urllib.request.Request(
        url,
        data=urllib.parse.urlencode(values).encode("utf-8"),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    return opener.open(request, timeout=20)


def totp(seed_file: str) -> str:
    with open(seed_file, encoding="utf-8") as stream:
        seed = base64.b32decode(stream.read().strip(), casefold=True)
    remaining = 30 - (int(time.time()) % 30)
    if remaining < 4:
        time.sleep(remaining + 1)
    counter = int(time.time()) // 30
    digest = hmac.new(seed, struct.pack(">Q", counter), hashlib.sha256).digest()
    offset = digest[-1] & 0x0F
    value = struct.unpack(">I", digest[offset : offset + 4])[0] & 0x7FFFFFFF
    return f"{value % 1_000_000:06d}"


def decode_claims(token: str) -> dict:
    payload = token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    return json.loads(base64.urlsafe_b64decode(payload))


def write_header(path: str, token: str):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(f"Authorization: Bearer {token}\n")


def main():
    global CURRENT_STAGE
    parser = argparse.ArgumentParser()
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--realm", required=True)
    parser.add_argument("--client-id", required=True)
    parser.add_argument("--redirect-uri", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--totp-file", required=True)
    parser.add_argument("--header-file", required=True)
    parser.add_argument("--expect-realm-role", action="append", default=[])
    parser.add_argument("--connect-ip")
    parser.add_argument("--allow-insecure-localhost", action="store_true")
    args = parser.parse_args()

    issuer_url = urllib.parse.urlsplit(args.issuer)
    if not issuer_url.hostname:
        raise RuntimeError("issuer must contain a hostname")
    if issuer_url.scheme != "https":
        if not (
            args.allow_insecure_localhost
            and issuer_url.scheme == "http"
            and issuer_url.hostname in {"127.0.0.1", "localhost"}
        ):
            raise RuntimeError("issuer must be an HTTPS hostname URL")
    if args.connect_ip:
        if issuer_url.scheme != "https":
            raise RuntimeError("connect-ip requires an HTTPS issuer")
        address = ipaddress.ip_address(args.connect_ip)
        if address.version != 4:
            raise RuntimeError("connect-ip must be IPv4")

    with open(args.password_file, encoding="utf-8") as stream:
        password = stream.read().strip()

    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode("ascii")).digest()
    ).rstrip(b"=").decode("ascii")
    state = secrets.token_urlsafe(24)
    nonce = secrets.token_urlsafe(24)
    query = urllib.parse.urlencode(
        {
            "client_id": args.client_id,
            "redirect_uri": args.redirect_uri,
            "response_type": "code",
            "scope": "openid",
            "state": state,
            "nonce": nonce,
            "code_challenge_method": "S256",
            "code_challenge": challenge,
        }
    )
    cookie_jar = http.cookiejar.CookieJar()
    handlers = [
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(cookie_jar),
    ]
    if args.connect_ip:
        handlers.append(
            FixedAddressHTTPSHandler(args.connect_ip, issuer_url.hostname)
        )
    opener = urllib.request.build_opener(*handlers)
    CURRENT_STAGE = "authorization-page"
    with opener.open(
        f"{args.issuer}/realms/{args.realm}/protocol/openid-connect/auth?{query}",
        timeout=20,
    ) as response:
        login_page = response.read()
    if args.allow_insecure_localhost:
        host = urllib.parse.urlsplit(args.issuer).hostname
        if host not in {"127.0.0.1", "localhost"}:
            raise RuntimeError("insecure cookie override is localhost-only")
        for cookie in cookie_jar:
            cookie.secure = False

    CURRENT_STAGE = "password-form"
    with post_form(
        opener,
        form_action(login_page, "kc-form-login"),
        {"username": args.username, "password": password},
    ) as response:
        otp_page = response.read()

    CURRENT_STAGE = "totp-form"
    with post_form(
        opener,
        form_action(otp_page, "kc-otp-login-form"),
        {"otp": totp(args.totp_file)},
    ) as response:
        final_url = response.geturl()
        response.read()

    final_query = urllib.parse.parse_qs(urllib.parse.urlsplit(final_url).query)
    if final_query.get("state", [None])[0] != state:
        raise RuntimeError("authorization state mismatch")
    code = final_query.get("code", [None])[0]
    if not code:
        raise RuntimeError("authorization code missing")

    CURRENT_STAGE = "code-exchange"
    with post_form(
        opener,
        f"{args.issuer}/realms/{args.realm}/protocol/openid-connect/token",
        {
            "grant_type": "authorization_code",
            "client_id": args.client_id,
            "redirect_uri": args.redirect_uri,
            "code": code,
            "code_verifier": verifier,
        },
    ) as response:
        token = json.loads(response.read())["access_token"]

    claims = decode_claims(token)
    expected_issuer = f"{args.issuer}/realms/{args.realm}"
    if claims.get("iss") != expected_issuer:
        raise RuntimeError("issuer mismatch")
    realm_roles = set(claims.get("realm_access", {}).get("roles", []))
    if not set(args.expect_realm_role) <= realm_roles:
        raise RuntimeError("expected realm role missing")
    CURRENT_STAGE = "claim-check"
    write_header(args.header_file, token)
    print(
        f"browser-login: issuer={expected_issuer}, "
        f"expected-realm-roles={sorted(args.expect_realm_role)}"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        status = getattr(error, "code", "n/a")
        print(
            f"browser-login failed: stage={CURRENT_STAGE}, "
            f"type={type(error).__name__}, status={status}",
            file=sys.stderr,
        )
        raise SystemExit(1)
