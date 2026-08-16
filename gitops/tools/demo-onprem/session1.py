#!/usr/bin/env python3
"""합성 계정 한 browser session으로 allow 200과 privileged 403을 판정한다."""

from __future__ import annotations

import argparse
import http.cookiejar
import importlib.util
from pathlib import Path


USERNAME = "demo-onprem-user"
CONTROL = "https://access.imcherry5778.xyz/demo-onprem/account/control"
RESTRICTED = "https://access.imcherry5778.xyz/demo-onprem/account/restricted"
MARKER = b'{"marker":"DEMO-ACCOUNT-CONTROL-200"}'


def load_browser(repo: Path):
    path = repo / "gitops/tools/pom-01/browser-session.py"
    spec = importlib.util.spec_from_file_location("demo_onprem_browser", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("browser helper load failed")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--connect-ip", default="10.10.20.10")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[3]
    browser = load_browser(repo)
    secret_dir = Path("/home/imcherry/secrets/ktcloud4-bean/demo-onprem")
    jar = http.cookiejar.CookieJar()
    opener = browser.build_opener(jar, args.connect_ip)
    status, final_url, body = browser.login(
        opener, CONTROL, USERNAME, str(secret_dir / "password"), str(secret_dir / "totp")
    )
    if status != 200 or final_url != CONTROL or body != MARKER:
        raise RuntimeError(f"control path mismatch: HTTP {status}")
    status, final_url, _headers, _body = browser.get_response(opener, RESTRICTED)
    if status != 403 or final_url != RESTRICTED:
        raise RuntimeError(f"restricted path mismatch: HTTP {status}")
    print("DEMO_SESSION1_CONTROL=PASS same_account=true same_session=true allow=200 restricted=403 groups=masked")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"DEMO_SESSION1_CONTROL=FAIL reason={error}", file=__import__("sys").stderr)
        raise SystemExit(1)
