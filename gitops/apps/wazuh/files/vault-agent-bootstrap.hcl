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
      role       = "wazuh-bootstrap"
      token_path = "/var/run/secrets/vault/token"
    }
  }
}

template {
  destination          = "/vault/secrets/root-ca.pem"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/bootstrap" -}}{{ .Data.data.root_ca_pem }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/admin.pem"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/bootstrap" -}}{{ .Data.data.admin_pem }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/admin-key.pem"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/bootstrap" -}}{{ .Data.data.admin_key_pem }}{{- end -}}
EOT
}
