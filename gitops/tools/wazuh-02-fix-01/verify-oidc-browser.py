#!/usr/bin/env python3
"""WAZUH-02-FIX-01 browser proof: Pomerium entry plus native Wazuh OIDC session.

No Wazuh internal password is read. The same browser session first completes
Pomerium entry, then the Dashboard's native Keycloak OIDC redirect, and finally
queries two already-stored records.
"""

from __future__ import annotations

import argparse
import http.cookiejar
import importlib.util
import json
from html.parser import HTMLParser
from pathlib import Path
import sys
import urllib.error
import urllib.parse
import urllib.request


WAZUH_URL = "https://wazuh.imcherry5778.xyz"
START_URL = f"{WAZUH_URL}/app/wz-home"
D30_INDEX_PATTERN = "wazuh-alerts-4.x-*"
A90_INDEX_PATTERN = "wazuh-alerts-4.x-audit-*"
REPRESENTATIVE_SID = "2029054"
CURRENT_STAGE = "initialization"


class FormIdParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.form_ids: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "form":
            return
        form_id = dict(attrs).get("id")
        if form_id:
            self.form_ids.append(form_id)


def require_secret_file(path: Path) -> None:
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_mode & 0o077:
        raise RuntimeError(f"secret input is not a mode 0600 regular file: {path.name}")


def load_pomerium_browser(repo_root: Path):
    module_path = repo_root / "gitops/tools/pom-01/browser-session.py"
    spec = importlib.util.spec_from_file_location("wazuh02fix01_pomerium_browser", module_path)
    if not spec or not spec.loader:
        raise RuntimeError("POM-01 browser verifier를 불러올 수 없다")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.EXPECTED_HOSTS = set(module.EXPECTED_HOSTS) | {"wazuh.imcherry5778.xyz"}
    original_form_action = module.form_action

    def form_action_with_safe_diagnostic(document: bytes, form_id: str) -> str:
        try:
            return original_form_action(document, form_id)
        except RuntimeError as error:
            parser = FormIdParser()
            parser.feed(document.decode("utf-8", errors="replace"))
            found = ",".join(sorted(set(parser.form_ids))) or "none"
            raise RuntimeError(f"{error}; form-ids={found}") from error

    module.form_action = form_action_with_safe_diagnostic
    return module


def request(opener, url: str, *, method: str = "GET", payload=None, headers=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request_headers = dict(headers or {})
    if payload is not None:
        request_headers["Content-Type"] = "application/json"
    http_request = urllib.request.Request(url, data=data, headers=request_headers, method=method)
    try:
        with opener.open(http_request, timeout=30) as response:
            return response.status, response.geturl(), response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.geturl(), error.read()


def console_search(opener, index_pattern: str, query_string: str) -> dict:
    global CURRENT_STAGE
    CURRENT_STAGE = f"discover-search:{index_pattern}"
    encoded = urllib.parse.urlencode({"path": f"{index_pattern}/_search", "method": "GET"})
    status, final_url, body = request(
        opener,
        f"{WAZUH_URL}/api/console/proxy?{encoded}",
        method="POST",
        payload={"query": {"query_string": {"query": query_string}}, "size": 1},
        headers={"osd-xsrf": "true"},
    )
    if status != 200 or urllib.parse.urlsplit(final_url).hostname != "wazuh.imcherry5778.xyz":
        raise RuntimeError(f"Dashboard OIDC query failed: HTTP {status}")
    try:
        decoded = json.loads(body)
    except json.JSONDecodeError as error:
        raise RuntimeError("Dashboard OIDC query returned non-JSON") from error
    if not isinstance(decoded, dict):
        raise RuntimeError("Dashboard OIDC query JSON is not an object")
    return decoded


def main() -> None:
    global CURRENT_STAGE
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", type=Path, required=True)
    parser.add_argument("--connect-ip", required=True)
    parser.add_argument("--username", required=True)
    parser.add_argument("--password-file", type=Path, required=True)
    parser.add_argument("--totp-file", type=Path, required=True)
    args = parser.parse_args()
    require_secret_file(args.password_file)
    require_secret_file(args.totp_file)

    browser = load_pomerium_browser(args.repo_root)
    cookie_jar = http.cookiejar.CookieJar()
    opener = browser.build_opener(cookie_jar, args.connect_ip)

    # The outer Pomerium authorization-code flow consumes MFA and lands on
    # the Dashboard's captureUrlFragment page. Its browser JavaScript starts
    # native OIDC with this same URL; perform that deterministic navigation so
    # the Dashboard exchanges the code and writes its own session cookie.
    CURRENT_STAGE = "pomerium-entry"
    status, final_url, _ = browser.login(
        opener,
        START_URL,
        args.username,
        str(args.password_file),
        str(args.totp_file),
    )
    if status != 200 or urllib.parse.urlsplit(final_url).hostname != "wazuh.imcherry5778.xyz":
        raise RuntimeError(f"Pomerium entry did not return its Wazuh route: HTTP {status}")

    CURRENT_STAGE = "dashboard-native-oidc"
    native_oidc_query = urllib.parse.urlencode(
        {"redirectHash": "false", "nextUrl": "/app/wz-home"}
    )
    status, final_url, _ = request(
        opener, f"{WAZUH_URL}/auth/openid/login?{native_oidc_query}"
    )
    final = urllib.parse.urlsplit(final_url)
    if status != 200 or final.hostname != "wazuh.imcherry5778.xyz" or final.path != "/app/wz-home":
        raise RuntimeError(f"Dashboard native OIDC did not return its Wazuh route: HTTP {status}")

    d30 = console_search(
        opener, D30_INDEX_PATTERN, f"data.alert.signature_id:{REPRESENTATIVE_SID}*"
    )
    if not d30.get("hits", {}).get("hits"):
        raise RuntimeError(f"D30 index lacks existing sid {REPRESENTATIVE_SID} through OIDC session")
    a90 = console_search(opener, A90_INDEX_PATTERN, "rule.id:[100100 TO 100109]")
    if not a90.get("hits", {}).get("hits"):
        raise RuntimeError("A90 index lacks existing audit event through OIDC session")
    CURRENT_STAGE = "complete"
    print(
        "WAZUH-02-FIX-01 browser=PASS pomerium-entry=native-oidc=allow D30/A90=found"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(
            f"WAZUH-02-FIX-01 browser=FAIL stage={CURRENT_STAGE} type={type(error).__name__} detail={error}",
            file=sys.stderr,
        )
        raise SystemExit(1)
