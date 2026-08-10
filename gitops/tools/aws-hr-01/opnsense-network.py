#!/usr/bin/env python3
"""AWS-HR-01의 OPNsense DNS 전달과 k3s 단일 egress를 지원 API로만 관리한다."""

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
RESOLVER_ALIAS = {
    "enabled": "1",
    "name": "AWS_HR_01_RESOLVER_V4",
    "type": "network",
    "content": "10.20.10.53\n10.20.20.102",
    "description": "AWS-HR-01 Route 53 Resolver inbound endpoint IPv4",
}
K3S_HOST = {
    "enabled": "1",
    "hostname": "k3s-01",
    "domain": "imcherry5778.xyz",
    "rr": "A",
    "server": "10.10.20.10",
}
HOST_ALIASES = (
    {
        "enabled": "1",
        "hostname": "www",
        "domain": "imcherry5778.xyz",
        "description": "AWS-HR-01 employee self-service Pomerium alias",
    },
    {
        "enabled": "1",
        "hostname": "admin",
        "domain": "imcherry5778.xyz",
        "description": "AWS-HR-01 HR admin Pomerium alias",
    },
)
FORWARDS = (
    {
        "enabled": "1",
        "type": "forward",
        "domain": "ap-northeast-2.eks.amazonaws.com",
        "server": "10.10.20.10",
        "port": "1053",
        "verify": "",
        "forward_tcp_upstream": "0",
        "forward_first": "0",
        "description": "AWS-HR-01 EKS private API conditional forwarder via k3s DNS relay",
    },
    {
        "enabled": "1",
        "type": "forward",
        "domain": "aws.imcherry5778.xyz",
        "server": "10.10.20.10",
        "port": "1053",
        "verify": "",
        "forward_tcp_upstream": "0",
        "forward_first": "0",
        "description": "AWS-HR-01 internal ALB private zone conditional forwarder via k3s DNS relay",
    },
)
LEGACY_FORWARDS = (
    {
        "enabled": "1",
        "type": "forward",
        "domain": "ap-northeast-2.eks.amazonaws.com",
        "server": "10.20.10.53",
        "port": "53",
        "verify": "",
        "forward_tcp_upstream": "0",
        "forward_first": "0",
        "description": "AWS-HR-01 EKS private API conditional forwarder AZ-a",
    },
    {
        "enabled": "1",
        "type": "forward",
        "domain": "ap-northeast-2.eks.amazonaws.com",
        "server": "10.20.20.102",
        "port": "53",
        "verify": "",
        "forward_tcp_upstream": "0",
        "forward_first": "0",
        "description": "AWS-HR-01 EKS private API conditional forwarder AZ-c",
    },
    {
        "enabled": "1",
        "type": "forward",
        "domain": "aws.imcherry5778.xyz",
        "server": "10.20.10.53",
        "port": "53",
        "verify": "",
        "forward_tcp_upstream": "0",
        "forward_first": "0",
        "description": "AWS-HR-01 internal ALB private zone conditional forwarder AZ-a",
    },
    {
        "enabled": "1",
        "type": "forward",
        "domain": "aws.imcherry5778.xyz",
        "server": "10.20.20.102",
        "port": "53",
        "verify": "",
        "forward_tcp_upstream": "0",
        "forward_first": "0",
        "description": "AWS-HR-01 internal ALB private zone conditional forwarder AZ-c",
    },
)
EXISTING_EKS_API_RULE = {
    "enabled": "1",
    "sequence": "1021",
    "action": "pass",
    "quick": "1",
    "interface": "opt2",
    "direction": "in",
    "ipprotocol": "inet",
    "protocol": "TCP",
    "source_net": "10.10.20.10",
    "source_port": "",
    "destination_net": "10.20.0.0/16",
    "destination_port": "443",
    "log": "1",
    "description": "AWS-HR-01: k3s-01에서 AWS shared VPC EKS API와 internal ALB TCP 443만 허용",
}
RULES_TO_ADD = (
    {
        "enabled": "1",
        "statetype": "keep",
        "sequence": "1017",
        "action": "pass",
        "quick": "1",
        "interface": "opt2",
        "direction": "in",
        "ipprotocol": "inet",
        "protocol": "TCP",
        "source_net": "10.10.20.10",
        "source_port": "",
        "destination_net": "10.20.0.0/16",
        "destination_port": "80",
        "gateway": "",
        "log": "1",
        "description": "AWS-HR-01: k3s-01 Pomerium에서 AWS internal ALB HTTP 80만 허용",
    },
    {
        "enabled": "1",
        "statetype": "keep",
        "sequence": "1019",
        "action": "pass",
        "quick": "1",
        "interface": "opt2",
        "direction": "in",
        "ipprotocol": "inet",
        "protocol": "TCP/UDP",
        "source_net": "10.10.20.10",
        "source_port": "",
        "destination_net": RESOLVER_ALIAS["name"],
        "destination_port": "53",
        "gateway": "",
        "log": "1",
        "description": "AWS-HR-01: k3s-01에서 Route 53 Resolver endpoint DNS TCP/UDP 53만 허용",
    },
)


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
        if key not in allowed:
            raise RuntimeError(f"unsupported OPN setting at line {number}: {key}")
        if key in values:
            raise RuntimeError(f"duplicate OPN setting at line {number}: {key}")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
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
        token = base64.b64encode(
            f"{values['OPN_KEY']}:{values['OPN_SECRET']}".encode("utf-8")
        ).decode("ascii")
        self.headers = {"Authorization": f"Basic {token}", "Content-Type": "application/json"}
        self.context = ssl.create_default_context()
        if values.get("OPN_CACERT"):
            ca_path = Path(values["OPN_CACERT"])
            if not ca_path.is_file():
                raise RuntimeError("OPN_CACERT is not a readable file")
            self.context.load_verify_locations(cafile=str(ca_path))

    def request(self, method: str, path: str, payload=None):
        if not path.startswith("/api/"):
            raise RuntimeError("unsupported API path")
        request = urllib.request.Request(
            f"{self.base}{path}",
            data=None if payload is None and method == "GET" else json.dumps(payload or {}).encode("utf-8"),
            headers=self.headers,
            method=method,
        )
        try:
            with urllib.request.urlopen(request, timeout=30, context=self.context) as response:
                body = json.load(response)
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"OPNsense API {path} returned HTTP {error.code}") from error
        if response.status != 200 or not isinstance(body, dict):
            raise RuntimeError(f"invalid API response: {path}")
        return body

    def get(self, path: str):
        return self.request("GET", path)

    def post(self, path: str, payload=None):
        return self.request("POST", path, payload)


