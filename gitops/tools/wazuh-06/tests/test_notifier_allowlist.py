#!/usr/bin/env python3
"""WAZUH-06 마스킹 경계 회귀 테스트.

Slack으로 나가는 본문에 raw log·IP·사용자명·token·request body·full label이
들어가지 않는지, level 경계와 webhook host 고정이 유지되는지 확인한다.
manager 쪽 custom-wazuh06과 notifier 쪽 sanitize를 실제 소스에서 그대로 로드해
같은 alert를 통과시킨다. 라이브 Wazuh·Slack·Vault를 호출하지 않는다.

이 테스트가 깨지면 allowlist가 넓어진 것이다. 필드를 늘리려면 여기와
gitops/apps/wazuh/README.md의 payload 표를 같은 변경에서 갱신한다.
"""
import importlib.util
import json
import pathlib
import tempfile
import unittest

FILES = pathlib.Path(__file__).resolve().parents[3] / "apps/wazuh/files"


def load_source(name, path):
    """확장자가 없는 integration 스크립트도 로드할 수 있게 직접 exec한다."""
    spec = importlib.util.spec_from_loader(name, loader=None)
    module = importlib.util.module_from_spec(spec)
    exec(compile(path.read_text(encoding="utf-8"), str(path), "exec"), module.__dict__)
    return module


integration = load_source("custom_wazuh06", FILES / "custom-wazuh06")
notifier = load_source("wazuh_06_notifier", FILES / "wazuh-06-notifier.py")

# 원문·식별자를 최대한 담은 현실적인 alert. 실제 sshd 실패 alert의 형태를 따른다.
ALERT = {
    "timestamp": "2026-08-13T17:40:00.123+0900",
    "id": "1755071999.123456",
    "full_log": (
        "Aug 13 17:40:00 k3s-01 sshd[2211]: Failed password for root "
        "from 203.0.113.9 port 51234 ssh2"
    ),
    "previous_output": "이전 원문 여러 줄",
    "agent": {"id": "004", "name": "k3s-01", "ip": "10.10.20.10"},
    "manager": {"name": "wazuh-manager-master-0"},
    "decoder": {"name": "sshd"},
    "location": "/var/log/secure",
    "data": {
        "srcip": "203.0.113.9",
        "dstuser": "root",
        "srcport": "51234",
        "token": "xoxb-super-secret",
    },
    "rule": {
        "level": 14,
        "id": "100129",
        "description": "WAZUH-06 temporary level 14 notification test",
        "groups": ["wazuh_d30", "wazuh_06_test"],
        "mitre": {"id": ["T1110"]},
    },
}

# 어느 단계에서도 나타나면 안 되는 문자열.
FORBIDDEN = (
    "203.0.113.9",
    "xoxb-super-secret",
    "/var/log/secure",
    "sshd",
    "Failed password",
    "51234",
    "10.10.20.10",
    "이전 원문",
    "T1110",
)


class ManagerSideAllowlist(unittest.TestCase):
    """manager를 떠나는 시점에 이미 원문이 없어야 한다."""

    def setUp(self):
        self.payload = integration.build(ALERT)
        self.serialized = json.dumps(self.payload, ensure_ascii=False)

    def test_keeps_only_declared_fields(self):
        self.assertEqual(
            set(self.payload),
            {
                "level",
                "rule_id",
                "rule_description",
                "rule_groups",
                "agent_name",
                "agent_id",
                "timestamp",
                "test",
            },
        )

    def test_sends_agent_alias_not_address(self):
        self.assertEqual(self.payload["agent_name"], "k3s-01")
        self.assertNotIn("agent_ip", self.payload)

    def test_marks_test_group(self):
        self.assertTrue(self.payload["test"])
        self.assertFalse(integration.build(
            dict(ALERT, rule=dict(ALERT["rule"], groups=["wazuh_d30"]))
        )["test"])

    def test_no_raw_material_leaves_manager(self):
        for needle in FORBIDDEN:
            with self.subTest(needle=needle):
                self.assertNotIn(needle, self.serialized)


