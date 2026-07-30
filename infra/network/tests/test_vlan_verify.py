import importlib.machinery
import importlib.util
import sys
import unittest
from datetime import datetime, timezone
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "vlan-verify"
LOADER = importlib.machinery.SourceFileLoader("vlan_verify", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
vlan_verify = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = vlan_verify
LOADER.exec_module(vlan_verify)


class FakeBackend:
    def __init__(self, observations):
        self.observations = dict(observations)

    def _get(self, key):
        try:
            return self.observations[key]
        except KeyError as exc:
            raise AssertionError(f"예상하지 않은 backend 호출: {key}") from exc

    def route(self, destination, _timeout):
        return self._get(("route", destination))

    def dns(self, server, port, query, _timeout):
        return self._get(("dns", server, port, query))

    def tcp(self, destination, port, _timeout):
        return self._get(("tcp", destination, port))

    def ntp(self, destination, port, _timeout):
        return self._get(("ntp", destination, port))

    def ssh(self, destination, port, _timeout):
        return self._get(("ssh", destination, port))

    def tls(self, destination, port, server_name, verify, ca_file, _timeout):
        return self._get(("tls", destination, port, server_name, verify, ca_file))

    def http(self, destination, port, server_name, path, verify, ca_file, _timeout):
        return self._get(
            ("http", destination, port, server_name, path, verify, ca_file)
        )


def observation(kind, detail="fixture", **data):
    return vlan_verify.Observation(kind, detail, data)


def route_probe(probe_id, destination, dependencies=()):
    return vlan_verify.Probe(
        probe_id=probe_id,
        layer="route",
        destination_location="fixture destination",
        expected=vlan_verify.ALLOW,
        reason="fixture route precondition",
        destination=destination,
        dependencies=dependencies,
    )


def tcp_probe(
    probe_id,
    destination,
    route_id,
    expected=vlan_verify.ALLOW,
    control_probe=None,
    enforcement_point=None,
    port=22,
):
    return vlan_verify.Probe(
        probe_id=probe_id,
        layer="tcp",
        destination_location="fixture service",
        expected=expected,
        reason="fixture policy basis",
        destination=destination,
        port=port,
        dependencies=(route_id,),
        control_probe=control_probe,
        enforcement_point=enforcement_point,
    )


def route_found(source="192.0.2.10", interface="eth0"):
    return observation(
        "ROUTE_FOUND",
        source_address=source,
        source_interface=interface,
        gateway="192.0.2.1",
    )


def control_result(probe_id="mgmt-open", destination="198.51.100.10", port=22):
    return vlan_verify.Result(
        probe_id=probe_id,
        layer="tcp",
        source="MGMT control",
        destination_location="fixture service",
        destination=destination,
        resolved_destination=destination,
        protocol=f"TCP/{port}",
        expected=vlan_verify.ALLOW,
        reason="허용 출발지에서 서비스가 열려 있음을 확인",
        status=vlan_verify.PASS,
        observation="CONNECTED",
        decision_basis="fixture control",
        detail="TCP 3-way handshake 성공",
        observed_at=datetime.now(timezone.utc).isoformat(timespec="seconds"),
        source_address="198.51.100.20",
        source_interface="eth0",
        port=port,
        data={},
    )


class VlanVerifyEvaluationTest(unittest.TestCase):
    def setUp(self):
        self.profile = vlan_verify.get_profile("bootstrap")
        self.source = vlan_verify.SourceSpec(
            name="PLATFORM fixture",
            cidr="192.0.2.0/24",
            interface="eth0",
            vlan_id=20,
        )

    def run_fixture(self, probes, observations, evidence=None, profile=None, scope="vlan"):
        return vlan_verify.run_plan(
            profile=profile or self.profile,
            scope=scope,
            source=self.source,
            probes=probes,
            backend=FakeBackend(observations),
            evidence=evidence or {},
            timeout=0.1,
        )

    def test_expected_allow_success(self):
        probes = [
            route_probe("route", "198.51.100.10"),
            tcp_probe("allow", "198.51.100.10", "route"),
        ]
        report = self.run_fixture(
            probes,
            {
                ("route", "198.51.100.10"): route_found(),
                ("tcp", "198.51.100.10", 22): observation("CONNECTED"),
            },
        )

        self.assertEqual(report.overall_status, vlan_verify.PASS)
        self.assertEqual(report.exit_code, vlan_verify.EXIT_OK)
        self.assertEqual(report.results[-1].status, vlan_verify.PASS)

    def test_expected_allow_timeout_is_failure(self):
        probes = [
            route_probe("route", "198.51.100.10"),
            tcp_probe("allow", "198.51.100.10", "route"),
        ]
        report = self.run_fixture(
            probes,
            {
                ("route", "198.51.100.10"): route_found(),
                ("tcp", "198.51.100.10", 22): observation("TIMEOUT"),
            },
        )

        self.assertEqual(report.results[-1].status, vlan_verify.FAIL)
        self.assertEqual(report.exit_code, vlan_verify.EXIT_FAILED)

    def test_expected_block_timeout_with_open_control_is_success(self):
        probes = [
            route_probe("route", "198.51.100.10"),
            tcp_probe(
                "blocked",
                "198.51.100.10",
                "route",
                expected=vlan_verify.BLOCK,
                control_probe="mgmt-open",
                enforcement_point="opnsense",
            ),
        ]
        report = self.run_fixture(
            probes,
            {
                ("route", "198.51.100.10"): route_found(),
                ("tcp", "198.51.100.10", 22): observation("TIMEOUT"),
            },
            evidence={"mgmt-open": control_result()},
        )

        self.assertEqual(report.results[-1].status, vlan_verify.PASS)
        self.assertIn("drop(timeout)", report.results[-1].decision_basis)
        self.assertEqual(report.exit_code, vlan_verify.EXIT_OK)

    def test_expected_block_open_is_policy_violation(self):
        probes = [
            route_probe("route", "198.51.100.10"),
            tcp_probe(
                "blocked",
                "198.51.100.10",
                "route",
                expected=vlan_verify.BLOCK,
                control_probe="mgmt-open",
                enforcement_point="opnsense",
            ),
        ]
        report = self.run_fixture(
            probes,
            {
                ("route", "198.51.100.10"): route_found(),
                ("tcp", "198.51.100.10", 22): observation("CONNECTED"),
            },
            evidence={"mgmt-open": control_result()},
        )

        self.assertEqual(report.results[-1].status, vlan_verify.FAIL)
        self.assertEqual(report.exit_code, vlan_verify.EXIT_FAILED)

    def test_block_without_matching_control_is_inconclusive(self):
        probes = [
            route_probe("route", "198.51.100.10"),
            tcp_probe(
                "blocked",
                "198.51.100.10",
                "route",
                expected=vlan_verify.BLOCK,
                control_probe="missing-control",
                enforcement_point="opnsense",
            ),
        ]
        report = self.run_fixture(
            probes,
            {
                ("route", "198.51.100.10"): route_found(),
                ("tcp", "198.51.100.10", 22): observation("TIMEOUT"),
            },
        )

        self.assertEqual(report.results[-1].status, vlan_verify.INCONCLUSIVE)
        self.assertEqual(report.exit_code, vlan_verify.EXIT_INCONCLUSIVE)

    def test_dns_failure_is_inconclusive(self):
        probes = [
            route_probe("dns-route", "192.0.2.1"),
            vlan_verify.Probe(
                probe_id="dns",
                layer="dns",
                destination_location="resolver",
                expected=vlan_verify.ALLOW,
                reason="fixture DNS",
                destination="192.0.2.1",
                port=53,
                query="example.test",
                dependencies=("dns-route",),
            ),
        ]
        report = self.run_fixture(
            probes,
            {
                ("route", "192.0.2.1"): route_found(),
                ("dns", "192.0.2.1", 53, "example.test"): observation("TIMEOUT"),
            },
        )

        self.assertEqual(report.results[-1].status, vlan_verify.INCONCLUSIVE)
        self.assertEqual(report.exit_code, vlan_verify.EXIT_INCONCLUSIVE)

    def test_route_source_mismatch_is_inconclusive(self):
        probes = [route_probe("route", "198.51.100.10")]
        report = self.run_fixture(
            probes,
            {("route", "198.51.100.10"): route_found(source="203.0.113.10")},
        )

        self.assertEqual(report.results[0].observation, "SOURCE_MISMATCH")
        self.assertEqual(report.results[0].status, vlan_verify.INCONCLUSIVE)
        self.assertEqual(report.exit_code, vlan_verify.EXIT_INCONCLUSIVE)

    def test_timeout_and_connection_refused_remain_distinct(self):
        probes = [
            route_probe("route-timeout", "198.51.100.10"),
            tcp_probe("timeout", "198.51.100.10", "route-timeout", port=22),
            route_probe("route-refused", "198.51.100.11"),
            tcp_probe("refused", "198.51.100.11", "route-refused", port=22),
        ]
        report = self.run_fixture(
            probes,
            {
                ("route", "198.51.100.10"): route_found(),
                ("tcp", "198.51.100.10", 22): observation("TIMEOUT"),
                ("route", "198.51.100.11"): route_found(),
                ("tcp", "198.51.100.11", 22): observation("CONNECTION_REFUSED"),
            },
        )

        by_id = {result.probe_id: result for result in report.results}
        self.assertEqual(by_id["timeout"].observation, "TIMEOUT")
        self.assertEqual(by_id["timeout"].status, vlan_verify.FAIL)
        self.assertEqual(by_id["refused"].observation, "CONNECTION_REFUSED")
        self.assertEqual(by_id["refused"].status, vlan_verify.INCONCLUSIVE)
        self.assertEqual(report.exit_code, vlan_verify.EXIT_FAILED)

    def test_one_failure_makes_multi_probe_exit_nonzero(self):
        probes = [
            route_probe("route-ok", "198.51.100.10"),
            tcp_probe("ok", "198.51.100.10", "route-ok"),
            route_probe("route-fail", "198.51.100.11"),
            tcp_probe("fail", "198.51.100.11", "route-fail"),
        ]
        report = self.run_fixture(
            probes,
            {
                ("route", "198.51.100.10"): route_found(),
                ("tcp", "198.51.100.10", 22): observation("CONNECTED"),
                ("route", "198.51.100.11"): route_found(),
                ("tcp", "198.51.100.11", 22): observation("TIMEOUT"),
            },
        )

        self.assertEqual(report.results[1].status, vlan_verify.PASS)
        self.assertEqual(report.results[3].status, vlan_verify.FAIL)
        self.assertEqual(report.exit_code, vlan_verify.EXIT_FAILED)

    def test_tls_and_http_are_separate_results(self):
        destination = "198.51.100.10"
        route = route_probe("route", destination)
        tcp = tcp_probe("tcp", destination, "route", port=8006)
        tls = vlan_verify.Probe(
            probe_id="tls",
            layer="tls",
            destination_location="Proxmox HTTPS",
            expected=vlan_verify.ALLOW,
            reason="fixture TLS",
            destination=destination,
            port=8006,
            server_name="pve.example.test",
            tls_verify=False,
            dependencies=("route", "tcp"),
        )
        http = vlan_verify.Probe(
            probe_id="http",
            layer="http",
            destination_location="Proxmox HTTPS",
            expected=vlan_verify.ALLOW,
            reason="fixture HTTP",
            destination=destination,
            port=8006,
            server_name="pve.example.test",
            tls_verify=False,
            dependencies=("route", "tcp", "tls"),
        )
        report = self.run_fixture(
            [route, tcp, tls, http],
            {
                ("route", destination): route_found(),
                ("tcp", destination, 8006): observation("CONNECTED"),
                ("tls", destination, 8006, "pve.example.test", False, None): observation(
                    "TLS_ESTABLISHED"
                ),
                (
                    "http",
                    destination,
                    8006,
                    "pve.example.test",
                    "/",
                    False,
                    None,
                ): observation("HTTP_RESPONSE", status=200),
            },
        )

        self.assertEqual([item.layer for item in report.results], ["route", "tcp", "tls", "http"])
        self.assertTrue(all(item.status == vlan_verify.PASS for item in report.results))


class VlanVerifyContractTest(unittest.TestCase):
    def test_invalid_profile_and_invalid_probe_input(self):
        with self.assertRaises(vlan_verify.VlanVerifyError):
            vlan_verify.get_profile("not-a-profile")

        invalid = route_probe("invalid-layer", "198.51.100.10")
        invalid = vlan_verify.Probe(**{**invalid.__dict__, "layer": "icmp"})
        with self.assertRaises(vlan_verify.VlanVerifyError):
            vlan_verify.validate_plan(
                vlan_verify.get_profile("bootstrap"),
                "vlan",
                vlan_verify.SourceSpec("fixture", "192.0.2.0/24", vlan_id=20),
                [invalid],
            )

    def test_hardened_rejects_phase1_and_missing_policy_pair(self):
        source = vlan_verify.SourceSpec("phase1", "198.51.100.0/24")
        probes = [route_probe("route", "198.51.100.1")]
        with self.assertRaises(vlan_verify.VlanVerifyError):
            vlan_verify.validate_plan(
                vlan_verify.get_profile("hardened"),
                "phase1-untagged-lan",
                source,
                probes,
            )

        vlan_source = vlan_verify.SourceSpec("MGMT", "198.51.100.0/24", vlan_id=10)
        with self.assertRaises(vlan_verify.VlanVerifyError):
            vlan_verify.validate_plan(
                vlan_verify.get_profile("hardened"), "vlan", vlan_source, probes
            )

    def test_nonexistent_hardened_source_vlan_cannot_pass(self):
        source = vlan_verify.SourceSpec(
            "PLATFORM", "192.0.2.0/24", interface="eth0", vlan_id=20
        )
        probes = [
            route_probe("allow-route", "198.51.100.10"),
            tcp_probe("allow", "198.51.100.10", "allow-route"),
            route_probe("block-route", "198.51.100.11"),
            tcp_probe(
                "block",
                "198.51.100.11",
                "block-route",
                expected=vlan_verify.BLOCK,
                control_probe="control",
                enforcement_point="opnsense",
            ),
        ]
        report = vlan_verify.run_plan(
            profile=vlan_verify.get_profile("hardened"),
            scope="vlan",
            source=source,
            probes=probes,
            backend=FakeBackend(
                {
                    ("route", "198.51.100.10"): route_found(source="198.51.100.50"),
                    ("route", "198.51.100.11"): route_found(source="198.51.100.50"),
                }
            ),
            evidence={"control": control_result("control", "198.51.100.11")},
            timeout=0.1,
        )

        self.assertEqual(report.overall_status, vlan_verify.INCONCLUSIVE)
        self.assertEqual(report.exit_code, vlan_verify.EXIT_INCONCLUSIVE)
        self.assertTrue(
            all(result.status == vlan_verify.INCONCLUSIVE for result in report.results)
        )

    def test_same_vlan_opnsense_block_claim_is_rejected(self):
        source = vlan_verify.SourceSpec("DATA", "203.0.113.0/24", vlan_id=50)
        probes = [
            route_probe("route", "203.0.113.20"),
            tcp_probe(
                "same-vlan-block",
                "203.0.113.20",
                "route",
                expected=vlan_verify.BLOCK,
                control_probe="control",
                enforcement_point="opnsense",
                port=9000,
            ),
        ]

        with self.assertRaises(vlan_verify.VlanVerifyError):
            vlan_verify.validate_plan(
                vlan_verify.get_profile("bootstrap"), "vlan", source, probes
            )

    def test_cli_returns_usage_code_for_unknown_profile(self):
        self.assertEqual(
            vlan_verify.main(["profiles", "unknown-profile"]),
            vlan_verify.EXIT_USAGE,
        )

    def test_phase1_proxmox_keeps_tcp_ssh_tls_http_separate(self):
        parser = vlan_verify.build_parser()
        args = parser.parse_args(
            [
                "phase1",
                "--profile",
                "bootstrap",
                "--source-name",
                "fixture",
                "--source-cidr",
                "198.51.100.0/24",
                "--checks",
                "proxmox",
                "--proxmox-host",
                "198.51.100.10",
                "--proxmox-name",
                "pve.example.test",
                "--proxmox-ssh-port",
                "22",
                "--proxmox-https-port",
                "8006",
            ]
        )

        _source, probes, _checks = vlan_verify.build_phase1_plan(args)

        self.assertEqual(
            [probe.layer for probe in probes],
            ["route", "tcp", "ssh", "tcp", "tls", "http"],
        )

    def test_invalid_port_is_rejected_before_network_call(self):
        source = vlan_verify.SourceSpec("fixture", "192.0.2.0/24", vlan_id=20)
        probes = [
            route_probe("route", "198.51.100.10"),
            tcp_probe("invalid-port", "198.51.100.10", "route", port=70000),
        ]

        with self.assertRaises(vlan_verify.VlanVerifyError):
            vlan_verify.validate_plan(
                vlan_verify.get_profile("bootstrap"), "vlan", source, probes
            )


if __name__ == "__main__":
    unittest.main()
