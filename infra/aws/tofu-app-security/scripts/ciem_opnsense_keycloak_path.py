#!/usr/bin/env python3
"""AWS-SEC-03 Keycloak Admin API의 AWS→온프레미스 단일 IPsec 경로를 관리한다."""

import argparse
import base64
import json
import os
from pathlib import Path
import ssl
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request


ENV_DEFAULT = Path(os.environ.get("KTC_SECRET_ROOT", Path.home() / "secrets/ktcloud4-bean")) / "opnsense/env"
DESCRIPTION_PREFIX = "AWS-SEC-03: AWS CIEM Keycloak Admin HTTPS"
SOURCES = ("10.20.10.0/24", "10.20.20.0/24")


def expected_rule(source: str, enabled: str = "1") -> dict[str, str]:
    return {
        "enabled": enabled,
        "statetype": "keep",
        "action": "pass",
        "quick": "1",
        "interface": "enc0",
        "direction": "in",
        "ipprotocol": "inet",
        "protocol": "TCP",
        "source_net": source,
        "source_port": "",
        "destination_net": "10.10.20.10",
        "destination_port": "443",
        "gateway": "",
        "log": "1",
        "description": f"{DESCRIPTION_PREFIX} {source} to k3s-01 TCP 443 only",
    }


def load_env(path: Path) -> dict[str, str]:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
        raise RuntimeError("OPNsense env file must be a regular non-symlink file")
    if metadata.st_uid != os.getuid() or metadata.st_mode & 0o077:
        raise RuntimeError("OPNsense env file must be owned by the caller with mode 0600")

    values: dict[str, str] = {}
    allowed = {"OPN_KEY", "OPN_SECRET", "OPN_URL", "OPN_CACERT"}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if not key.startswith("OPN_"):
            continue
        if key not in allowed or key in values:
            raise RuntimeError(f"invalid OPN setting at line {number}: {key}")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        values[key] = value
    for required in ("OPN_KEY", "OPN_SECRET"):
        if not values.get(required):
            raise RuntimeError(f"missing {required}")
    values.setdefault("OPN_URL", "https://opnsense.imcherry5778.xyz")
    parsed = urllib.parse.urlsplit(values["OPN_URL"])
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        raise RuntimeError("OPN_URL must be a credential-free HTTPS origin")
    return values


class Client:
    def __init__(self, values: dict[str, str]):
        self.base = values["OPN_URL"].rstrip("/")
        token = base64.b64encode(f"{values['OPN_KEY']}:{values['OPN_SECRET']}".encode()).decode()
        self.headers = {"Authorization": f"Basic {token}", "Content-Type": "application/json"}
        self.context = ssl.create_default_context()
        if values.get("OPN_CACERT"):
            ca_path = Path(values["OPN_CACERT"])
            if not ca_path.is_file():
                raise RuntimeError("OPN_CACERT is not a readable file")
            self.context.load_verify_locations(cafile=str(ca_path))

    def post(self, path: str, payload: dict | None = None) -> dict:
        if not path.startswith("/api/"):
            raise RuntimeError("unsupported API path")
        request = urllib.request.Request(
            f"{self.base}{path}",
            data=json.dumps(payload or {}).encode(),
            headers=self.headers,
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=30, context=self.context) as response:
                body = json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"OPNsense API {path} returned HTTP {error.code}") from error
        if response.status != 200 or not isinstance(body, dict):
            raise RuntimeError(f"invalid API response: {path}")
        return body


def api_saved(body: dict, action: str) -> None:
    if body.get("result") not in {"saved", "deleted"}:
        detail = body.get("validations", body.get("result", "missing result"))
        raise RuntimeError(f"{action} was not saved: {json.dumps(detail, sort_keys=True)}")


def api_ok(body: dict, action: str) -> None:
    if str(body.get("status", "")).strip().lower() not in {"ok", "done"}:
        raise RuntimeError(f"{action} did not succeed: {json.dumps(body, sort_keys=True)}")


def rows(client: Client) -> list[dict]:
    body = client.post("/api/firewall/filter/search_rule")
    found = body.get("rows")
    if not isinstance(found, list):
        raise RuntimeError("invalid firewall rule search response")
    return found