def value_matches(row: dict, expected: dict) -> bool:
    return all(str(row.get(key, "")) == value for key, value in expected.items())


def normalized_content(value: str) -> list[str]:
    return sorted(item for item in value.replace(",", "\n").splitlines() if item)


def search_rows(client: Client, path: str, method: str = "GET") -> list[dict]:
    body = client.post(path) if method == "POST" else client.get(path)
    rows = body.get("rows")
    if not isinstance(rows, list):
        raise RuntimeError(f"invalid search response: {path}")
    return rows


def state(client: Client) -> dict:
    aliases = [row for row in search_rows(client, "/api/firewall/alias/search_item", "POST") if row.get("name") == RESOLVER_ALIAS["name"]]
    if len(aliases) > 1:
        raise RuntimeError("Resolver alias is not unique")
    if aliases:
        alias = aliases[0]
        if not value_matches(alias, {key: value for key, value in RESOLVER_ALIAS.items() if key != "content"}) or normalized_content(str(alias.get("content", ""))) != normalized_content(RESOLVER_ALIAS["content"]):
            raise RuntimeError("Resolver alias exists but differs from the AWS-HR-01 declaration")

    hosts = [
        row
        for row in search_rows(client, "/api/unbound/settings/search_host_override", "POST")
        if value_matches(row, K3S_HOST)
    ]
    if len(hosts) > 1:
        raise RuntimeError("k3s-01 Unbound host override is not unique")
    host_uuid = str(hosts[0].get("uuid", "")) if hosts else ""
    if hosts and not host_uuid:
        raise RuntimeError("k3s-01 Unbound host override UUID is missing")

    host_alias_rows = search_rows(client, "/api/unbound/settings/search_host_alias", "POST")
    host_aliases: dict[str, dict] = {}
    for expected in HOST_ALIASES:
        name = expected["hostname"]
        matches = [
            row
            for row in host_alias_rows
            if row.get("hostname") == name and row.get("domain") == expected["domain"]
        ]
        if len(matches) > 1:
            raise RuntimeError(f"{name} Unbound host alias is not unique")
        if matches:
            row = matches[0]
            if not host_uuid or row.get("host") != host_uuid or not value_matches(row, expected):
                raise RuntimeError(f"{name} Unbound host alias differs from the AWS-HR-01 declaration")
            if not row.get("uuid"):
                raise RuntimeError(f"{name} Unbound host alias UUID is missing")
            host_aliases[name] = row

    forwards = search_rows(client, "/api/unbound/settings/search_forward", "POST")
    forward_descriptions = {item["description"] for item in (*FORWARDS, *LEGACY_FORWARDS)}
    owned_forwards = [row for row in forwards if row.get("description") in forward_descriptions]
    expected_forward_keys = {(item["domain"], item["server"]) for item in FORWARDS}
    legacy_forward_keys = {(item["domain"], item["server"]) for item in LEGACY_FORWARDS}
    seen_forward_keys = set()
    legacy_forwards = []
    for row in owned_forwards:
        key = (str(row.get("domain", "")), str(row.get("server", "")))
        if (key not in expected_forward_keys and key not in legacy_forward_keys) or key in seen_forward_keys:
            raise RuntimeError("conditional forwarder has an unexpected or duplicate entry")
        expected = next(item for item in (*FORWARDS, *LEGACY_FORWARDS) if (item["domain"], item["server"]) == key)
        if not value_matches(row, expected):
            raise RuntimeError("conditional forwarder differs from the AWS-HR-01 declaration")
        if not row.get("uuid"):
            raise RuntimeError("conditional forwarder UUID is missing")
        seen_forward_keys.add(key)
        if key in legacy_forward_keys:
            legacy_forwards.append(row)

    rules = search_rows(client, "/api/firewall/filter/search_rule", "POST")
    expected_rules = (EXISTING_EKS_API_RULE, *RULES_TO_ADD)
    descriptions = {item["description"] for item in expected_rules}
    owned_rules = [row for row in rules if str(row.get("description", "")).startswith("AWS-HR-01:")]
    seen_descriptions = set()
    for row in owned_rules:
        description = str(row.get("description", ""))
        if description not in descriptions or description in seen_descriptions:
            raise RuntimeError("AWS-HR-01 firewall rule has an unexpected or duplicate entry")
        expected = next(item for item in expected_rules if item["description"] == description)
        if not value_matches(row, expected):
            raise RuntimeError("AWS-HR-01 firewall rule differs from the declaration")
        if not row.get("uuid"):
            raise RuntimeError("AWS-HR-01 firewall rule UUID is missing")
        seen_descriptions.add(description)

    return {
        "alias": aliases[0] if aliases else None,
        "host_uuid": host_uuid,
        "host_aliases": host_aliases,
        "forward_keys": seen_forward_keys,
        "legacy_forwards": legacy_forwards,
        "rule_descriptions": seen_descriptions,
    }


