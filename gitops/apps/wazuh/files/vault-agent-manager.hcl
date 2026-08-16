# manager container는 UID 0이지만 capabilities를 모두 drop해 CAP_DAC_OVERRIDE가 없다.
# 그래서 0400이 아니라 fsGroup 101이 읽을 수 있는 0440으로 렌더한다.
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
  destination          = "/vault/secrets/certs/root-ca.pem"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/manager" -}}{{ .Data.data.root_ca_pem }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/certs/filebeat.pem"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/manager" -}}{{ .Data.data.filebeat_pem }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/certs/filebeat-key.pem"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/manager" -}}{{ .Data.data.filebeat_key_pem }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/authd.pass"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/manager" -}}{{ .Data.data.authd_password }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/wazuh.env"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/manager" -}}
INDEXER_USERNAME={{ .Data.data.indexer_username }}
INDEXER_PASSWORD={{ .Data.data.indexer_password }}
API_USERNAME={{ .Data.data.api_username }}
API_PASSWORD={{ .Data.data.api_password }}
{{- end -}}
EOT
}

# SOAR-01 webhook capability는 이 memory volume을 유일하게 mount한 Wazuh manager
# container 안에서만 읽는다. integratord가 UID/GID 999로 내려가므로 Vault Agent
# UID/GID와 무관하게 읽을 수 있어야 하며, ossec.conf와 integration argv에는 넣지 않아
# Wazuh integrations.log에 URL이 남지 않는다.
template {
  destination          = "/vault/secrets/soar01-hook-url"
  perms                = "0444"
  # rollback은 hook key를 지워 integration을 fail-closed로 만든다. 이 template는 빈
  # 값을 렌더해야 manager Pod 자체가 멈추지 않으며, custom-soar01은 빈 값을 URL로
  # 인정하지 않는다.
  error_on_missing_key = false
  contents             = <<EOT
{{- with secret "kv/data/wazuh/manager" -}}{{ .Data.data.soar01_hook_url }}{{- end -}}
EOT
}
