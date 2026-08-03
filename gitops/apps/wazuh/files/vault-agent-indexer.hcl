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
      role       = "wazuh-indexer"
      token_path = "/var/run/secrets/vault/token"
    }
  }
}

template {
  destination          = "/vault/secrets/certs/root-ca.pem"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/indexer" -}}{{ .Data.data.root_ca_pem }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/certs/node.pem"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/indexer" -}}{{ .Data.data.node_pem }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/certs/node-key.pem"
  perms                = "0400"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/indexer" -}}{{ .Data.data.node_key_pem }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/certs/admin.pem"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/indexer" -}}{{ .Data.data.admin_pem }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/certs/admin-key.pem"
  perms                = "0400"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/indexer" -}}{{ .Data.data.admin_key_pem }}{{- end -}}
EOT
}

template {
  destination          = "/vault/secrets/security/internal_users.yml"
  perms                = "0400"
  error_on_missing_key = true
  contents             = <<EOT
---
_meta:
  type: "internalusers"
  config_version: 2

admin:
  hash: "{{ with secret "kv/data/wazuh/indexer" }}{{ .Data.data.admin_password_hash }}{{ end }}"
  reserved: true
  backend_roles:
  - "admin"
  description: "WAZUH-01 filebeat writer and verification account"
EOT
}
