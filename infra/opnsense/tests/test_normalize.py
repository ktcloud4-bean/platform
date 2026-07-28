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


if __name__ == "__main__":
    unittest.main()
