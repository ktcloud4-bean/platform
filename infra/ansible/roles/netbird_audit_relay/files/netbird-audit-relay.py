#!/usr/bin/env python3
"""WAZUH-05: NetBird events.db를 read-only polling해 새 row만 JSON 한 줄씩 append한다.

docs/audit-event-standard.md 4절 소스별 표에 따라 "account·user·peer·policy·
setup-key 변경과 접근 event"만 다루고, setup key/token 값·geo/city·사용자
email·표시명은 여기서 제거한다(6절). 마스킹은 allowlist 방식이다 — meta의
알려진 안전 필드만 통과시키고 새로 생기는 필드는 기본적으로 버린다.

이 스크립트는 events.db를 URI read-only 모드로만 연다(쓰지 않는다). 상태
파일(마지막 처리 row id)은 tmp에 쓴 뒤 rename으로 원자적으로 갱신해 중간에
죽어도 이미 쓴 row를 잃어버리거나 중복 처리하지 않는다(재시작 후 이어 읽기).
"""
import json
import os
import re
import sqlite3
import sys

DB_PATH = "/var/lib/netbird/events.db"
STATE_PATH = "/var/lib/wazuh-05-netbird-relay/last-event-id"
OUTPUT_PATH = "/var/lib/wazuh-05-netbird-relay/netbird-audit.log"
MAX_BYTES = 20 * 1024 * 1024

# NetBird management/server/activity/codes.go의 activityMap을 그대로 옮긴 것.
# 값이 바뀌면(업스트림이 activity code를 재배정하면) 안전 쪽으로 실패하도록
# 모르는 activity는 무조건 건너뛴다(아래 ACTIVITY_BUCKET에 없으면 버림).
ACTIVITY_CODE = {
    0: "peer.user.add", 1: "peer.setupkey.add", 2: "user.join", 3: "user.invite",
    4: "account.create", 99999: "account.delete", 5: "user.peer.delete",
    6: "rule.add", 7: "rule.update", 8: "rule.delete",
    9: "policy.add", 10: "policy.update", 11: "policy.delete",
    12: "setupkey.add", 13: "setupkey.update", 14: "setupkey.revoke", 15: "setupkey.overuse",
    16: "group.add", 17: "group.update", 18: "peer.group.add", 19: "peer.group.delete",
    20: "user.group.add", 21: "user.group.delete", 22: "user.role.update",
    23: "setupkey.group.add", 24: "setupkey.group.delete",
    25: "dns.setting.disabled.management.group.add", 26: "dns.setting.disabled.management.group.delete",
    30: "peer.ssh.enable", 31: "peer.ssh.disable", 32: "peer.rename",
    33: "peer.login.expiration.enable", 34: "peer.login.expiration.disable",
    38: "account.setting.peer.login.expiration.enable",
    39: "account.setting.peer.login.expiration.disable",
    40: "account.setting.peer.login.expiration.update",
    43: "service.user.create", 44: "service.user.delete",
    45: "user.block", 46: "user.unblock", 47: "user.delete", 48: "group.delete",
    49: "user.peer.login", 50: "peer.login.expire", 51: "dashboard.login",
    55: "account.setting.peer.approval.enable", 56: "account.setting.peer.approval.disable",
    57: "peer.approve", 58: "peer.approval.revoke", 59: "transferred.owner.role",
    63: "peer.inactivity.expiration.enable", 64: "peer.inactivity.expiration.disable",
    65: "account.peer.inactivity.expiration.enable", 66: "account.peer.inactivity.expiration.disable",
    67: "account.peer.inactivity.expiration.update", 68: "setupkey.delete",
    69: "account.setting.group.propagation.enable", 70: "account.setting.group.propagation.disable",
    85: "account.setting.lazy.connection.enable", 86: "account.setting.lazy.connection.disable",
    87: "account.network.range.update", 88: "peer.ip.update",
    89: "user.approve", 90: "user.reject", 91: "user.create",
    103: "user.password.change",
    104: "user.invite.link.create", 105: "user.invite.link.accept",
    106: "user.invite.link.regenerate", 107: "user.invite.link.delete",
    116: "account.setting.auto.update.always.enable", 117: "account.setting.auto.update.always.disable",
    121: "account.setting.ipv6.enable", 122: "account.setting.ipv6.disable",
    123: "account.setting.local.mfa.enable", 124: "account.setting.local.mfa.disable",
    125: "user.peer.session.extend",
}

