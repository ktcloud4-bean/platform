#!/usr/bin/env python3
"""SUPPLY-01-FIX-01 OPNsense exact TUF proxy rules."""

import argparse
import base64
import fcntl
import json
import os
import pathlib
import re
import ssl
import subprocess
import tempfile
import urllib.error
import urllib.request

ALIAS_NAME = "SUPPLY01_TUF_CDN_HOST"
ALIAS_CONTENT = "tuf-repo-cdn.sigstore.dev"
ALIAS_DESCRIPTION = "SUPPLY-01-FIX-01: Kyverno TUF CDN FQDN"
RULES = (
    {
        "interface": "opt2",
        "sequence": "1181",
        "source_net": "10.10.20.12",
        "destination_net": ALIAS_NAME,
        "destination_port": "443",
        "description": "SUPPLY-01-FIX-01: TUF proxy source에서 sigstore TUF CDN TCP 443만 허용",
    },
    {
        "interface": "enc0",
        "sequence": "2581",
        "source_net": "10.20.10.0/24",
        "destination_net": "10.10.20.12",
        "destination_port": "8445",
        "description": "SUPPLY-01-FIX-01: EKS app subnet 10.20.10.0/24에서 TUF proxy TCP 8445만 허용",
    },
    {
        "interface": "enc0",
        "sequence": "2681",
        "source_net": "10.20.20.0/24",
        "destination_net": "10.10.20.12",
        "destination_port": "8445",
        "description": "SUPPLY-01-FIX-01: EKS app subnet 10.20.20.0/24에서 TUF proxy TCP 8445만 허용",
    },
)
UUID_PATTERN = re.compile(r"^[0-9a-f-]{36}$")
STATE_ROOT = pathlib.Path("/home/imcherry/.local/state-backups")


class Failure(RuntimeError):
    pass


def fail(message):
    raise Failure(f"SUPPLY-01-FIX-01 실패: {message}")


def checked_uuid(value, field):
    if not isinstance(value, str) or not UUID_PATTERN.fullmatch(value):
        fail(f"{field} UUID 형식이 안전하지 않다.")
    return value


def load_env(path):
    try:
        metadata = path.stat()
    except FileNotFoundError:
        fail("OPNsense env 파일이 없다.")
    if not path.is_file() or path.is_symlink() or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
        fail("OPNsense env 파일의 type·소유자·권한이 안전하지 않다.")
    values = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key in {"OPN_KEY", "OPN_SECRET", "OPN_URL", "OPN_CACERT"}:
            values[key] = value
    for key in ("OPN_KEY", "OPN_SECRET"):
        if os.environ.get(key):
            values[key] = os.environ[key]
    if not values.get("OPN_KEY") or not values.get("OPN_SECRET"):
        fail("OPN_KEY와 OPN_SECRET이 필요하다.")
    base_url = values.get("OPN_URL", "https://opnsense.imcherry5778.xyz").rstrip("/")
    if not base_url.startswith("https://") or "@" in base_url:
        fail("OPN_URL은 credential 없는 https URL이어야 한다.")
    cacert = values.get("OPN_CACERT")
    if cacert and not pathlib.Path(cacert).is_file():
        fail("OPN_CACERT를 읽을 수 없다.")
    return values, base_url, cacert


class Client:
    def __init__(self, values, base_url, cacert):
        self.base_url = base_url
        self.auth = base64.b64encode(
            (values["OPN_KEY"] + ":" + values["OPN_SECRET"]).encode("utf-8")
        ).decode("ascii")
        self.context = ssl.create_default_context(cafile=cacert) if cacert else ssl.create_default_context()

    def call(self, method, path, payload=None):
        data = None
        headers = {"Authorization": "Basic " + self.auth}
        if payload is not None:
            data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base_url + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, context=self.context, timeout=300) as response:
                raw = response.read()
        except urllib.error.HTTPError as error:
            fail(f"OPNsense API HTTP {error.code}: {path}")
        except urllib.error.URLError as error:
            fail(f"OPNsense API transport 실패: {error.reason}")
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            fail(f"JSON이 아닌 OPNsense API 응답이다: {path}")


