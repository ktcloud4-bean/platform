#!/usr/bin/env python3
"""classify_opnsense_drift.py 회귀 테스트.

승인된 drift(WazuhAgent 신규 추가·IDS persisted_at·firmware plugins 목록)만
통과시키고, 그 밖의 어떤 foreign semantic drift도 --update 전에 거부하는지
확인한다. 라이브 OPNsense를 호출하지 않는다.
"""
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from classify_opnsense_drift import classify  # noqa: E402

COMMON = dict(
    agent_name="opnsense-01",
    manager_address="10.10.20.10",
    events_port="31514",
    auth_port="31515",
)

PLUGINS_HUNK = """\
@@ -73,1 +73,1 @@
-      <plugins>os-acme-client,os-node_exporter</plugins>
+      <plugins>os-acme-client,os-node_exporter,os-wazuh-agent</plugins>
"""

IDS_HUNK = """\
@@ -2206,1 +2206,1 @@
-    <IDS version="1.1.2" persisted_at="1785445956.85" description="Intrusion detection">
+    <IDS version="1.1.2" persisted_at="1785758919.18" description="Intrusion detection">
"""

WAZUHAGENT_HUNK = """\
@@ -3203,0 +3204,34 @@
+    <WazuhAgent version="0.0.0" persisted_at="1785748406.92" description="Wazuh Agent">
+      <general>
+        <enabled>1</enabled>
+        <server_address>10.10.20.10</server_address>
+        <agent_name>opnsense-01</agent_name>
+        <protocol>tcp</protocol>
+        <port>31514</port>
+        <debug_level>0</debug_level>
+      </general>
+      <auth>
+        <password>***MASKED***</password>
+        <port>31515</port>
+      </auth>
+      <logcollector>
+        <remote_commands>0</remote_commands>
+        <syslog_programs />
+        <suricata_eve_log>1</suricata_eve_log>
+      </logcollector>
+      <rootcheck>
+        <enabled>0</enabled>
+      </rootcheck>
+      <syscollector>
+        <enabled>0</enabled>
+      </syscollector>
+      <syscheck>
+        <enabled>0</enabled>
+      </syscheck>
+      <active_response>
+        <enabled>0</enabled>
+        <remote_commands>0</remote_commands>
+        <fw_alias_ignore />
+        <repeated_offenders />
+      </active_response>
+    </WazuhAgent>
"""


class ClassifyOpnsenseDriftTest(unittest.TestCase):
    def test_approved_combo_passes(self):
        diff_text = PLUGINS_HUNK + IDS_HUNK + WAZUHAGENT_HUNK
        ok, bad = classify(diff_text, **COMMON)
        self.assertTrue(ok, bad)
        self.assertEqual(bad, [])

    def test_wazuhagent_only_passes(self):
        ok, bad = classify(WAZUHAGENT_HUNK, **COMMON)
        self.assertTrue(ok, bad)

    def test_ids_only_passes(self):
        ok, bad = classify(IDS_HUNK, **COMMON)
        self.assertTrue(ok, bad)

    def test_plugins_only_passes(self):
        ok, bad = classify(PLUGINS_HUNK, **COMMON)
        self.assertTrue(ok, bad)

    def test_foreign_pf_rule_change_is_rejected(self):
        foreign_hunk = """\
@@ -420,1 +420,1 @@
-        <descr>allow platform to postgres</descr>
+        <descr>allow platform to postgres and object-01</descr>
"""
        diff_text = PLUGINS_HUNK + IDS_HUNK + WAZUHAGENT_HUNK + foreign_hunk
        ok, bad = classify(diff_text, **COMMON)
        self.assertFalse(ok)
        self.assertEqual(len(bad), 1)
        self.assertIn("allow platform to postgres", bad[0])

    def test_wazuhagent_tampered_field_is_rejected(self):
        tampered = WAZUHAGENT_HUNK.replace(
            "+        <enabled>0</enabled>\n"
            "+        <remote_commands>0</remote_commands>\n"
            "+        <fw_alias_ignore />",
            "+        <enabled>1</enabled>\n"
            "+        <remote_commands>0</remote_commands>\n"
            "+        <fw_alias_ignore />",
        )
        self.assertNotEqual(tampered, WAZUHAGENT_HUNK)
        ok, bad = classify(tampered, **COMMON)
        self.assertFalse(ok)
        self.assertEqual(len(bad), 1)

    def test_ids_semantic_change_is_rejected(self):
        semantic_change_hunk = """\
@@ -2206,1 +2206,1 @@
-    <IDS version="1.1.2" persisted_at="1785445956.85" description="Intrusion detection">
+    <IDS version="1.1.3" persisted_at="1785758919.18" description="Intrusion detection">
"""
        ok, bad = classify(semantic_change_hunk, **COMMON)
        self.assertFalse(ok)

    def test_plugins_hunk_removing_unrelated_plugin_is_rejected(self):
        bad_plugins_hunk = """\
@@ -73,1 +73,1 @@
-      <plugins>os-acme-client,os-node_exporter</plugins>
+      <plugins>os-node_exporter,os-wazuh-agent</plugins>
"""
        ok, bad = classify(bad_plugins_hunk, **COMMON)
        self.assertFalse(ok)

    def test_plugins_hunk_adding_unrelated_plugin_is_rejected(self):
        bad_plugins_hunk = """\
@@ -73,1 +73,1 @@
-      <plugins>os-acme-client,os-node_exporter</plugins>
+      <plugins>os-acme-client,os-node_exporter,os-wazuh-agent,os-theme-cicada</plugins>
"""
        ok, bad = classify(bad_plugins_hunk, **COMMON)
        self.assertFalse(ok)

    def test_wazuhagent_addition_with_unmasked_password_is_rejected(self):
        leaked = WAZUHAGENT_HUNK.replace(
            "+        <password>***MASKED***</password>",
            "+        <password>hunter2</password>",
        )
        ok, bad = classify(leaked, **COMMON)
        self.assertFalse(ok)

    def test_no_hunks_passes_vacuously(self):
        ok, bad = classify("", **COMMON)
        self.assertTrue(ok)
        self.assertEqual(bad, [])


if __name__ == "__main__":
    unittest.main()
