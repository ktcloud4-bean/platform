import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import normalize  # noqa: E402


def scrub_xml(xml: str) -> ET.Element:
    root = ET.fromstring(xml)
    normalize.scrub(root)
    return root


class NormalizeAcmeSecretsTest(unittest.TestCase):
    def test_acme_account_private_key_is_masked_by_path(self) -> None:
        root = scrub_xml(
            """
            <opnsense>
              <OPNsense>
                <AcmeClient>
                  <accounts>
                    <account>
                      <key>synthetic-acme-account-private-key</key>
                    </account>
                  </accounts>
                </AcmeClient>
              </OPNsense>
            </opnsense>
            """
        )

        self.assertEqual(root.findtext(".//account/key"), normalize.MASK)

    def test_generic_key_outside_acme_account_is_preserved(self) -> None:
        root = scrub_xml(
            """
            <opnsense>
              <component><key>non-secret-selector</key></component>
              <AcmeClient><other><key>non-secret-acme-value</key></other></AcmeClient>
            </opnsense>
            """
        )

        self.assertEqual(root.findtext(".//component/key"), "non-secret-selector")
        self.assertEqual(
            root.findtext(".//AcmeClient/other/key"),
            "non-secret-acme-value",
        )

    def test_empty_acme_account_private_key_stays_empty(self) -> None:
        root = scrub_xml(
            """
            <AcmeClient>
              <accounts><account><key /></account></accounts>
            </AcmeClient>
            """
        )

        self.assertIsNone(root.find(".//account/key").text)

    def test_cloudflare_credentials_are_masked(self) -> None:
        root = scrub_xml(
            """
            <OPNsense>
              <AcmeClient>
                <validations>
                  <validation>
                    <dns_cf_token>synthetic-cloudflare-token</dns_cf_token>
                    <dns_cf_key>synthetic-cloudflare-key</dns_cf_key>
                    <dns_cf_zone_id>public-zone-id</dns_cf_zone_id>
                  </validation>
                </validations>
              </AcmeClient>
            </OPNsense>
            """
        )

        self.assertEqual(root.findtext(".//dns_cf_token"), normalize.MASK)
        self.assertEqual(root.findtext(".//dns_cf_key"), normalize.MASK)
        self.assertEqual(root.findtext(".//dns_cf_zone_id"), "public-zone-id")

    def test_other_dns_provider_credential_suffixes_are_masked(self) -> None:
        root = scrub_xml(
            """
            <validation>
              <dns_aws_secret>synthetic-aws-secret</dns_aws_secret>
              <dns_azuredns_clientsecret>synthetic-azure-secret</dns_azuredns_clientsecret>
              <dns_dnsexit_auth_pass>synthetic-auth-pass</dns_dnsexit_auth_pass>
              <dns_netcup_pw>synthetic-password</dns_netcup_pw>
              <dns_hostingde_apiKey>synthetic-api-key</dns_hostingde_apiKey>
              <dns_infoblox_credentials>synthetic-credentials</dns_infoblox_credentials>
            </validation>
            """
        )

        for child in root:
            self.assertEqual(child.text, normalize.MASK, child.tag)

    def test_empty_cloudflare_credential_stays_empty(self) -> None:
        root = scrub_xml("<validation><dns_cf_token /></validation>")

        self.assertIsNone(root.find("dns_cf_token").text)

    def test_existing_secret_and_revision_rules_still_apply(self) -> None:
        root = scrub_xml(
            """
            <OPNsense>
              <revision><time>123</time></revision>
              <system><user><password>synthetic-password</password></user></system>
            </OPNsense>
            """
        )

        self.assertIsNone(root.find("revision"))
        self.assertEqual(root.findtext(".//password"), normalize.MASK)


class NormalizeIpsecSecretsTest(unittest.TestCase):
    """AWS-NET-01이 도입한 IPsec pre-shared key가 스냅샷에 남지 않게 고정한다.

    PSK 값은 <preSharedKey> 의 텍스트가 아니라 하위 <Key> 에 들어간다.
    태그 매칭이 하위 요소까지 제거하는 동작에 의존하므로 회귀로 묶어 둔다.
    """

    PSK = "synthetic-aws-tunnel-preshared-key"

    def test_ipsec_preshared_key_child_value_is_removed(self) -> None:
        root = scrub_xml(
            f"""
            <opnsense><OPNsense><IPsec>
              <preSharedKeys>
                <preSharedKey>
                  <ident>synthetic-tunnel-1</ident>
                  <keyType>PSK</keyType>
                  <Key>{self.PSK}</Key>
                </preSharedKey>
              </preSharedKeys>
            </IPsec></OPNsense></opnsense>
            """
        )

        self.assertNotIn(self.PSK, ET.tostring(root, encoding="unicode"))
        # 항목 자체는 남겨 PSK 개수 변화는 계속 드리프트로 보이게 한다.
        self.assertIsNotNone(root.find(".//preSharedKeys/preSharedKey"))
        self.assertIsNone(root.find(".//preSharedKey/Key"))

    def test_psk_tag_is_masked(self) -> None:
        root = scrub_xml(f"<tunnel><psk>{self.PSK}</psk></tunnel>")

        self.assertEqual(root.findtext("psk"), normalize.MASK)

    def test_swanctl_non_secret_fields_are_preserved(self) -> None:
        """터널 구성 드리프트를 계속 볼 수 있어야 한다.

        PSK만 가리고 연결·traffic selector 같은 정책 값은 남긴다.
        """
        root = scrub_xml(
            """
            <opnsense><OPNsense><Swanctl>
              <Connections><Connection>
                <proposals>aes256-sha256-modp2048</proposals>
                <version>2</version>
              </Connection></Connections>
              <locals><local><auth>psk</auth></local></locals>
              <children><child>
                <local_ts>10.10.50.0/24</local_ts>
                <remote_ts>10.20.0.0/16</remote_ts>
              </child></children>
            </Swanctl></OPNsense></opnsense>
            """
        )

        self.assertEqual(root.findtext(".//Connection/proposals"),
                         "aes256-sha256-modp2048")
        self.assertEqual(root.findtext(".//child/local_ts"), "10.10.50.0/24")
        self.assertEqual(root.findtext(".//child/remote_ts"), "10.20.0.0/16")
        # <auth>psk</auth> 는 값이 psk 일 뿐 비밀이 아니다. 태그명만 검사한다.
        self.assertEqual(root.findtext(".//local/auth"), "psk")


if __name__ == "__main__":
    unittest.main()
