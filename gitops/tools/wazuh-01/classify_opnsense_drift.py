#!/usr/bin/env python3
"""WAZUH-01-FIX-01 exact-diff gate.

check-drift.sh --update를 호출하기 전에, 정규화한 live config와 커밋된 스냅샷의
unified diff(-u0)를 hunk 단위로 승인 목록과 대조한다. 승인하는 변경은 셋뿐이다.

  1) <firmware>의 <plugins> 목록에 os-wazuh-agent 하나만 추가
  2) <IDS ...>의 persisted_at만 변경 (version·description은 동일)
  3) <WazuhAgent> subtree 신규 추가, 필드 값이 apply-opnsense.sh 선언과 정확히 일치
     (password는 normalize.py가 마스킹한 ***MASKED*** 고정값이어야 한다)

그 밖의 hunk가 하나라도 있으면 거부한다. 이 모듈은 라이브를 읽거나 쓰지 않고
순수하게 주어진 diff 텍스트만 분류한다.
"""
from __future__ import annotations

import re
import sys

_HUNK_START = re.compile(r"^(?=@@)", re.M)


def _split_hunks(diff_text: str) -> list[str]:
    return [h for h in _HUNK_START.split(diff_text) if h.startswith("@@")]


def _plus_minus(hunk: str) -> tuple[list[str], list[str]]:
    lines = hunk.splitlines()[1:]
    plus = [line for line in lines if line.startswith("+") and not line.startswith("+++")]
    minus = [line for line in lines if line.startswith("-") and not line.startswith("---")]
    return plus, minus


def _is_plugins_addition(plus: list[str], minus: list[str]) -> bool:
    if len(plus) != 1 or len(minus) != 1:
        return False
    m_old = re.match(r"^-\s*<plugins>([^<]*)</plugins>\s*$", minus[0])
    m_new = re.match(r"^\+\s*<plugins>([^<]*)</plugins>\s*$", plus[0])
    if not (m_old and m_new):
        return False
    old_set = {x for x in m_old.group(1).split(",") if x}
    new_set = {x for x in m_new.group(1).split(",") if x}
    return new_set - old_set == {"os-wazuh-agent"} and old_set - new_set == set()


def _is_ids_persisted_at_only(plus: list[str], minus: list[str]) -> bool:
    if len(plus) != 1 or len(minus) != 1:
        return False
    pattern = r'^[+-]\s*<IDS version="([^"]*)" persisted_at="[^"]*" description="([^"]*)">\s*$'
    m_old = re.match(pattern, minus[0])
    m_new = re.match(pattern, plus[0])
    if not (m_old and m_new):
        return False
    return m_old.group(1) == m_new.group(1) and m_old.group(2) == m_new.group(2)


def wazuhagent_expected_body(
    *, agent_name: str, manager_address: str, events_port: str, auth_port: str
) -> list[str]:
    """apply-opnsense.sh가 저장하는 필드의 정확한 순서.

    set 기반 멤버십 검사는 위치를 무시하므로 예를 들어 `<active_response>`의
    `<enabled>`를 `1`로 조작해도 `<general>`의 `<enabled>1</enabled>`와 문자열이
    같아 통과한다. 순서가 고정된 목록과 완전 일치만 승인해 이 구멍을 막는다.
    """
    return [
        "+      <general>",
        "+        <enabled>1</enabled>",
        f"+        <server_address>{manager_address}</server_address>",
        f"+        <agent_name>{agent_name}</agent_name>",
        "+        <protocol>tcp</protocol>",
        f"+        <port>{events_port}</port>",
        "+        <debug_level>0</debug_level>",
        "+      </general>",
        "+      <auth>",
        "+        <password>***MASKED***</password>",
        f"+        <port>{auth_port}</port>",
        "+      </auth>",
        "+      <logcollector>",
        "+        <remote_commands>0</remote_commands>",
        "+        <syslog_programs />",
        "+        <suricata_eve_log>1</suricata_eve_log>",
        "+      </logcollector>",
        "+      <rootcheck>",
        "+        <enabled>0</enabled>",
        "+      </rootcheck>",
        "+      <syscollector>",
        "+        <enabled>0</enabled>",
        "+      </syscollector>",
        "+      <syscheck>",
        "+        <enabled>0</enabled>",
        "+      </syscheck>",
        "+      <active_response>",
        "+        <enabled>0</enabled>",
        "+        <remote_commands>0</remote_commands>",
        "+        <fw_alias_ignore />",
        "+        <repeated_offenders />",
        "+      </active_response>",
        "+    </WazuhAgent>",
    ]


def _is_wazuhagent_addition(plus: list[str], minus: list[str], expected_body: list[str]) -> bool:
    if minus or not plus:
        return False
    header = re.match(
        r'^\+\s*<WazuhAgent version="[^"]*" persisted_at="[^"]*" description="Wazuh Agent">\s*$',
        plus[0],
    )
    if not header:
        return False
    return plus[1:] == expected_body


def classify(
    diff_text: str,
    *,
    agent_name: str,
    manager_address: str,
    events_port: str,
    auth_port: str,
) -> tuple[bool, list[str]]:
    """승인된 drift만 있으면 (True, [])를, 아니면 (False, 거부된 hunk 목록)을 반환한다."""
    expected_wazuhagent_body = wazuhagent_expected_body(
        agent_name=agent_name,
        manager_address=manager_address,
        events_port=events_port,
        auth_port=auth_port,
    )
    bad: list[str] = []
    for hunk in _split_hunks(diff_text):
        plus, minus = _plus_minus(hunk)
        if _is_plugins_addition(plus, minus):
            continue
        if _is_ids_persisted_at_only(plus, minus):
            continue
        if _is_wazuhagent_addition(plus, minus, expected_wazuhagent_body):
            continue
        bad.append(hunk)
    return (not bad, bad)


def main(argv: list[str]) -> int:
    if len(argv) != 6:
        print(
            "사용법: classify_opnsense_drift.py <diff-file> <agent_name> "
            "<manager_address> <events_port> <auth_port>",
            file=sys.stderr,
        )
        return 2
    diff_path, agent_name, manager_address, events_port, auth_port = argv[1:]
    with open(diff_path, encoding="utf-8") as fh:
        diff_text = fh.read()
    ok, bad = classify(
        diff_text,
        agent_name=agent_name,
        manager_address=manager_address,
        events_port=events_port,
        auth_port=auth_port,
    )
    if ok:
        print("ExactDiffGate=PASS 승인된 WazuhAgent 추가와 IDS persisted_at 차이만 확인됨.")
        return 0
    print("ExactDiffGate=FAIL 승인 범위 밖 drift 감지:", file=sys.stderr)
    print("\n".join(bad), file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