def alias_rows(client):
    rows = client.call("POST", "/api/firewall/alias/search_item", {}).get("rows", [])
    return [row for row in rows if row.get("name") == ALIAS_NAME]


def rule_rows(client, interface):
    rows = client.call("GET", f"/api/firewall/filter/search_rule?interface={interface}&show_all=1").get("rows", [])
    return [row for row in rows if row.get("description", "").startswith("SUPPLY-01-FIX-01:")]


def validate_alias(rows):
    if len(rows) != 1:
        fail("TUF CDN alias 개수가 정확히 하나가 아니다.")
    expected = {
        "enabled": "1",
        "name": ALIAS_NAME,
        "type": "host",
        "content": ALIAS_CONTENT,
        "description": ALIAS_DESCRIPTION,
    }
    if any(rows[0].get(key) != value for key, value in expected.items()):
        fail("TUF CDN alias 의미값이 계획과 다르다.")


def validate_rule(row, expected, enabled):
    values = {
        "enabled": enabled,
        "sequence": expected["sequence"],
        "action": "pass",
        "quick": "1",
        "interface": expected["interface"],
        "direction": "in",
        "ipprotocol": "inet",
        "protocol": "TCP",
        "source_net": expected["source_net"],
        "source_port": "",
        "destination_net": expected["destination_net"],
        "destination_port": expected["destination_port"],
        "log": "1",
        "description": expected["description"],
    }
    if any(row.get(key) != value for key, value in values.items()):
        fail(f"TUF rule 의미값이 계획과 다르다: {expected['description']}")


def runtime_rule(client, rule_uuid):
    stats = client.call("GET", "/api/firewall/filter_util/rule_stats").get("stats", {})
    try:
        loaded = int(stats[rule_uuid]["pf_rules"])
    except (KeyError, TypeError, ValueError):
        loaded = 0
    if loaded < 1:
        fail(f"PF runtime에 TUF rule이 없다: {rule_uuid}")


def state_dir():
    STATE_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = pathlib.Path(tempfile.mkdtemp(prefix="supply-01-fix-01-", dir=STATE_ROOT))
    os.chmod(path, 0o700)
    return path


def remove_rule(client, rule_uuid):
    client.call("POST", f"/api/firewall/filter/toggle_rule/{rule_uuid}/0")
    client.call("POST", "/api/firewall/filter/apply")
    client.call("POST", f"/api/firewall/filter/del_rule/{rule_uuid}")
    client.call("POST", "/api/firewall/filter/apply")


def rollback_created(client, alias_uuid, rule_uuids):
    for rule_uuid in reversed(rule_uuids):
        try:
            remove_rule(client, rule_uuid)
        except Failure:
            pass
    if alias_uuid:
        try:
            client.call("POST", f"/api/firewall/alias/del_item/{alias_uuid}")
            client.call("POST", "/api/firewall/alias/reconfigure")
        except Failure:
            pass


