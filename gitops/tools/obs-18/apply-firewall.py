#!/usr/bin/env python3
"""OBS-18 Slack CONNECT proxy의 OPNsense FQDN alias/rule lifecycle."""

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

ALIAS_NAME = "OBS18_SLACK_HOST"
ALIAS_DESCRIPTION = "OBS-18: Alertmanager Slack Incoming Webhook FQDN"
ALIAS_CONTENT = "hooks.slack.com"
RULE_SEQUENCE = "1023"
RULE_DESCRIPTION = "OBS-18: Slack egress proxy source에서 hooks.slack.com TCP 443만 허용"
EGRESS_SOURCE = "10.10.20.11"
UUID_PATTERN = re.compile(r"^[0-9a-f-]{36}$")
STATE_ROOT = pathlib.Path("/home/imcherry/.local/state-backups")


class Failure(RuntimeError):
    pass


def fail(message):
    raise Failure(f"OBS-18 실패: {message}")


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
    allowed = {"OPN_KEY", "OPN_SECRET", "OPN_URL", "OPN_CACERT"}
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        if not key.startswith("OPN_"):
            continue
        if key not in allowed or key in values:
            fail(f"OPNsense env {line_number}행의 key가 허용되지 않는다.")
        values[key] = value
    for key in allowed:
        if os.environ.get(key):
            values[key] = os.environ[key]

    base_url = values.get("OPN_URL", "https://opnsense.imcherry5778.xyz").rstrip("/")
    if not base_url.startswith("https://") or "@" in base_url:
        fail("OPN_URL은 credential 없는 https URL이어야 한다.")
    if not values.get("OPN_KEY") or not values.get("OPN_SECRET"):
        fail("OPN_KEY와 OPN_SECRET이 필요하다.")
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
        if not path.startswith("/api/"):
            fail("허용되지 않은 OPNsense API path다.")
        data = None
        headers = {"Authorization": "Basic " + self.auth}
        if payload is not None:
            data = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            self.base_url + path, data=data, headers=headers, method=method
        )
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
    response = client.call("POST", "/api/firewall/alias/search_item", {})
    return [row for row in response.get("rows", []) if row.get("name") == ALIAS_NAME]


def rule_rows(client):
    response = client.call("GET", "/api/firewall/filter/search_rule?interface=opt2&show_all=1")
    return [row for row in response.get("rows", []) if row.get("description") == RULE_DESCRIPTION]


def validate_alias(rows):
    if len(rows) != 1:
        fail("Slack FQDN alias 개수가 정확히 하나가 아니다.")
    row = rows[0]
    expected = {
        "enabled": "1",
        "name": ALIAS_NAME,
        "type": "host",
        "content": ALIAS_CONTENT,
        "description": ALIAS_DESCRIPTION,
    }
    if any(row.get(key) != value for key, value in expected.items()):
        fail("Slack FQDN alias 의미값이 계획과 다르다.")


def validate_rule(rows, enabled):
    if len(rows) != 1:
        fail("Slack egress rule 개수가 정확히 하나가 아니다.")
    row = rows[0]
    expected = {
        "enabled": enabled,
        "sequence": RULE_SEQUENCE,
        "action": "pass",
        "quick": "1",
        "interface": "opt2",
        "direction": "in",
        "ipprotocol": "inet",
        "protocol": "TCP",
        "source_net": EGRESS_SOURCE,
        "source_port": "",
        "destination_net": ALIAS_NAME,
        "destination_port": "443",
        "log": "1",
        "description": RULE_DESCRIPTION,
    }
    if any(row.get(key) != value for key, value in expected.items()):
        fail(f"Slack egress rule 의미값이 계획과 다르다: enabled={enabled}")


def runtime_rule(client, uuid):
    response = client.call("GET", "/api/firewall/filter_util/rule_stats")
    try:
        loaded = int(response["stats"][uuid]["pf_rules"])
    except (KeyError, TypeError, ValueError):
        loaded = 0
    if response.get("status") != "ok" or loaded < 1:
        fail("PF runtime에 OBS-18 Slack rule이 없다.")


def empty_owned(client):
    if alias_rows(client):
        fail("같은 이름의 OBS-18 Slack alias가 이미 있다.")
    if rule_rows(client):
        fail("같은 description의 OBS-18 Slack rule이 이미 있다.")
    all_rules = client.call("GET", "/api/firewall/filter/search_rule?interface=opt2&show_all=1").get("rows", [])
    if any(row.get("sequence") == RULE_SEQUENCE for row in all_rules):
        fail(f"opt2 sequence {RULE_SEQUENCE}을 이미 다른 rule이 사용한다.")


def create_state_dir():
    STATE_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    state = pathlib.Path(tempfile.mkdtemp(prefix="obs-18-", dir=STATE_ROOT))
    os.chmod(state, 0o700)
    for name in ("alias-uuid", "rule-uuid"):
        target = state / name
        target.touch(mode=0o600)
        os.chmod(target, 0o600)
    return state


