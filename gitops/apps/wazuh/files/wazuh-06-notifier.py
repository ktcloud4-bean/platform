"""WAZUH-06 security notifier relay.

`wazuh` 네임스페이스에서 유일하게 외부 TCP 443으로 나가는 Pod다. wazuh-manager의
custom-wazuh06 integration이 in-cluster로 보낸 allowlist payload만 받아
`#security-alerts` Slack Incoming Webhook으로 한 번 보낸다.

경계:
- Slack webhook 원문은 Vault Agent가 memory emptyDir에 렌더한 파일에서만 읽고
  로그·응답·stdout 어디에도 출력하지 않는다.
- payload는 ALLOWED_FIELDS 밖의 key를 전부 버린다. manager 쪽 custom-wazuh06이
  이미 한 번 걸렀지만 같은 allowlist를 여기서 다시 강제한다(defense in depth).
  raw log·IP·사용자명·token·request body·full label은 어느 쪽에서도 통과하지 못한다.
- 보안 이벤트는 상태 경보가 아니므로 resolved 통지를 만들지 않는다. 이 relay는
  단방향이며 어떤 상태도 저장하지 않는다.
- webhook host는 EXPECTED_HOST로 고정 검증한다. Vault 값이 다른 host를 가리키면
  전송하지 않고 실패한다 — NetworkPolicy의 TCP 443이 목적지 host까지 좁히지는
  못하므로 이 검증이 실제 목적지 제한을 담당한다.
"""

import json
import logging
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOOK_FILE = os.environ.get("WAZUH06_HOOK_FILE", "/vault/secrets/slack-webhook-url")
LISTEN_PORT = int(os.environ.get("WAZUH06_LISTEN_PORT", "8080"))
ALERT_PATH = "/alert"
HEALTH_PATH = "/healthz"

EXPECTED_HOST = "hooks.slack.com"
EXPECTED_PATH_PREFIX = "/services/"

MIN_LEVEL = 14
MAX_BODY_BYTES = 8192
SLACK_TIMEOUT = 10

# manager 쪽 custom-wazuh06이 보내도 되는 필드의 유일한 원본. 값 타입까지 고정해
# dict/list가 통째로 실려 오는 경로를 막는다.
ALLOWED_FIELDS = {
    "level": int,
    "rule_id": str,
    "rule_description": str,
    "rule_groups": list,
    "agent_name": str,
    "agent_id": str,
    "timestamp": str,
    "test": bool,
}

MAX_TEXT_LEN = 300
MAX_GROUPS = 12

DASHBOARD_URL = "https://wazuh.imcherry5778.xyz/"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s wazuh-06-notifier %(levelname)s %(message)s",
    stream=sys.stdout,
)
log = logging.getLogger("wazuh-06-notifier")


def load_hook():
    """Vault Agent가 렌더한 webhook을 읽고 host/경로를 고정 검증한다."""
    with open(HOOK_FILE, encoding="utf-8") as handle:
        hook = handle.read().strip()
    parsed = urllib.parse.urlsplit(hook)
    if (
        parsed.scheme != "https"
        or parsed.hostname != EXPECTED_HOST
        or parsed.port not in (None, 443)
        or not parsed.path.startswith(EXPECTED_PATH_PREFIX)
        or parsed.query
        or parsed.fragment
    ):
        # 값 자체는 절대 남기지 않는다.
        raise ValueError("webhook URL이 예상한 Slack Incoming Webhook 형식이 아니다")
    return hook


def clean_text(value):
    """제어문자를 없애고 길이를 자른다. Slack 마크업 주입도 함께 막는다."""
    text = "".join(ch for ch in str(value) if ch.isprintable())
    text = text.replace("<", "").replace(">", "").replace("@", "")
    return text[:MAX_TEXT_LEN]


def sanitize(payload):
    """ALLOWED_FIELDS만 남기고 나머지는 조용히 버린다."""
    if not isinstance(payload, dict):
        raise ValueError("payload가 object가 아니다")

    clean = {}
    for name, want in ALLOWED_FIELDS.items():
        value = payload.get(name)
        if value is None:
            continue
        if want is int and isinstance(value, bool):
            continue
        if not isinstance(value, want):
            continue
        if want is list:
            clean[name] = [clean_text(item) for item in value[:MAX_GROUPS]]
        elif want is str:
            clean[name] = clean_text(value)
        else:
            clean[name] = value

    level = clean.get("level")
    if not isinstance(level, int) or level < MIN_LEVEL:
        raise ValueError("level이 없거나 통지 기준(%d) 미만이다" % MIN_LEVEL)
    if not clean.get("rule_id"):
        raise ValueError("rule_id가 없다")
    return clean


def slack_message(alert):
    """Slack에 보낼 최종 본문. allowlist된 값만 문자열로 조립한다."""
    prefix = "[TEST]" if alert.get("test") else ""
    header = "%s[SECURITY][CRITICAL] @channel" % prefix

    lines = [
        header,
        "rule %s (level %d): %s"
        % (
            alert["rule_id"],
            alert["level"],
            alert.get("rule_description", "N/A"),
        ),
    ]
    if alert.get("rule_groups"):
        lines.append("group: %s" % ", ".join(alert["rule_groups"]))
    if alert.get("agent_name"):
        agent = alert["agent_name"]
        if alert.get("agent_id"):
            agent = "%s (id %s)" % (agent, alert["agent_id"])
        lines.append("agent: %s" % agent)
    if alert.get("timestamp"):
        lines.append("time: %s" % alert["timestamp"])
    lines.append("dashboard: %s" % DASHBOARD_URL)

    return {"text": "\n".join(lines), "link_names": True}


def post_to_slack(message):
    body = json.dumps(message, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        load_hook(),
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    context = ssl.create_default_context()
    with urllib.request.urlopen(request, timeout=SLACK_TIMEOUT, context=context) as response:
        return response.status


class Handler(BaseHTTPRequestHandler):
    server_version = "wazuh-06-notifier"
    sys_version = ""

    def log_message(self, fmt, *args):
        """기본 access log는 끈다 — 경로·payload를 남기지 않는다."""

    def _reply(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        if self.path == HEALTH_PATH:
            self._reply(200)
        else:
            self._reply(404)

    def do_POST(self):
        if self.path != ALERT_PATH:
            self._reply(404)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._reply(400)
            return
        if length <= 0 or length > MAX_BODY_BYTES:
            self._reply(413)
            return

        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
            alert = sanitize(payload)
        except (ValueError, UnicodeDecodeError) as error:
            # 사유만 남기고 payload는 남기지 않는다.
            log.warning("payload 거부: %s", error)
            self._reply(400)
            return

        try:
            status = post_to_slack(slack_message(alert))
        except (OSError, ValueError, urllib.error.HTTPError) as error:
            log.error(
                "Slack 전송 실패 rule=%s level=%s: %s",
                alert["rule_id"],
                alert["level"],
                type(error).__name__,
            )
            self._reply(502)
            return

        log.info(
            "Slack 전송 완료 rule=%s level=%s test=%s status=%s",
            alert["rule_id"],
            alert["level"],
            bool(alert.get("test")),
            status,
        )
        self._reply(204)


def main():
    # 기동 시점에 webhook 형식을 한 번 검증해, 잘못된 값이면 첫 경보가 아니라
    # 여기서 즉시 실패한다.
    load_hook()
    log.info("listening on :%d (level>=%d only)", LISTEN_PORT, MIN_LEVEL)
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