def apply(client, repo_root, env_file):
    with open("/tmp/ktcloud4-bean-opnsense-live.lock", "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        subprocess.run(
            [str(repo_root / "infra/opnsense/scripts/check-drift.sh"), "--env-file", str(env_file)],
            check=True,
        )
        if alias_rows(client):
            fail("같은 TUF CDN alias가 이미 있다.")
        existing = [row for rule in RULES for row in rule_rows(client, rule["interface"])]
        if existing:
            fail("같은 SUPPLY-01-FIX-01 rule이 이미 있다.")
        path = state_dir()
        alias_uuid = ""
        rule_uuids = []
        print(f"복구 지점={path}")
        try:
            response = client.call("POST", "/api/firewall/alias/add_item", {"alias": {
                "enabled": "1", "name": ALIAS_NAME, "type": "host", "content": ALIAS_CONTENT,
                "description": ALIAS_DESCRIPTION,
            }})
            alias_uuid = checked_uuid(response.get("uuid"), "TUF CDN alias")
            (path / "alias-uuid").write_text(alias_uuid + "\n", encoding="ascii")
            client.call("POST", "/api/firewall/alias/reconfigure")
            validate_alias(alias_rows(client))
            for expected in RULES:
                response = client.call("POST", "/api/firewall/filter/add_rule", {"rule": {
                    "enabled": "0", "statetype": "keep", "sequence": expected["sequence"],
                    "action": "pass", "quick": "1", "interface": expected["interface"],
                    "direction": "in", "ipprotocol": "inet", "protocol": "TCP",
                    "source_net": expected["source_net"], "source_port": "",
                    "destination_net": expected["destination_net"],
                    "destination_port": expected["destination_port"], "gateway": "", "log": "1",
                    "description": expected["description"],
                }})
                rule_uuid = checked_uuid(response.get("uuid"), "TUF firewall rule")
                rule_uuids.append(rule_uuid)
                (path / rule_uuid).write_text(expected["description"] + "\n", encoding="utf-8")
                validate_rule(next(row for row in rule_rows(client, expected["interface"]) if row.get("uuid") == rule_uuid), expected, "0")
            for rule_uuid in rule_uuids:
                client.call("POST", f"/api/firewall/filter/toggle_rule/{rule_uuid}/1")
            client.call("POST", "/api/firewall/filter/apply")
            for expected, rule_uuid in zip(RULES, rule_uuids):
                row = next(row for row in rule_rows(client, expected["interface"]) if row.get("uuid") == rule_uuid)
                validate_rule(row, expected, "1")
                runtime_rule(client, rule_uuid)
            print("FirewallApply=PASS rules=3 alias=SUPPLY01_TUF_CDN_HOST")
        except Exception:
            rollback_created(client, alias_uuid, rule_uuids)
            raise
        print(f"STATE_DIR={path}")


def rollback(client, path):
    resolved = path.resolve()
    if resolved.parent != STATE_ROOT or not resolved.name.startswith("supply-01-fix-01-") or path.is_symlink():
        fail("명시적인 SUPPLY-01-FIX-01 복구 지점이 필요하다.")
    uuids = [item.name for item in resolved.iterdir() if UUID_PATTERN.fullmatch(item.name)]
    if len(uuids) != 3:
        fail("복구 지점의 TUF rule UUID가 3개가 아니다.")
    with open("/tmp/ktcloud4-bean-opnsense-live.lock", "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        for rule_uuid in uuids:
            remove_rule(client, rule_uuid)
        alias = alias_rows(client)
        if len(alias) == 1:
            client.call("POST", f"/api/firewall/alias/del_item/{checked_uuid((resolved / 'alias-uuid').read_text(encoding='ascii').strip(), 'alias')}")
            client.call("POST", "/api/firewall/alias/reconfigure")
        if alias_rows(client) or any(rule_rows(client, rule["interface"]) for rule in RULES):
            fail("rollback 뒤 SUPPLY-01-FIX-01 rule 또는 alias가 남아 있다.")
        print(f"RollbackReference={resolved}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("apply", "rollback"))
    parser.add_argument("state_dir", nargs="?")
    args = parser.parse_args()
    repo_root = pathlib.Path(__file__).resolve().parents[3]
    secret_root = pathlib.Path(os.environ.get("KTC_SECRET_ROOT", "/home/imcherry/secrets/ktcloud4-bean"))
    env_file = pathlib.Path(os.environ.get("SUPPLY01_OPN_ENV_FILE", secret_root / "opnsense/env"))
    values, base_url, cacert = load_env(env_file)
    client = Client(values, base_url, cacert)
    try:
        if args.action == "apply":
            if args.state_dir:
                fail("apply에는 복구 지점을 넘기지 않는다.")
            apply(client, repo_root, env_file)
        else:
            if not args.state_dir:
                fail("rollback에는 복구 지점이 필요하다.")
            rollback(client, pathlib.Path(args.state_dir))
    except BlockingIOError:
        fail("다른 OPNSENSE-LIVE 작업이 실행 중이다.")


if __name__ == "__main__":
    try:
        main()
    except Failure as error:
        print(error, file=os.sys.stderr)
        raise SystemExit(1)