def assert_runtime(client: Client):
    current = state(client)
    if not current["alias"]:
        raise RuntimeError("Resolver alias is absent")
    if not current["host_uuid"]:
        raise RuntimeError("k3s-01 Unbound host override is absent")
    if set(current["host_aliases"]) != {item["hostname"] for item in HOST_ALIASES}:
        raise RuntimeError("HR Unbound host aliases are incomplete")
    if len(current["forward_keys"]) != len(FORWARDS):
        raise RuntimeError("conditional forwarders are incomplete")
    if current["legacy_forwards"]:
        raise RuntimeError("obsolete EKS conditional forwarder remains")
    if current["rule_descriptions"] != {item["description"] for item in (EXISTING_EKS_API_RULE, *RULES_TO_ADD)}:
        raise RuntimeError("firewall rules are incomplete")
    return current


def api_saved(body: dict, action: str):
    if body.get("result") not in {"saved", "deleted"}:
        raise RuntimeError(f"{action} was not saved: {json.dumps(body, sort_keys=True)}")


def status_ok(body: dict) -> bool:
    return str(body.get("status", "")).strip().lower() in {"ok", "done"}


def reconfigure_unbound(client: Client):
    body = client.post("/api/unbound/service/reconfigure")
    if not status_ok(body):
        raise RuntimeError("Unbound reconfigure did not succeed")