# docs/audit-event-standard.md 4절: "account·user·peer·policy·setup-key 변경과
# 접근 event"만 A90으로 보낸다. route·nameserver·network·service·integration·
# posture check·DNS zone·identity provider·domain·agent_network·personal
# access token은 이 소스의 범위 밖이라 activity 코드가 있어도 버킷에 없으면
# 전송하지 않는다. group.*은 NetBird에서 policy가 사용자/피어를 직접이 아니라
# group으로 지정하는 구조라 policy 변경과 같은 버킷(정책 대상 변경)으로 묶는다.
ACTIVITY_BUCKET = {}
for code in (
    "account.create", "account.delete", "account.setting.peer.login.expiration.enable",
    "account.setting.peer.login.expiration.disable", "account.setting.peer.login.expiration.update",
    "account.setting.peer.approval.enable", "account.setting.peer.approval.disable",
    "account.peer.inactivity.expiration.enable", "account.peer.inactivity.expiration.disable",
    "account.peer.inactivity.expiration.update", "account.setting.group.propagation.enable",
    "account.setting.group.propagation.disable", "account.setting.lazy.connection.enable",
    "account.setting.lazy.connection.disable", "account.network.range.update",
    "account.setting.auto.update.always.enable", "account.setting.auto.update.always.disable",
    "account.setting.ipv6.enable", "account.setting.ipv6.disable",
    "account.setting.local.mfa.enable", "account.setting.local.mfa.disable",
    "user.join", "user.invite", "user.peer.delete", "user.role.update", "user.block",
    "user.unblock", "user.delete", "user.approve", "user.reject", "user.create",
    "user.password.change", "user.invite.link.create", "user.invite.link.accept",
    "user.invite.link.regenerate", "user.invite.link.delete", "transferred.owner.role",
    "service.user.create", "service.user.delete",
    "peer.user.add", "peer.setupkey.add", "peer.ssh.enable", "peer.ssh.disable",
    "peer.rename", "peer.login.expiration.enable", "peer.login.expiration.disable",
    "peer.approve", "peer.approval.revoke", "peer.ip.update",
    "peer.inactivity.expiration.enable", "peer.inactivity.expiration.disable",
    "user.peer.login", "peer.login.expire", "dashboard.login", "user.peer.session.extend",
):
    ACTIVITY_BUCKET[code] = "account_access"
for code in (
    "rule.add", "rule.update", "rule.delete", "policy.add", "policy.update", "policy.delete",
    "setupkey.add", "setupkey.update", "setupkey.revoke", "setupkey.overuse", "setupkey.delete",
    "group.add", "group.update", "group.delete", "peer.group.add", "peer.group.delete",
    "user.group.add", "user.group.delete", "setupkey.group.add", "setupkey.group.delete",
    "dns.setting.disabled.management.group.add", "dns.setting.disabled.management.group.delete",
):
    ACTIVITY_BUCKET[code] = "policy_setupkey"

# meta의 allowlist. 여기 없는 key는 무조건 버린다(6절: setup key/token 값·
# geo/city·이메일·표시명 제거 — key는 실제 NetBird setup key 값이라 항상 제거).
META_ALLOWLIST = {
    "name", "fqdn", "ip", "ipv6", "group", "group_id", "type",
    "is_service_user", "pending_approval", "created_at",
}


def load_last_id():
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as f:
            return int(f.read().strip() or "0")
    except FileNotFoundError:
        return 0


def save_last_id(event_id):
    tmp_path = STATE_PATH + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(str(event_id))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp_path, STATE_PATH)


def mask_meta(raw_meta):
    try:
        meta = json.loads(raw_meta) if raw_meta else {}
    except (TypeError, ValueError):
        return {}
    if not isinstance(meta, dict):
        return {}
    return {k: v for k, v in meta.items() if k in META_ALLOWLIST}


SQLITE_TS_RE = re.compile(
    r"^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})(\.\d+)?([+-]\d{2}:\d{2})?$"
)


def to_iso8601(sqlite_timestamp):
    """"YYYY-MM-DD HH:MM:SS.nnnnnnnnn+00:00"(SQLite, 공백 구분자·나노초)를
    "YYYY-MM-DDTHH:MM:SS.nnnnnn+00:00"(ISO 8601, 마이크로초까지)로 바꾼다.

    다른 WAZUH-04 소스가 이미 이 인덱스의 data.timestamp를 ISO 8601 date
    필드로 먼저 매핑해 뒀다 — 공백 구분자·나노초 원문을 그대로 보내면
    mapper_parsing_exception으로 문서 전체가 조용히 drop된다는 것을
    라이브로 확인했다(docs/backlog.md 참고). 필드 이름 자체도 event_time으로
    바꿔 그 기존 매핑과 아예 겹치지 않게 한다.
    """
    match = SQLITE_TS_RE.match(sqlite_timestamp)
    if not match:
        return sqlite_timestamp
    date, time, frac, offset = match.groups()
    frac = (frac or ".0")[:7]
    offset = offset or "+00:00"
    return f"{date}T{time}{frac}{offset}"


def rotate_if_needed():
    try:
        if os.path.getsize(OUTPUT_PATH) >= MAX_BYTES:
            os.replace(OUTPUT_PATH, OUTPUT_PATH + ".1")
    except FileNotFoundError:
        pass


def main():
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    last_id = load_last_id()

    conn = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        rows = conn.execute(
            "SELECT timestamp, activity, id, initiator_id, target_id, account_id, meta "
            "FROM events WHERE id > ? ORDER BY id ASC",
            (last_id,),
        ).fetchall()
    finally:
        conn.close()

    if not rows:
        return

    rotate_if_needed()
    written = 0
    with open(OUTPUT_PATH, "a", encoding="utf-8") as out:
        for row in rows:
            action = ACTIVITY_CODE.get(row["activity"])
            bucket = ACTIVITY_BUCKET.get(action) if action else None
            if bucket:
                event = {
                    "event_time": to_iso8601(row["timestamp"]),
                    "event_id": row["id"],
                    "action": action,
                    "bucket": bucket,
                    "initiator_id": row["initiator_id"],
                    "target_id": row["target_id"],
                    "account_id": row["account_id"],
                    "meta": mask_meta(row["meta"]),
                }
                out.write(json.dumps(event, ensure_ascii=True) + "\n")
                written += 1
        out.flush()
        os.fsync(out.fileno())

    save_last_id(rows[-1]["id"])
    print(f"polled={len(rows)} forwarded={written} last_id={rows[-1]['id']}", file=sys.stderr)


if __name__ == "__main__":
    main()
