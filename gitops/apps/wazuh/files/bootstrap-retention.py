#!/usr/bin/env python3
"""WAZUH-01 보존 정책 bootstrap.

docs/audit-event-standard.md의 D30·A90을 Wazuh indexer running 설정으로 만든다.
- D30: 탐지 alert index `wazuh-alerts-4.x-*`를 30일 뒤 삭제한다.
- A90: Kubernetes API audit index `wazuh-alerts-4.x-audit-*`를 90일 뒤 삭제한다.

두 pattern은 겹치므로 A90 ism_template priority를 높여 audit index가 A90만 받게 한다.
admin client certificate로만 인증하며 password는 읽지도 출력하지도 않는다.
"""

import json
import ssl
import sys
import time
import urllib.error
import urllib.request

INDEXER_URL = "https://indexer.wazuh.svc.cluster.local:9200"
CA_FILE = "/vault/secrets/root-ca.pem"
CERT_FILE = "/vault/secrets/admin.pem"
KEY_FILE = "/vault/secrets/admin-key.pem"
READY_DEADLINE_SECONDS = 600

POLICIES = {
    "wazuh-01-d30": {
        "policy": {
            "description": "WAZUH-01 D30 detection retention (30 days)",
            "default_state": "retain",
            "states": [
                {
                    "name": "retain",
                    "actions": [],
                    "transitions": [
                        {"state_name": "delete", "conditions": {"min_index_age": "30d"}}
                    ],
                },
                {"name": "delete", "actions": [{"delete": {}}], "transitions": []},
            ],
            "ism_template": [
                {"index_patterns": ["wazuh-alerts-4.x-*"], "priority": 1}
            ],
        }
    },
    "wazuh-01-a90": {
        "policy": {
            "description": "WAZUH-01 A90 audit metadata retention (90 days)",
            "default_state": "retain",
            "states": [
                {
                    "name": "retain",
                    "actions": [],
                    "transitions": [
                        {"state_name": "delete", "conditions": {"min_index_age": "90d"}}
                    ],
                },
                {"name": "delete", "actions": [{"delete": {}}], "transitions": []},
            ],
            "ism_template": [
                {"index_patterns": ["wazuh-alerts-4.x-audit-*"], "priority": 100}
            ],
        }
    },
}


def build_context() -> ssl.SSLContext:
    context = ssl.create_default_context(cafile=CA_FILE)
    context.load_cert_chain(certfile=CERT_FILE, keyfile=KEY_FILE)
    context.check_hostname = True
    context.verify_mode = ssl.CERT_REQUIRED
    return context


def request(context, method, path, payload=None):
    body = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(f"{INDEXER_URL}{path}", data=body, method=method)
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, context=context, timeout=30) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        raw = error.read() or b"{}"
        try:
            return error.code, json.loads(raw)
        except json.JSONDecodeError:
            return error.code, {}


def wait_for_indexer(context) -> None:
    deadline = time.monotonic() + READY_DEADLINE_SECONDS
    last = "no attempt"
    while time.monotonic() < deadline:
        try:
            status, payload = request(
                context, "GET", "/_cluster/health?wait_for_status=yellow&timeout=20s"
            )
            if status == 200 and payload.get("status") in ("yellow", "green"):
                print(f"IndexerHealth={payload['status']}", flush=True)
                return
            last = f"status={status} payload={payload.get('status')}"
        except (urllib.error.URLError, ssl.SSLError, OSError) as error:
            # 실패 원인을 남긴다. credential은 이 경로에 오지 않는다.
            last = f"{type(error).__name__}: {error}"
            print(f"IndexerWait={last}", flush=True)
        time.sleep(5)
    raise SystemExit(f"bootstrap 실패 단계=indexer-ready 원인={last}")


def put_policy(context, policy_id, document) -> str:
    status, payload = request(
        context, "PUT", f"/_plugins/_ism/policies/{policy_id}", document
    )
    if status in (200, 201):
        return "created"
    if status != 409:
        raise SystemExit(
            f"bootstrap 실패 단계=policy-put id={policy_id} 원인=status {status}"
        )

    status, existing = request(context, "GET", f"/_plugins/_ism/policies/{policy_id}")
    if status != 200:
        raise SystemExit(
            f"bootstrap 실패 단계=policy-get id={policy_id} 원인=status {status}"
        )
    seq_no = existing.get("_seq_no")
    primary_term = existing.get("_primary_term")
    if seq_no is None or primary_term is None:
        raise SystemExit(
            f"bootstrap 실패 단계=policy-get id={policy_id} 원인=seq_no/primary_term 없음"
        )
    status, _ = request(
        context,
        "PUT",
        f"/_plugins/_ism/policies/{policy_id}"
        f"?if_seq_no={seq_no}&if_primary_term={primary_term}",
        document,
    )
    if status not in (200, 201):
        raise SystemExit(
            f"bootstrap 실패 단계=policy-update id={policy_id} 원인=status {status}"
        )
    return "updated"


def main() -> int:
    context = build_context()
    wait_for_indexer(context)
    for policy_id, document in POLICIES.items():
        outcome = put_policy(context, policy_id, document)
        age = document["policy"]["states"][0]["transitions"][0]["conditions"][
            "min_index_age"
        ]
        print(f"Policy={policy_id} outcome={outcome} min_index_age={age}", flush=True)

    for policy_id in POLICIES:
        status, payload = request(
            context, "GET", f"/_plugins/_ism/policies/{policy_id}"
        )
        if status != 200 or payload.get("_id") != policy_id:
            raise SystemExit(
                f"bootstrap 실패 단계=policy-verify id={policy_id} 원인=status {status}"
            )
    print("WAZUH01_BOOTSTRAP=PASS", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
