#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest


SOURCE = pathlib.Path(__file__).parents[3] / "apps/obs/files/obs-18-slack-egress-proxy.py"
SPEC = importlib.util.spec_from_file_location("obs18proxy", SOURCE)
PROXY = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(PROXY)


class SlackProxyTest(unittest.TestCase):
    def test_accepts_only_slack_connect(self):
        request = b"CONNECT hooks.slack.com:443 HTTP/1.1\r\nHost: hooks.slack.com:443\r\n\r\n"
        self.assertTrue(PROXY.is_expected_connect(request))

    def test_rejects_other_host_port_and_method(self):
        for request in (
            b"CONNECT slack.com:443 HTTP/1.1\r\n\r\n",
            b"CONNECT hooks.slack.com:80 HTTP/1.1\r\n\r\n",
            b"GET https://hooks.slack.com/ HTTP/1.1\r\n\r\n",
        ):
            with self.subTest(request=request):
                self.assertFalse(PROXY.is_expected_connect(request))

    def test_accepts_only_cluster_client_sources(self):
        self.assertTrue(PROXY.allowed_client("10.42.0.99"))
        self.assertTrue(PROXY.allowed_client("10.10.20.10"))
        self.assertFalse(PROXY.allowed_client("10.10.20.11"))
        self.assertFalse(PROXY.allowed_client("10.10.30.10"))


if __name__ == "__main__":
    unittest.main()
