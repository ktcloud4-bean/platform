#!/usr/bin/env python3
"""Pomerium 브라우저 로그인, Route allow·deny와 세션 종료를 검증한다."""

import argparse
import base64
import hashlib
import hmac
from html.parser import HTMLParser
import http.client
import http.cookiejar
import ipaddress
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


ACCESS_URL = "https://access.imcherry5778.xyz"
AUTH_URL = "https://k3s-01.imcherry5778.xyz"
ISSUER_URL = "https://sso.imcherry5778.xyz"
PROTECTED_URL = f"{ACCESS_URL}/pom01-platform-user-check"
EXPECTED_HOSTS = {
    "access.imcherry5778.xyz",
    "k3s-01.imcherry5778.xyz",
    "sso.imcherry5778.xyz",
}
MARKER = b"POM-01 protected route\n"
CURRENT_STAGE = "initialization"


class FixedAddressHTTPSConnection(http.client.HTTPSConnection):
    """URL hostname의 TLS 검증을 유지하면서 연결 IP만 고정한다."""

    def __init__(self, host, *, fixed_ip: str, allowed_hosts: set[str], **kwargs):
        self.fixed_ip = fixed_ip
        self.allowed_hosts = allowed_hosts
        super().__init__(host, **kwargs)

    def connect(self):
        if self.host not in self.allowed_hosts:
            raise OSError("redirect left the approved POM-01 host set")
        self.sock = self._create_connection(
            (self.fixed_ip, self.port), self.timeout, self.source_address
        )
        if self._tunnel_host:
            self._tunnel()
        self.sock = self._context.wrap_socket(self.sock, server_hostname=self.host)


class FixedAddressHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, fixed_ip: str, allowed_hosts: set[str]):
        super().__init__()
        self.fixed_ip = fixed_ip
        self.allowed_hosts = allowed_hosts

    def https_open(self, request):
        def connection(host, **kwargs):
            return FixedAddressHTTPSConnection(
                host,
                fixed_ip=self.fixed_ip,
                allowed_hosts=self.allowed_hosts,
                **kwargs,
            )

        return self.do_open(connection, request, context=self._context)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


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
    parser.feed(document.decode("utf-8", errors="strict"))
    if not parser.action:
        raise RuntimeError(f"missing form: {form_id}")
    return parser.action


