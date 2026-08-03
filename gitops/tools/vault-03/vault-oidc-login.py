#!/usr/bin/env python3
"""VAULT-03: Vault UI가 실제로 하는 OIDC 왕복(auth_url -> Keycloak 로그인 -> callback)을
그대로 재현해 Vault client_token을 얻는다. Keycloak id_token을 그대로 재사용하지 않는다.
Vault 자신이 code를 교환하고 state를 검증해야 실제 auth method·policy 판정을 검증한 것이 된다."""

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
import ssl
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


CURRENT_STAGE = "initialization"

SAFE_RUNTIME_ERRORS = {
    "issuer must contain a hostname",
    "vault addr must be an HTTPS hostname URL",
    "connect-ip must be IPv4",
    "missing form: kc-form-login",
    "missing form: kc-otp-login-form",
    "TOTP rejected or replayed",
    "authorization callback missing",
    "authorization code missing",
    "authorization state missing",
    "vault auth_url response missing auth_url",
    "vault callback did not return a client_token",
}


def safe_error_detail(error: Exception) -> str:
    if isinstance(error, RuntimeError) and str(error) in SAFE_RUNTIME_ERRORS:
        return str(error)
    return "redacted"


class FixedAddressHTTPSConnection(http.client.HTTPSConnection):
    """Connect to one IP while preserving URL host, SNI, and certificate checks."""

    def __init__(self, host, *, fixed_ip: str, expected_host: str, **kwargs):
        self.fixed_ip = fixed_ip
        self.expected_host = expected_host
        super().__init__(host, **kwargs)

    def connect(self):
        if self.host != self.expected_host:
            raise OSError("fixed-address redirect left the expected host")
        self.sock = self._create_connection(
            (self.fixed_ip, self.port), self.timeout, self.source_address
        )
        if self._tunnel_host:
            self._tunnel()
        self.sock = self._context.wrap_socket(
            self.sock, server_hostname=self.expected_host
        )


class FixedAddressHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, fixed_ip: str, expected_host: str, context=None):
        super().__init__(context=context)
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


class CallbackRedirect(Exception):
    def __init__(self, url: str):
        super().__init__(url)
        self.url = url


