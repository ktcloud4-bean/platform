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
      role       = "wazuh-dashboard"
      token_path = "/var/run/secrets/vault/token"
    }
  }
}

template {
  destination          = "/vault/secrets/certs/root-ca.pem"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/dashboard" -}}{{ .Data.data.root_ca_pem }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/wazuh.env"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/dashboard" -}}
DASHBOARD_USERNAME={{ .Data.data.dashboard_username }}
DASHBOARD_PASSWORD={{ .Data.data.dashboard_password }}
API_USERNAME={{ .Data.data.api_username }}
API_PASSWORD={{ .Data.data.api_password }}
OIDC_CLIENT_SECRET={{ .Data.data.oidc_client_secret }}
{{- end -}}
EOT
}