def post_form(opener, url: str, values: dict[str, str]):
    request = urllib.request.Request(
        url,
        data=urllib.parse.urlencode(values).encode("utf-8"),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    return opener.open(request, timeout=30)


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


def build_opener(cookie_jar, fixed_ip: str, *, no_redirect: bool = False):
    handlers = [
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(cookie_jar),
        FixedAddressHTTPSHandler(fixed_ip, EXPECTED_HOSTS),
    ]
    if no_redirect:
        handlers.append(NoRedirect())
    return urllib.request.build_opener(*handlers)


def login(opener, start_url: str, username: str, password_file: str, totp_file: str):
    global CURRENT_STAGE
    CURRENT_STAGE = "pomerium-redirect"
    with opener.open(start_url, timeout=30) as response:
        login_page = response.read()
        final_url = response.geturl()
    if urllib.parse.urlsplit(final_url).hostname != "sso.imcherry5778.xyz":
        raise RuntimeError("Pomerium did not redirect to the fixed Keycloak issuer")

    with open(password_file, encoding="utf-8") as stream:
        password = stream.read().strip()

    CURRENT_STAGE = "keycloak-password"
    with post_form(
        opener,
        form_action(login_page, "kc-form-login"),
        {"username": username, "password": password},
    ) as response:
        otp_page = response.read()

    CURRENT_STAGE = "keycloak-totp"
    try:
        with post_form(
            opener,
            form_action(otp_page, "kc-otp-login-form"),
            {"otp": totp(totp_file)},
        ) as response:
            body = response.read()
            status = response.status
            final_url = response.geturl()
    except urllib.error.HTTPError as error:
        # 인증 성공 뒤 Pomerium policy가 명시적으로 거부한 403도 기대 결과다.
        if error.code != 403:
            raise
        body = error.read()
        status = error.code
        final_url = error.geturl()
    return status, final_url, body


def get_response(opener, url: str):
    try:
        with opener.open(url, timeout=30) as response:
            return response.status, response.geturl(), response.headers, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.geturl(), error.headers, error.read()


def verify_reauthentication_redirect(cookie_jar, fixed_ip: str, reason: str):
    opener = build_opener(cookie_jar, fixed_ip, no_redirect=True)
    status, _, headers, _ = get_response(opener, PROTECTED_URL)
    location = headers.get("Location", "")
    parsed = urllib.parse.urlsplit(location)
    if status not in {302, 303}:
        raise RuntimeError(f"{reason}: expected authentication redirect, got {status}")
    if parsed.hostname not in {
        "access.imcherry5778.xyz",
        "k3s-01.imcherry5778.xyz",
    }:
        raise RuntimeError(f"{reason}: redirect left Pomerium endpoints")
    if ".pomerium" not in parsed.path:
        raise RuntimeError(f"{reason}: redirect is not a Pomerium authentication path")


def logout(opener, cookie_jar, fixed_ip: str):
    global CURRENT_STAGE
    CURRENT_STAGE = "logout-csrf"
    status, _, headers, _ = get_response(
        opener, f"{ACCESS_URL}/.well-known/pomerium"
    )
    if status != 200:
        raise RuntimeError(f"well-known status={status}")
    csrf = headers.get("X-CSRF-Token")
    if not csrf:
        csrf = next(
            (
                cookie.value
                for cookie in cookie_jar
                if cookie.name == "_pomerium_csrf"
            ),
            None,
        )
    if not csrf:
        raise RuntimeError("Pomerium CSRF header is missing")

    CURRENT_STAGE = "logout"
    request = urllib.request.Request(
        f"{ACCESS_URL}/.pomerium/sign_out",
        headers={"X-CSRF-Token": csrf},
    )
    try:
        with opener.open(request, timeout=30) as response:
            response.read()
    except urllib.error.HTTPError as error:
        if error.code not in {302, 303}:
            raise
        error.read()
    verify_reauthentication_redirect(cookie_jar, fixed_ip, "logout")


def wait_for_cookie_expiry(cookie_jar, fixed_ip: str, maximum_wait: int):
    route_expiries = [
        cookie.expires
        for cookie in cookie_jar
        if cookie.name == "_pomerium"
        and cookie.domain.lstrip(".") == "access.imcherry5778.xyz"
        and cookie.expires is not None
    ]
    if not route_expiries:
        raise RuntimeError("expiring access route cookie is missing")
    wait_seconds = max(route_expiries) - int(time.time()) + 2
    if wait_seconds < 1:
        wait_seconds = 1
    if wait_seconds > maximum_wait:
        raise RuntimeError(
            f"route cookie wait {wait_seconds}s exceeds limit {maximum_wait}s"
        )
    while wait_seconds > 0:
        interval = min(30, wait_seconds)
        print(f"session-expiry: remaining<={wait_seconds}s", flush=True)
        time.sleep(interval)
        wait_seconds -= interval
    verify_reauthentication_redirect(cookie_jar, fixed_ip, "session-expiry")


def main():
    global CURRENT_STAGE
    parser = argparse.ArgumentParser()
    parser.add_argument("--connect-ip", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--totp-file", required=True)
    parser.add_argument("--expect", choices=("allow", "deny"), required=True)
    parser.add_argument("--check-logout", action="store_true")
    parser.add_argument("--check-expiry", action="store_true")
    parser.add_argument("--maximum-expiry-wait", type=int, default=360)
    args = parser.parse_args()

    address = ipaddress.ip_address(args.connect_ip)
    if address.version != 4:
        raise RuntimeError("connect-ip must be IPv4")

    cookie_jar = http.cookiejar.CookieJar()
    opener = build_opener(cookie_jar, args.connect_ip)
    status, final_url, body = login(
        opener,
        PROTECTED_URL,
        args.username,
        args.password_file,
        args.totp_file,
    )

    CURRENT_STAGE = "authorization"
    if args.expect == "allow":
        if status != 200 or final_url != PROTECTED_URL or body != MARKER:
            raise RuntimeError("allowed route did not return the exact 200 marker")
    else:
        if status != 403 or final_url != PROTECTED_URL:
            raise RuntimeError(f"unauthorized route status={status}, expected 403")

    portal_status, portal_url, _, portal_body = get_response(opener, f"{ACCESS_URL}/")
    if portal_status != 200 or portal_url != f"{ACCESS_URL}/":
        raise RuntimeError(f"Dashy portal shell status={portal_status}")
    if b'id="app"' not in portal_body:
        raise RuntimeError("Dashy portal shell marker is missing")

    if args.check_logout:
        logout(opener, cookie_jar, args.connect_ip)
    if args.check_expiry:
        wait_for_cookie_expiry(
            cookie_jar, args.connect_ip, args.maximum_expiry_wait
        )

    CURRENT_STAGE = "complete"
    print(
        f"browser-session: username={args.username}, expect={args.expect}, "
        "portal-shell=true, "
        f"logout={args.check_logout}, expiry={args.check_expiry}"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        status = getattr(error, "code", "n/a")
        print(
            f"browser-session failed: stage={CURRENT_STAGE}, "
            f"type={type(error).__name__}, status={status}",
            file=sys.stderr,
        )
        raise SystemExit(1)
