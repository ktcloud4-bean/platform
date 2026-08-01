# KC-01이 소비할 경로만 연다. 명시하지 않은 경로는 Vault 기본 deny다.

path "kv/data/keycloak/*" {
  capabilities = ["read"]
}

path "kv/metadata/keycloak/*" {
  capabilities = ["read", "list"]
}

# 단기 PostgreSQL 자격증명. 값을 저장하지 않고 매번 발급받는다.
path "database/creds/keycloak" {
  capabilities = ["read"]
}

# 내부 workload 인증서 발급. role이 클러스터 내부 이름만 허용한다.
path "pki/issue/internal-workload" {
  capabilities = ["update"]
}

# 자기 토큰과 lease 만 갱신할 수 있다.
path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "sys/leases/renew" {
  capabilities = ["update"]
}
