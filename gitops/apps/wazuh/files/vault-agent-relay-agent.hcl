# WAZUH-04: 새 Vault role을 만들지 않고 wazuh-manager Vault k8s-auth role을
# 그대로 재사용한다 — 이 role은 `bound_service_account_names`가 정확한
# ServiceAccount 이름으로 고정돼 있어(gitops/tools/wazuh-01/provision.sh),
# 이 Pod도 wazuh-manager ServiceAccount를 써야 인증된다. 이 Pod는 그 policy가
# 허용하는 kv/data/wazuh/manager의 authd_password 필드 하나만 읽는다 — manager가
# 이미 읽을 수 있는 것과 같은 값이라 새 권한이 생기지 않는다.
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
      role       = "wazuh-manager"
      token_path = "/var/run/secrets/vault/token"
    }
  }
}

template {
  destination          = "/vault/secrets/authd.pass"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/manager" -}}{{ .Data.data.authd_password }}{{- end -}}
EOT
}