def reconfigure_aliases(client: Client):
    body = client.post("/api/firewall/alias/reconfigure")
    if not status_ok(body):
        raise RuntimeError("firewall alias reconfigure did not succeed")


def apply(client: Client):
    current = state(client)
    created_host_aliases: list[str] = []
    created_forwards: list[str] = []
    deleted_legacy_forwards: list[dict] = []
    created_alias = False
    created_rules: list[str] = []
    firewall_committed = False
    try:
        if not current["alias"]:
            body = client.post("/api/firewall/alias/add_item", {"alias": RESOLVER_ALIAS})
            api_saved(body, "add resolver alias")
            if not body.get("uuid"):
                raise RuntimeError("resolver alias UUID is missing")
            created_alias = True

        for expected in FORWARDS:
            key = (expected["domain"], expected["server"])
            if key not in current["forward_keys"]:
                body = client.post("/api/unbound/settings/add_forward", {"dot": expected})
                api_saved(body, "add conditional forwarder")
                if not body.get("uuid"):
                    raise RuntimeError("conditional forwarder UUID is missing")
                created_forwards.append(str(body["uuid"]))
        if created_forwards:
            reconfigure_unbound(client)
        current = state(client)
        for legacy in current["legacy_forwards"]:
            body = client.post(f"/api/unbound/settings/del_forward/{legacy['uuid']}")
            api_saved(body, "delete obsolete conditional forwarder")
            deleted_legacy_forwards.append(legacy)
        if deleted_legacy_forwards:
            reconfigure_unbound(client)

        current = state(client)
        if not current["host_uuid"]:
            raise RuntimeError("k3s-01 Unbound host override is absent")
        for expected in HOST_ALIASES:
            if expected["hostname"] in current["host_aliases"]:
                continue
            body = client.post(
                "/api/unbound/settings/add_host_alias",
                {"alias": {**expected, "host": current["host_uuid"]}},
            )
            api_saved(body, f"add {expected['hostname']} Unbound host alias")
            if not body.get("uuid"):
                raise RuntimeError(f"{expected['hostname']} Unbound host alias UUID is missing")
            created_host_aliases.append(str(body["uuid"]))
        if created_host_aliases:
            reconfigure_unbound(client)
        if created_alias:
            reconfigure_aliases(client)

        current = state(client)
        missing_rules = [
            rule for rule in RULES_TO_ADD
            if rule["description"] not in current["rule_descriptions"]
        ]
        if missing_rules:
            for rule in missing_rules:
                staged = {**rule, "enabled": "0"}
                body = client.post("/api/firewall/filter/add_rule", {"rule": staged})
                api_saved(body, "stage firewall rule")
                if not body.get("uuid"):
                    raise RuntimeError("staged firewall rule UUID is missing")
                created_rules.append(str(body["uuid"]))

            all_rules = search_rows(client, "/api/firewall/filter/search_rule", "POST")
            for rule in missing_rules:
                matched = [row for row in all_rules if row.get("description") == rule["description"]]
                if len(matched) != 1:
                    raise RuntimeError("staged firewall rule is not uniquely readable")
                row = matched[0]
                if not value_matches(row, {**rule, "enabled": "0"}):
                    raise RuntimeError("staged firewall rule differs from the declaration")
                body = client.post(f"/api/firewall/filter/toggle_rule/{row['uuid']}/1")
                if body.get("result") not in {"saved", "ok", "done", "Enabled"}:
                    raise RuntimeError(f"enable firewall rule did not succeed: {json.dumps(body, sort_keys=True)}")
            body = client.post("/api/firewall/filter/apply")
            if not status_ok(body):
                raise RuntimeError(f"firewall apply did not succeed: {json.dumps(body, sort_keys=True)}")
            assert_runtime(client)
            firewall_committed = True
        assert_runtime(client)
    except Exception:
        for uuid in reversed(created_host_aliases):
            try:
                client.post(f"/api/unbound/settings/del_host_alias/{uuid}")
            except Exception:
                pass
        if created_host_aliases:
            try:
                reconfigure_unbound(client)
            except Exception:
                pass
        if created_rules and not firewall_committed:
            try:
                for uuid in reversed(created_rules):
                    client.post(f"/api/firewall/filter/toggle_rule/{uuid}/0")
                    client.post(f"/api/firewall/filter/del_rule/{uuid}")
                client.post("/api/firewall/filter/apply")
            except Exception:
                pass
        for uuid in reversed(created_forwards):
            try:
                client.post(f"/api/unbound/settings/del_forward/{uuid}")
            except Exception:
                pass
        if created_forwards:
            try:
                reconfigure_unbound(client)
            except Exception:
                pass
        for legacy in deleted_legacy_forwards:
            try:
                legacy_payload = {
                    key: str(legacy.get(key, ""))
                    for key in FORWARDS[0]
                }
                client.post("/api/unbound/settings/add_forward", {"dot": legacy_payload})
            except Exception:
                pass
        if deleted_legacy_forwards:
            try:
                reconfigure_unbound(client)
            except Exception:
                pass
        if created_alias:
            try:
                alias = state(client).get("alias")
                if alias and alias.get("uuid"):
                    client.post(f"/api/firewall/alias/del_item/{alias['uuid']}")
                    reconfigure_aliases(client)
            except Exception:
                pass
        raise


