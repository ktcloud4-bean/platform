# WAZUH-04: 새 Vault role을 만들지 않고 wazuh-manager Vault k8s-auth role을
# 그대로 재사용한다 — 이 role은 `bound_service_account_names`가 정확한
# ServiceAccount 이름으로 고정돼 있어(gitops/tools/wazuh-01/provision.sh),
# 이 Pod도 wazuh-manager ServiceAccount를 써야 인증된다. 이 Pod는 그 policy가
# 허용하는 kv/data/wazuh/manager의 필드만 읽는다 — manager가 이미 읽을 수 있는
# 경로라 새 권한이 생기지 않는다.
#
# WAZUH-04-FIX-01: client.keys는 pod 재시작마다 사라지는 컨테이너 파일시스템에만
# 있었고, wazuh-agentd의 자동 재등록이 같은 이름의 기존(비활성) 등록과 충돌해
# 영구 재시도에 빠지는 것을 라이브로 확인했다(docs/backlog.md 참고). authd_password
# 기반 동적 enrollment 대신, 매니저에 이미 살아 있는 등록의 client.keys 한 줄을
# `gitops/tools/wazuh-04-fix-01/apply-client-keys.sh`로 kv/wazuh/manager의
# wazuh_04_relay_client_keys 필드에 옮겨 담고 여기서 정적으로 렌더링한다
# (ossec.conf의 enrollment는 WAZUH-03 host agent와 동일하게 disabled).
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
  destination          = "/vault/secrets/client.keys"
  perms                = "0440"
  error_on_missing_key = true
  contents             = <<EOT
{{- with secret "kv/data/wazuh/manager" -}}{{ .Data.data.wazuh_04_relay_client_keys }}{{- end -}}
EOT
}
