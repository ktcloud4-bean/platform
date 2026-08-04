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
      role       = "shuffle-backend"
      token_path = "/var/run/secrets/vault/token"
    }
  }
}

template {
  destination          = "/vault/secrets/opensearch-password"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/shuffle/backend" -}}{{ .Data.data.opensearch_admin_password }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/encryption-modifier"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/shuffle/backend" -}}{{ .Data.data.encryption_modifier }}{{- end -}}
EOT
}
