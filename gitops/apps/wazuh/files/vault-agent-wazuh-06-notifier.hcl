# WAZUH-06: notifier 전용 Vault policy·Kubernetes auth role을 새로 만든다.
# WAZUH-04가 wazuh-manager role을 재사용한 것과 반대로 여기서는 재사용하지 않는다 —
# manager가 Slack webhook을 읽을 수 있게 되면 "manager는 외부로 나가지 않는다"는
# 경계가 정책 수준에서 무너지기 때문이다. 이 role은 kv/data/wazuh/security-notifier
# 한 경로만 read할 수 있고, 반대로 manager·indexer·dashboard policy는 이 경로를
# 읽지 못한다(gitops/tools/wazuh-06/provision.sh).
exit_after_auth = true
pid_file = "/tmp/vault-agent.pid"

vault {
  address = "https://vault.vault.svc.cluster.local:8200"
  ca_cert = "/vault/tls/vault.crt"
  retry {
    num_retries = 12
  }
}

auto_auth {
  method "kubernetes" {
    mount_path = "auth/kubernetes"
    config = {
      role       = "wazuh-06-notifier"
      token_path = "/var/run/secrets/vault/token"
    }
  }
}

template {
  destination          = "/vault/secrets/slack-webhook-url"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/security-notifier" -}}{{ .Data.data.slack_webhook_url }}{{- end -}}
EOT
}