def matches(row: dict, expected: dict[str, str]) -> bool:
    return all(str(row.get(key, "")) == value for key, value in expected.items())


def state(client: Client, enabled: str | None = None) -> dict[str, dict]:
    found = rows(client)
    result: dict[str, dict] = {}
    expected_descriptions = {expected_rule(source)["description"]: source for source in SOURCES}
    owned = [row for row in found if str(row.get("description", "")).startswith(DESCRIPTION_PREFIX)]
    for row in owned:
        description = str(row.get("description", ""))
        source = expected_descriptions.get(description)
        if source is None or source in result:
            raise RuntimeError("AWS-SEC-03 IPsec firewall rule is unexpected or duplicated")
        expected = expected_rule(source, enabled if enabled is not None else str(row.get("enabled", "")))
        if not matches(row, expected) or not row.get("uuid"):
            raise RuntimeError("AWS-SEC-03 IPsec firewall rule differs from the declaration")
        result[source] = row
    return result


def preflight(client: Client) -> None:
    current = state(client)
    if current and set(current) != set(SOURCES):
        raise RuntimeError("AWS-SEC-03 IPsec firewall rule is partially present")
    print(f"AWS-SEC-03 FirewallPreflight=PASS existing={len(current)} sources={len(SOURCES)}")


def check(client: Client) -> None:
    current = state(client, "1")
    if set(current) != set(SOURCES):
        raise RuntimeError("AWS-SEC-03 IPsec firewall rules are incomplete")
    print("AWS-SEC-03 FirewallCheck=PASS interface=enc0(IPsec) direction=in rules=2 destination=Keycloak-HTTPS")


def apply(client: Client) -> None:
    preflight(client)
    current = state(client)
    if current:
        check(client)
        return
    created: list[str] = []
    try:
        for source in SOURCES:
            body = client.post("/api/firewall/filter/add_rule", {"rule": expected_rule(source, "0")})
            api_saved(body, "stage firewall rule")
            uuid = str(body.get("uuid", ""))
            if not uuid:
                raise RuntimeError("staged firewall rule UUID is missing")
            created.append(uuid)
        staged = state(client, "0")
        if set(staged) != set(SOURCES):
            raise RuntimeError("staged firewall rules are incomplete")
        for source in SOURCES:
            body = client.post(f"/api/firewall/filter/toggle_rule/{staged[source]['uuid']}/1")
            if body.get("result") not in {"saved", "ok", "done", "Enabled"}:
                raise RuntimeError("enable firewall rule did not succeed")
        api_ok(client.post("/api/firewall/filter/apply"), "firewall apply")
        check(client)
    except Exception:
        for uuid in reversed(created):
            try:
                client.post(f"/api/firewall/filter/toggle_rule/{uuid}/0")
                client.post(f"/api/firewall/filter/del_rule/{uuid}")
            except Exception:
                pass
        if created:
            try:
                client.post("/api/firewall/filter/apply")
            except Exception:
                pass
        raise


def rollback(client: Client) -> None:
    current = state(client, "1")
    if set(current) != set(SOURCES):
        raise RuntimeError("AWS-SEC-03 IPsec firewall rollback target is incomplete")
    for source in SOURCES:
        api_saved(client.post(f"/api/firewall/filter/del_rule/{current[source]['uuid']}"), "delete firewall rule")
    api_ok(client.post("/api/firewall/filter/apply"), "firewall rollback apply")
    if state(client):
        raise RuntimeError("AWS-SEC-03 IPsec firewall rollback left owned rules")
    print("AWS-SEC-03 FirewallRollback=PASS rules=0")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("preflight", "apply", "check", "rollback"))
    parser.add_argument("--env-file", type=Path, default=ENV_DEFAULT)
    args = parser.parse_args()
    client = Client(load_env(args.env_file))
    {"preflight": preflight, "apply": apply, "check": check, "rollback": rollback}[args.mode](client)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as error:
        print(f"AWS-SEC-03 firewall failed: {type(error).__name__}: {error}", file=sys.stderr)
        raise SystemExit(1)
