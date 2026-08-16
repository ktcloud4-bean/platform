#!/usr/bin/env python3
"""DEMO-ONPREM-01 Wazuh 및 Shuffle 증거를 비밀·원문 없이 판정한다."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import importlib.util
import json
from pathlib import Path
import re
import shlex
import subprocess
import time


SSH = [
    "ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
    "-o", "UserKnownHostsFile=/home/imcherry/.ssh/known_hosts",
    "rocky@k3s-01.imcherry5778.xyz",
]


class SafeError(RuntimeError):
    pass


def load_soar(repo: Path):
    path = repo / "gitops/tools/soar-01/provision.py"
    spec = importlib.util.spec_from_file_location("demo_onprem_soar", path)
    if spec is None or spec.loader is None:
        raise SafeError("SOAR helper load failed")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def index_search(soar, query: str, since: str) -> dict:
    secret_dir = Path("/home/imcherry/secrets/ktcloud4-bean/wazuh")
    for name in ("root-ca.pem", "admin.pem", "admin-key.pem"):
        if not (secret_dir / name).is_file():
            raise SafeError(f"Wazuh protected input is absent: {name}")
    payload = json.dumps({
        "size": 100,
        "sort": [{"@timestamp": "desc"}],
        "_source": ["@timestamp", "rule.id", "data.path", "data.allow", "data.deny"],
        "query": {"bool": {"filter": [
            {"range": {"@timestamp": {"gte": since}}},
            {"query_string": {"query": query, "analyze_wildcard": False}},
        ]}},
    }, separators=(",", ":"))
    with soar.Tunnel("wazuh", "indexer", 9200, 19203) as base:
        url = base.replace("http://127.0.0.1:", "https://localhost:")
        result = subprocess.run([
            "curl", "-fsS", "--cacert", str(secret_dir / "root-ca.pem"),
            "--cert", str(secret_dir / "admin.pem"), "--key", str(secret_dir / "admin-key.pem"),
            "-H", "Content-Type: application/json", "-X", "POST", "--data", payload,
            f"{url}/wazuh-alerts-4.x-*/_search?ignore_unavailable=true",
        ], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False)
    if result.returncode:
        raise SafeError("Wazuh index query failed")
    try:
        response = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise SafeError("Wazuh index response is invalid") from error
    return response


def wait_hits(soar, query: str, since: str, minimum: int) -> list[dict]:
    for _ in range(36):
        response = index_search(soar, query, since)
        hits = response.get("hits", {}).get("hits", [])
        if isinstance(hits, list) and len(hits) >= minimum:
            return [hit for hit in hits if isinstance(hit, dict)]
        time.sleep(5)
    raise SafeError(f"Wazuh rule evidence did not reach minimum={minimum}")


def pomerium_path_evidence(since: str) -> None:
    command = shlex.join([
        "sudo", "-n", "/usr/local/bin/k3s", "kubectl", "-n", "pomerium", "logs",
        "deployment/pomerium", "-c", "pomerium", f"--since-time={since}",
    ])
    expected = {
        "/demo-onprem/account/control": ("allow", True),
        "/demo-onprem/account/restricted": ("allow", False),
    }
    diagnostic: dict[str, tuple[object, object]] = {}
    for _ in range(7):
        result = subprocess.run(
            [*SSH, command], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False,
        )
        if result.returncode:
            raise SafeError("Pomerium authorize log query failed")
        observed: set[str] = set()
        for line in result.stdout.splitlines():
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                continue
            path = item.get("path")
            if item.get("service") != "authorize" or not isinstance(path, str):
                continue
            if path.startswith("/demo-onprem/"):
                diagnostic[path] = (item.get("allow"), item.get("deny"))
            decision = expected.get(path)
            if decision and item.get(decision[0]) is decision[1]:
                observed.add(path)
        if observed == set(expected):
            return
        time.sleep(5)
    safe = ",".join(f"{path}:{allow}/{deny}" for path, (allow, deny) in sorted(diagnostic.items()))
    raise SafeError(f"Pomerium exact allow/deny path evidence is incomplete observed={safe or 'none'}")


def executions(value) -> list[dict]:
    if isinstance(value, list):
        return [item for item in value if isinstance(item, dict)]
    if isinstance(value, dict):
        for key in ("executions", "data", "items"):
            if isinstance(value.get(key), list):
                return [item for item in value[key] if isinstance(item, dict)]
    raise SafeError("Shuffle execution response shape is invalid")


def approval_result(execution: dict) -> tuple[str, bool] | None:
    results = execution.get("results")
    if not isinstance(results, list):
        return None
    for result in results:
        if not isinstance(result, dict):
            continue
        action = result.get("action") or {}
        if not isinstance(action, dict) or action.get("name") != "run_userinput":
            continue
        parsed = result.get("result")
        if isinstance(parsed, str):
            try:
                parsed = json.loads(parsed)
            except json.JSONDecodeError:
                parsed = {}
        if not isinstance(parsed, dict):
            parsed = {}
        click_info = parsed.get("click_info") or {}
        clicked = isinstance(click_info, dict) and click_info.get("clicked") is True
        return str(result.get("status", "")), clicked
    return None


def execution_rule_id(execution: dict) -> str:
    argument = execution.get("execution_argument")
    if not isinstance(argument, str):
        return ""
    try:
        payload = json.loads(argument)
    except json.JSONDecodeError:
        return ""
    if not isinstance(payload, dict):
        return ""
    return str(payload.get("rule_id", ""))


def live_no_automatic_response(workflow: dict) -> None:
    actions = workflow.get("actions") or []
    triggers = workflow.get("triggers") or []
    if len(actions) != 1 or actions[0].get("name") != "extract_indicators":
        raise SafeError("Shuffle workflow has an unexpected automatic action")
    kinds = sorted(str(item.get("trigger_type")) for item in triggers)
    if kinds != ["USERINPUT", "WEBHOOK"]:
        raise SafeError("Shuffle workflow trigger boundary drift")
    command = shlex.join([
        "sudo", "-n", "/usr/local/bin/k3s", "kubectl", "-n", "wazuh", "exec",
        "statefulset/wazuh-manager-master", "-c", "wazuh-manager", "--", "cat", "/var/ossec/etc/ossec.conf",
    ])
    result = subprocess.run([*SSH, command], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False)
    if result.returncode:
        raise SafeError("running Wazuh response boundary could not be read")
    config = re.sub(r"<!--.*?-->", "", result.stdout, flags=re.S)
    compact = re.sub(r">\s+<", "><", config)
    if "<active-response><disabled>yes</disabled></active-response>" not in compact or "<command>" in config:
        raise SafeError("running Wazuh automatic response boundary drift")


def wait_approval(soar) -> None:
    with soar.Tunnel("shuffle", "shuffle-backend", 5001, 18081) as base:
        admin = soar.ShuffleAdmin(base)
        admin.login()
        workflow = soar.owned_live_workflow(admin)
        if not workflow or not workflow.get("id"):
            raise SafeError("SOAR-01 live workflow is absent")
        live_no_automatic_response(workflow)
        waiting_printed = False
        for _ in range(180):
            raw = admin.request("GET", f"/api/v1/workflows/{workflow['id']}/executions")
            candidates = [item for item in executions(raw) if execution_rule_id(item) == "100123"]
            candidates.sort(key=lambda item: str(item.get("started_at") or item.get("start") or ""), reverse=True)
            if candidates:
                approval = approval_result(candidates[0])
                if approval == ("SUCCESS", True):
                    print("DEMO_SESSION3_APPROVAL=PASS workflow=SOAR-01 decision=ContinueOrStop clicked=true status=SUCCESS")
                    print("DEMO_SESSION3_AUTOMATIC_RESPONSE=PASS wazuh=disabled shuffle_response_actions=0")
                    return
            if not waiting_printed:
                print("DEMO_SESSION3_APPROVAL=WAITING url=https://shuffle.imcherry5778.xyz workflow=SOAR-01-Wazuh-read-only-approval", flush=True)
                waiting_printed = True
            time.sleep(5)
    raise SafeError("Shuffle human approval was not recorded within 15 minutes")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--session", type=int, choices=(1, 2, 3), required=True)
    parser.add_argument("--since", required=True)
    parser.add_argument("--wait-shuffle", action="store_true")
    args = parser.parse_args()
    # 입력 timestamp는 query에만 쓰고 출력하지 않는다.
    datetime.fromisoformat(args.since.replace("Z", "+00:00")).astimezone(timezone.utc)
    repo = Path(__file__).resolve().parents[3]
    soar = load_soar(repo)
    if args.session == 1:
        pomerium_path_evidence(args.since)
        wait_hits(soar, "rule.id:100102", args.since, 2)
        print("DEMO_SESSION1_EVIDENCE=PASS pomerium_paths=allow+not-allowed wazuh_rule=100102 authorize_hits>=2 identities=masked")
    elif args.session == 2:
        wait_hits(soar, "rule.id:100122", args.since, 1)
        print("DEMO_SESSION2_EVIDENCE=PASS crowdsec_block=present wazuh_rule=100122 request=masked")
    else:
        wait_hits(soar, "rule.id:100123", args.since, 2)
        print("DEMO_SESSION3_WAZUH=PASS wazuh_rule=100123 falco_parent=100121 events>=2")
        if args.wait_shuffle:
            wait_approval(soar)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"DEMO_EVIDENCE=FAIL reason={error}", file=__import__("sys").stderr)
        raise SystemExit(1)
