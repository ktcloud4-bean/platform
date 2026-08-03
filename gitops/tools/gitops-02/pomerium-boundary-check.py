#!/usr/bin/env python3
"""GITOPS-02: Pomerium claim/groups route 진입과 Argo CD 자체 인증 경계를 검증한다.

같은 브라우저 세션에서 두 가지를 순서대로 확인한다.
1. Pomerium이 claim/groups 정책대로 argo route 진입을 allow/deny 한다.
2. allow된 세션이라도 Pomerium cookie만으로는 Argo CD REST API가 인증되지 않는다
   (Argo CD 자신이 401을 반환한다). Pomerium은 자기 세션을 Argo Bearer 자격증명으로
   전달하지 않는다.
"""

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


ARGO_URL = "https://argo.imcherry5778.xyz"
EXPECTED_HOSTS = {
    "argo.imcherry5778.xyz",
    "k3s-01.imcherry5778.xyz",
    "sso.imcherry5778.xyz",
}
UI_MARKER = b"<title>Argo CD</title>"
CURRENT_STAGE = "initialization"


class FixedAddressHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, host, *, fixed_ip: str, allowed_hosts: set[str], **kwargs):
        self.fixed_ip = fixed_ip
        self.allowed_hosts = allowed_hosts
        super().__init__(host, **kwargs)

    def connect(self):
        if self.host not in self.allowed_hosts:
            raise OSError("redirect left the approved GITOPS-02 host set")
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


def build_opener(cookie_jar, fixed_ip: str):
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        urllib.request.HTTPCookieProcessor(cookie_jar),
        FixedAddressHTTPSHandler(fixed_ip, EXPECTED_HOSTS),
    )


def login(opener, username: str, password_file: str, totp_file: str):
    global CURRENT_STAGE
    CURRENT_STAGE = "pomerium-redirect"
    with opener.open(f"{ARGO_URL}/", timeout=30) as response:
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
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def main():
    global CURRENT_STAGE
    parser = argparse.ArgumentParser()
    parser.add_argument("--connect-ip", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--totp-file", required=True)
    parser.add_argument("--expect", choices=("allow", "deny"), required=True)
    args = parser.parse_args()

    address = ipaddress.ip_address(args.connect_ip)
    if address.version != 4:
        raise RuntimeError("connect-ip must be IPv4")

    cookie_jar = http.cookiejar.CookieJar()
    opener = build_opener(cookie_jar, args.connect_ip)
    status, final_url, body = login(
        opener, args.username, args.password_file, args.totp_file
    )

    CURRENT_STAGE = "pomerium-authorization"
    if args.expect == "allow":
        if status != 200 or final_url != f"{ARGO_URL}/" or UI_MARKER not in body:
            raise RuntimeError("allowed route did not return the Argo CD UI shell")
    else:
        if status != 403 or final_url != f"{ARGO_URL}/":
            raise RuntimeError(f"unauthorized route status={status}, expected 403")
        print(
            f"pomerium-boundary-check: username={args.username}, "
            f"expect={args.expect}, pomerium={status}"
        )
        return

    CURRENT_STAGE = "argo-api-without-bearer"
    api_status, api_body = get_response(opener, f"{ARGO_URL}/api/v1/applications")
    if api_status != 401:
        raise RuntimeError(
            f"Argo API accepted a Pomerium-only session: status={api_status}, "
            f"body_len={len(api_body)}"
        )

    CURRENT_STAGE = "complete"
    print(
        f"pomerium-boundary-check: username={args.username}, expect={args.expect}, "
        f"pomerium={status}, argo-api-without-bearer={api_status}"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        status = getattr(error, "code", "n/a")
        print(
            f"pomerium-boundary-check failed: stage={CURRENT_STAGE}, "
            f"type={type(error).__name__}, status={status}",
            file=sys.stderr,
        )
        raise SystemExit(1)