class CaptureCallbackRedirectHandler(urllib.request.HTTPRedirectHandler):
    """OIDC callback으로 실제 접속하지 않고 authorization redirect를 보존한다."""

    def __init__(self, expected_url: str):
        super().__init__()
        self.expected_url = expected_url

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if url_matches_callback(newurl, self.expected_url):
            raise CallbackRedirect(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


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


def url_matches_callback(actual_url: str, expected_url: str) -> bool:
    actual = urllib.parse.urlsplit(actual_url)
    expected = urllib.parse.urlsplit(expected_url)
    return (
        actual.scheme == expected.scheme
        and actual.netloc == expected.netloc
        and actual.path == expected.path
    )


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


def write_header(path: str, value: str):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(f"X-Vault-Token: {value}\n")


def build_vault_opener(vault_host: str, vault_cacert: str | None, connect_ip: str | None):
    # vault_addr는 항상 Traefik 표준 Ingress의 production 인증서를 쓴다(VAULT-03). Vault
    # listener의 자체서명 인증서는 Traefik->Vault backend 홉에서만 쓰이며 이 클라이언트는
    # 보지 않으므로 system CA로 검증한다. vault_cacert는 Ingress를 건너뛰는 직접 접속
    # 디버깅에서만 쓴다.
    context = ssl.create_default_context(cafile=vault_cacert) if vault_cacert else ssl.create_default_context()
    if connect_ip:
        handler = FixedAddressHTTPSHandler(connect_ip, vault_host, context=context)
    else:
        handler = urllib.request.HTTPSHandler(context=context)
    return urllib.request.build_opener(urllib.request.ProxyHandler({}), handler)


def main():
    global CURRENT_STAGE
    parser = argparse.ArgumentParser()
    parser.add_argument("--vault-addr", required=True, help="예: https://vault.imcherry5778.xyz")
    parser.add_argument(
        "--vault-cacert",
        help="Ingress를 건너뛰고 vault 자체서명 인증서로 직접 접속할 때만 지정한다(기본은 system CA)",
    )
    parser.add_argument("--role", required=True)
    parser.add_argument("--redirect-uri", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--totp-file", required=True)
    parser.add_argument("--header-file", required=True, help="X-Vault-Token 헤더를 mode 0600으로 쓴다")
    parser.add_argument("--connect-ip", help="vault·keycloak hostname을 이 IPv4로 고정한다")
    args = parser.parse_args()

    vault_url = urllib.parse.urlsplit(args.vault_addr)
    if vault_url.scheme != "https" or not vault_url.hostname:
        raise RuntimeError("vault addr must be an HTTPS hostname URL")
    if args.connect_ip:
        address = ipaddress.ip_address(args.connect_ip)
        if address.version != 4:
            raise RuntimeError("connect-ip must be IPv4")

    with open(args.password_file, encoding="utf-8") as stream:
        password = stream.read().strip()

    vault_opener = build_vault_opener(vault_url.hostname, args.vault_cacert, args.connect_ip)

    CURRENT_STAGE = "vault-auth-url"
    auth_url_request = urllib.request.Request(
        f"{args.vault_addr}/v1/auth/oidc/oidc/auth_url",
        data=json.dumps({"role": args.role, "redirect_uri": args.redirect_uri}).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with vault_opener.open(auth_url_request, timeout=20) as response:
        auth_url_body = json.load(response)
    auth_url = auth_url_body.get("data", {}).get("auth_url")
    if not auth_url:
        raise RuntimeError("vault auth_url response missing auth_url")

    keycloak_host = urllib.parse.urlsplit(auth_url).hostname

    cookie_jar = http.cookiejar.CookieJar()
    handlers = [
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(cookie_jar),
        CaptureCallbackRedirectHandler(args.redirect_uri),
    ]
    if args.connect_ip:
        handlers.append(FixedAddressHTTPSHandler(args.connect_ip, keycloak_host, context=ssl.create_default_context()))
    keycloak_opener = urllib.request.build_opener(*handlers)

    CURRENT_STAGE = "authorization-page"
    with keycloak_opener.open(auth_url, timeout=20) as response:
        login_page = response.read()

    CURRENT_STAGE = "password-form"
    with post_form(
        keycloak_opener,
        form_action(login_page, "kc-form-login"),
        {"username": args.username, "password": password},
    ) as response:
        otp_page = response.read()

    CURRENT_STAGE = "totp-form"
    try:
        with post_form(
            keycloak_opener,
            form_action(otp_page, "kc-otp-login-form"),
            {"otp": totp(args.totp_file)},
        ) as response:
            final_url = response.geturl()
            final_document = response.read()
    except CallbackRedirect as redirect:
        final_url = redirect.url
        final_document = b""

    if not url_matches_callback(final_url, args.redirect_uri):
        try:
            form_action(final_document, "kc-otp-login-form")
        except RuntimeError:
            raise RuntimeError("authorization callback missing") from None
        raise RuntimeError("TOTP rejected or replayed")

    final_query = urllib.parse.parse_qs(urllib.parse.urlsplit(final_url).query)
    code = final_query.get("code", [None])[0]
    state = final_query.get("state", [None])[0]
    if not state:
        raise RuntimeError("authorization state missing")
    if not code:
        raise RuntimeError("authorization code missing")

    CURRENT_STAGE = "vault-callback"
    callback_query = urllib.parse.urlencode({"state": state, "code": code})
    callback_request = urllib.request.Request(
        f"{args.vault_addr}/v1/auth/oidc/oidc/callback?{callback_query}",
        method="GET",
    )
    with vault_opener.open(callback_request, timeout=20) as response:
        callback_body = json.load(response)
    auth_data = callback_body.get("auth") or {}
    client_token = auth_data.get("client_token")
    if not client_token:
        raise RuntimeError("vault callback did not return a client_token")

    CURRENT_STAGE = "write-header"
    write_header(args.header_file, client_token)
    print(
        f"vault-oidc-login: role={args.role}, "
        f"policies={sorted(auth_data.get('policies', []))}, "
        f"entity_id={'set' if auth_data.get('entity_id') else 'missing'}"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        status = getattr(error, "code", "n/a")
        print(
            f"vault-oidc-login failed: stage={CURRENT_STAGE}, "
            f"type={type(error).__name__}, status={status}, "
            f"detail={safe_error_detail(error)}",
            file=sys.stderr,
        )
        raise SystemExit(1)
