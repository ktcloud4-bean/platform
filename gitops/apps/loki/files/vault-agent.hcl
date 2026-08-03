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
      role       = "loki"
      token_path = "/var/run/secrets/vault/token"
    }
  }
}

template {
  destination          = "/vault/secrets/credentials"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/loki/runtime" -}}
[default]
aws_access_key_id={{ .Data.data.s3_access_key }}
aws_secret_access_key={{ .Data.data.s3_secret_key }}
{{- end -}}
EOT
}
