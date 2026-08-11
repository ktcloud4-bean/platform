#!/usr/bin/env python3
"""AWS-ID-01 SAML browser login을 수행하되 assertion 원문은 mode 0600 file 밖으로 내보내지 않는다."""

import argparse
import base64
import hashlib
import hmac
import http.client
from html.parser import HTMLParser
import http.cookiejar
import ipaddress
import json
import os
import struct
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


ISSUER = "https://sso.imcherry5778.xyz"
REALM = "platform"
SAML_ENDPOINT = f"{ISSUER}/realms/{REALM}/protocol/saml/clients/aws-console"
AWS_ROLE_ATTRIBUTE = "https://aws.amazon.com/SAML/Attributes/Role"


class FormParser(HTMLParser):
    def __init__(self, form_id=None):
        super().__init__()
        self.form_id = form_id
        self.in_form = False
        self.action = None
        self.values = {}
        self.form_ids = []
        self.input_names = []

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "form":
            if values.get("id"):
                self.form_ids.append(values["id"])
            if self.form_id is None or values.get("id") == self.form_id:
                self.in_form = True
                self.action = values.get("action")
        elif tag == "input" and self.in_form and values.get("name"):
            self.input_names.append(values["name"])
            self.values[values["name"]] = values.get("value", "")

    def handle_endtag(self, tag):
        if tag == "form" and self.in_form:
            self.in_form = False


def parse_form(document, form_id=None):
    parser = FormParser(form_id)
    parser.feed(document.decode("utf-8"))
    if not parser.action:
        summary = FormParser()
        summary.feed(document.decode("utf-8"))
        raise RuntimeError(
            f"required form missing: {form_id or 'SAML response'} "
            f"(form_ids={sorted(set(summary.form_ids))}, "
            f"input_names={sorted(set(summary.input_names))})"
        )
    return parser.action, parser.values


class FixedAddressHTTPSConnection(http.client.HTTPSConnection):
    """Connect to one internal IP while retaining the public URL host, SNI, and TLS checks."""

    def __init__(self, host, *, fixed_ip, expected_host, **kwargs):
        self.fixed_ip = fixed_ip
        self.expected_host = expected_host
        super().__init__(host, **kwargs)

    def connect(self):
        if self.host != self.expected_host:
            raise OSError("fixed-address redirect left the expected issuer host")
        self.sock = self._create_connection((self.fixed_ip, self.port), self.timeout, self.source_address)
        if self._tunnel_host:
            self._tunnel()
        self.sock = self._context.wrap_socket(self.sock, server_hostname=self.expected_host)


class FixedAddressHTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, fixed_ip, expected_host):
        super().__init__()
        self.fixed_ip = fixed_ip
        self.expected_host = expected_host

    def https_open(self, request):
        def connection(host, **kwargs):
            return FixedAddressHTTPSConnection(
                host, fixed_ip=self.fixed_ip, expected_host=self.expected_host, **kwargs
            )

        return self.do_open(connection, request, context=self._context)


def totp(seed_file):
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


def post(opener, url, values):
    request = urllib.request.Request(
        url,
        data=urllib.parse.urlencode(values).encode("utf-8"),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    return opener.open(request, timeout=25)


def assertion_attributes(assertion):
    document = base64.b64decode(assertion, validate=True)
    root = ET.fromstring(document)
    namespace = {"saml": "urn:oasis:names:tc:SAML:2.0:assertion"}
    attributes = {}
    for attribute in root.findall(".//saml:Attribute", namespace):
        name = attribute.attrib.get("Name", "")
        attributes[name] = [
            value.text for value in attribute.findall("saml:AttributeValue", namespace) if value.text
        ]
    return attributes


def secure_write(path, content):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(content)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", required=True)
    parser.add_argument("--totp-file", required=True)
    parser.add_argument("--assertion-file", required=True)
    parser.add_argument("--connect-ip")
    parser.add_argument("--expected-role-pair-file")
    parser.add_argument("--expect-no-role", action="store_true")
    parser.add_argument("--post-to-aws", action="store_true")
    args = parser.parse_args()
    if bool(args.expected_role_pair_file) == args.expect_no_role:
        raise RuntimeError("expected role pair 또는 expect-no-role 중 정확히 하나가 필요합니다")

    with open(args.password_file, encoding="utf-8") as stream:
        password = stream.read().strip()
    if args.connect_ip:
        ipaddress.ip_address(args.connect_ip)
    cookies = http.cookiejar.CookieJar()
    handlers = [urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(cookies)]
    if args.connect_ip:
        handlers.insert(1, FixedAddressHTTPSHandler(args.connect_ip, "sso.imcherry5778.xyz"))
    opener = urllib.request.build_opener(*handlers)
    with opener.open(SAML_ENDPOINT, timeout=25) as response:
        login_page = response.read()
    action, login_values = parse_form(login_page, "kc-form-login")
    login_values.update({"username": args.username, "password": password})
    with post(opener, action, login_values) as response:
        otp_page = response.read()
    action, otp_values = parse_form(otp_page, "kc-otp-login-form")
    otp_values["otp"] = totp(args.totp_file)
    with post(opener, action, otp_values) as response:
        saml_page = response.read()

    action, fields = parse_form(saml_page)
    assertion = fields.get("SAMLResponse")
    if not assertion:
        action_host = urllib.parse.urlsplit(action).hostname or ""
        raise RuntimeError(
            f"SAMLResponse가 없다 (form host={action_host}, input names={sorted(fields)})"
        )
    attributes = assertion_attributes(assertion)
    pairs = attributes.get(AWS_ROLE_ATTRIBUTE, [])
    if args.expected_role_pair_file:
        with open(args.expected_role_pair_file, encoding="utf-8") as stream:
            expected = stream.read().strip()
        if pairs != [expected]:
            aws_pair_count = sum(
                value.startswith("arn:aws:iam::") and ",arn:aws:iam::" in value
                for value in pairs
            )
            raise RuntimeError(
                "SAML Role attribute가 기대한 단일 group role과 다르다 "
                f"(attribute_count={len(pairs)}, aws_pair_count={aws_pair_count}, "
                f"attribute_names={sorted(attributes)})"
            )
        result = {"role_attribute_count": len(pairs), "expected_role_present": True}
    else:
        if pairs:
            raise RuntimeError("그룹 없는 ID의 SAML assertion에 AWS Role이 있다")
        result = {"role_attribute_count": 0, "expected_role_present": False}

    secure_write(args.assertion_file, assertion)
    result["assertion_sha256"] = hashlib.sha256(assertion.encode("ascii")).hexdigest()
    if args.post_to_aws:
        with post(opener, action, fields) as response:
            final_url = response.geturl()
            response.read()
            parsed = urllib.parse.urlsplit(final_url)
            is_aws_console = parsed.hostname and (
                parsed.hostname.endswith(".amazonaws.com")
                or parsed.hostname == "console.aws.amazon.com"
                or parsed.hostname.endswith(".console.aws.amazon.com")
            )
            if not is_aws_console:
                raise RuntimeError(
                    f"AWS console sign-in redirect가 아니다 (final host={parsed.hostname or 'absent'})"
                )
            result["aws_console_http_status"] = response.status
            result["aws_console_host"] = parsed.hostname
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"saml-browser-login failed: {type(error).__name__}: {error}", file=sys.stderr)
        raise SystemExit(1)