class NotifierSanitize(unittest.TestCase):
    """manager가 오염된 payload를 보내더라도 notifier가 다시 거른다."""

    def test_drops_unknown_keys(self):
        polluted = dict(
            integration.build(ALERT),
            full_log="원문 로그",
            srcip="203.0.113.9",
            dstuser="root",
            extra={"nested": "값"},
        )
        clean = notifier.sanitize(polluted)
        self.assertLessEqual(set(clean), set(notifier.ALLOWED_FIELDS))
        for dropped in ("full_log", "srcip", "dstuser", "extra"):
            self.assertNotIn(dropped, clean)

    def test_rejects_wrong_types(self):
        clean = notifier.sanitize(
            dict(integration.build(ALERT), agent_name={"nested": "값"})
        )
        self.assertNotIn("agent_name", clean)

    def test_level_boundary(self):
        base = integration.build(ALERT)
        for level in (0, 7, 13):
            with self.subTest(level=level):
                with self.assertRaises(ValueError):
                    notifier.sanitize(dict(base, level=level))
        for level in (14, 15):
            with self.subTest(level=level):
                self.assertEqual(notifier.sanitize(dict(base, level=level))["level"], level)

    def test_requires_rule_id(self):
        with self.assertRaises(ValueError):
            notifier.sanitize(dict(integration.build(ALERT), rule_id=""))


class SlackMessage(unittest.TestCase):
    def setUp(self):
        self.clean = notifier.sanitize(integration.build(ALERT))
        self.text = notifier.slack_message(self.clean)["text"]

    def test_test_event_prefix(self):
        self.assertTrue(self.text.startswith("[TEST][SECURITY][CRITICAL] @channel"))

    def test_real_event_prefix_has_no_test_marker(self):
        text = notifier.slack_message(dict(self.clean, test=False))["text"]
        self.assertTrue(text.startswith("[SECURITY][CRITICAL] @channel"))
        self.assertNotIn("[TEST]", text)

    def test_carries_declared_context(self):
        self.assertIn("rule 100129 (level 14)", self.text)
        self.assertIn("k3s-01", self.text)
        self.assertIn("wazuh.imcherry5778.xyz", self.text)

    def test_mention_enabled(self):
        self.assertIs(notifier.slack_message(self.clean)["link_names"], True)

    def test_no_raw_material_in_slack_body(self):
        for needle in FORBIDDEN:
            with self.subTest(needle=needle):
                self.assertNotIn(needle, self.text)

    def test_strips_markup_injection(self):
        hostile = notifier.sanitize(
            dict(
                integration.build(ALERT),
                rule_description="<!channel> @here <https://evil.example.com|click>",
            )
        )
        text = notifier.slack_message(hostile)["text"]
        self.assertNotIn("<", text)
        self.assertNotIn(">", text)
        # 본문에 남는 @는 우리가 만든 @channel 하나뿐이다.
        self.assertEqual(text.count("@"), 1)


class WebhookHostPinning(unittest.TestCase):
    """NetworkPolicy가 FQDN을 모르므로 목적지 제한은 이 검증이 담당한다."""

    def _load(self, value):
        with tempfile.NamedTemporaryFile("w", suffix=".url", delete=False) as handle:
            handle.write(value)
            path = handle.name
        original = notifier.HOOK_FILE
        notifier.HOOK_FILE = path
        try:
            return notifier.load_hook()
        finally:
            notifier.HOOK_FILE = original
            pathlib.Path(path).unlink()

    def test_accepts_slack_incoming_webhook(self):
        url = "https://hooks.slack.com/services/T000/B000/abc"
        self.assertEqual(self._load(url + "\n"), url)

    def test_rejects_other_hosts_and_schemes(self):
        for value in (
            "https://evil.example.com/services/T000/B000/abc",
            "http://hooks.slack.com/services/T000/B000/abc",
            "https://hooks.slack.com/api/chat.postMessage",
            "https://hooks.slack.com.evil.example.com/services/T/B/x",
            "https://hooks.slack.com/services/T/B/x?redirect=1",
            "not-a-url",
        ):
            with self.subTest(value=value):
                with self.assertRaises(ValueError):
                    self._load(value)


if __name__ == "__main__":
    unittest.main(verbosity=2)