def rollback(client: Client):
    current = assert_runtime(client)
    try:
        rules = search_rows(client, "/api/firewall/filter/search_rule", "POST")
        for expected in RULES_TO_ADD:
            row = next(row for row in rules if row.get("description") == expected["description"])
            client.post(f"/api/firewall/filter/del_rule/{row['uuid']}")
        body = client.post("/api/firewall/filter/apply")
        if not status_ok(body):
            raise RuntimeError("firewall rollback apply did not succeed")
    except Exception:
        raise

    for expected in HOST_ALIASES:
        row = current["host_aliases"][expected["hostname"]]
        client.post(f"/api/unbound/settings/del_host_alias/{row['uuid']}")
    reconfigure_unbound(client)

    forwards = search_rows(client, "/api/unbound/settings/search_forward", "POST")
    for expected in FORWARDS:
        row = next(row for row in forwards if value_matches(row, expected))
        client.post(f"/api/unbound/settings/del_forward/{row['uuid']}")
    reconfigure_unbound(client)
    alias = current["alias"]
    client.post(f"/api/firewall/alias/del_item/{alias['uuid']}")
    reconfigure_aliases(client)
    print("AWS-HR-01 OPNsense rollback=PASS")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("check", "apply", "rollback"))
    parser.add_argument("--env-file", type=Path, default=ENV_DEFAULT)
    args = parser.parse_args()
    client = Client(load_env(args.env_file))
    if args.mode == "check":
        current = assert_runtime(client)
        print(
            "AWS-HR-01 OPNsense check=PASS "
            f"host_aliases={len(current['host_aliases'])} forwards={len(current['forward_keys'])} "
            f"firewall_rules={len(current['rule_descriptions'])}"
        )
        return
    if args.mode == "apply":
        apply(client)
        current = assert_runtime(client)
        print(
            "AWS-HR-01 OPNsense apply=PASS "
            f"host_aliases={len(current['host_aliases'])} forwards={len(current['forward_keys'])} "
            f"firewall_rules={len(current['rule_descriptions'])}"
        )
        return
    rollback(client)


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, urllib.error.URLError, urllib.error.HTTPError, json.JSONDecodeError) as error:
        print(f"AWS-HR-01 OPNsense failed: {type(error).__name__}: {error}", file=sys.stderr)
        raise SystemExit(1)
