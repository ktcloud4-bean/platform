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
      role       = "harbor"
      token_path = "/var/run/secrets/vault/token"
    }
  }
}

template {
  destination          = "/vault/secrets/registry_http_secret"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/harbor/runtime" -}}{{ .Data.data.registry_http_secret }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/s3_access_key"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/harbor/runtime" -}}{{ .Data.data.s3_access_key }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/s3_secret_key"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/harbor/runtime" -}}{{ .Data.data.s3_secret_key }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/passwd"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/harbor/runtime" -}}{{ .Data.data.registry_htpasswd }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/core_secret"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/harbor/runtime" -}}{{ .Data.data.core_secret }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/jobservice_secret"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/harbor/runtime" -}}{{ .Data.data.jobservice_secret }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/registry_password"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/harbor/runtime" -}}{{ .Data.data.registry_password }}{{- end -}}
EOT
}
