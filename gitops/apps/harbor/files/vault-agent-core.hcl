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
  destination          = "/vault/secrets/admin_password"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/harbor/runtime" -}}{{ .Data.data.admin_password }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/db_password"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/harbor/runtime" -}}{{ .Data.data.db_password }}{{- end -}}
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

template {
  destination          = "/vault/secrets/csrf_key"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/harbor/runtime" -}}{{ .Data.data.csrf_key }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/key"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/harbor/runtime" -}}{{ .Data.data.secret_key }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/tls.key"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/harbor/runtime" -}}{{ .Data.data.token_private_key }}{{- end -}}
EOT
}