def rollback_created(client, alias_uuid, rule_uuid):
    if rule_uuid and UUID_PATTERN.fullmatch(rule_uuid):
        try:
            client.call("POST", f"/api/firewall/filter/toggle_rule/{rule_uuid}/0")
            client.call("POST", "/api/firewall/filter/apply")
            client.call("POST", f"/api/firewall/filter/del_rule/{rule_uuid}")
            client.call("POST", "/api/firewall/filter/apply")
        except Failure:
            pass
    if alias_uuid and UUID_PATTERN.fullmatch(alias_uuid):
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
        empty_owned(client)
        state = create_state_dir()
        alias_uuid = ""
        rule_uuid = ""
        print(f"복구 지점={state}")
        try:
            response = client.call(
                "POST",
                "/api/firewall/alias/add_item",
                {
                    "alias": {
                        "enabled": "1",
                        "name": ALIAS_NAME,
                        "type": "host",
                        "content": ALIAS_CONTENT,
                        "description": ALIAS_DESCRIPTION,
                    }
                },
            )
            alias_uuid = checked_uuid(response.get("uuid"), "Slack FQDN alias")
            (state / "alias-uuid").write_text(alias_uuid + "\n", encoding="ascii")
            client.call("POST", "/api/firewall/alias/reconfigure")
            validate_alias(alias_rows(client))
            print(f"AliasApply=PASS name={ALIAS_NAME} uuid={alias_uuid}")

            response = client.call(
                "POST",
                "/api/firewall/filter/add_rule",
                {
                    "rule": {
                        "enabled": "0",
                        "statetype": "keep",
                        "sequence": RULE_SEQUENCE,
                        "action": "pass",
                        "quick": "1",
                        "interface": "opt2",
                        "direction": "in",
                        "ipprotocol": "inet",
                        "protocol": "TCP",
                        "source_net": EGRESS_SOURCE,
                        "source_port": "",
                        "destination_net": ALIAS_NAME,
                        "destination_port": "443",
                        "gateway": "",
                        "log": "1",
                        "description": RULE_DESCRIPTION,
                    }
                },
            )
            rule_uuid = checked_uuid(response.get("uuid"), "Slack egress rule")
            (state / "rule-uuid").write_text(rule_uuid + "\n", encoding="ascii")
            validate_rule(rule_rows(client), "0")
            print(f"FirewallStage=PASS uuid={rule_uuid} sequence={RULE_SEQUENCE} enabled=0")

            client.call("POST", f"/api/firewall/filter/toggle_rule/{rule_uuid}/1")
            client.call("POST", "/api/firewall/filter/apply")
            validate_rule(rule_rows(client), "1")
            runtime_rule(client, rule_uuid)
            print(f"FirewallApply=PASS uuid={rule_uuid} sequence={RULE_SEQUENCE}")
        except Exception:
            rollback_created(client, alias_uuid, rule_uuid)
            raise
        print(f"STATE_DIR={state}")


def rollback(client, state):
    resolved = state.resolve()
    if resolved.parent != STATE_ROOT or not resolved.name.startswith("obs-18-") or state.is_symlink():
        fail("명시적인 OBS-18 복구 지점이 필요하다.")
    alias_uuid = checked_uuid((resolved / "alias-uuid").read_text(encoding="ascii").strip(), "alias")
    rule_uuid = checked_uuid((resolved / "rule-uuid").read_text(encoding="ascii").strip(), "rule")
    with open("/tmp/ktcloud4-bean-opnsense-live.lock", "w", encoding="utf-8") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if any(row.get("uuid") == rule_uuid for row in rule_rows(client)):
            client.call("POST", f"/api/firewall/filter/toggle_rule/{rule_uuid}/0")
            client.call("POST", "/api/firewall/filter/apply")
            client.call("POST", f"/api/firewall/filter/del_rule/{rule_uuid}")
            client.call("POST", "/api/firewall/filter/apply")
            print(f"FirewallRollback=PASS removed_uuid={rule_uuid}")
        if any(row.get("uuid") == alias_uuid for row in alias_rows(client)):
            client.call("POST", f"/api/firewall/alias/del_item/{alias_uuid}")
            client.call("POST", "/api/firewall/alias/reconfigure")
            print(f"AliasRollback=PASS removed_uuid={alias_uuid}")
        if rule_rows(client) or alias_rows(client):
            fail("rollback 뒤 OBS-18 Slack rule 또는 alias가 남아 있다.")
        print(f"RollbackReference={resolved}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("apply", "rollback"))
    parser.add_argument("state_dir", nargs="?")
    args = parser.parse_args()
    repo_root = pathlib.Path(__file__).resolve().parents[3]
    secret_root = pathlib.Path(os.environ.get("KTC_SECRET_ROOT", "/home/imcherry/secrets/ktcloud4-bean"))
    env_file = pathlib.Path(os.environ.get("OBS18_OPN_ENV_FILE", secret_root / "opnsense/env"))
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
