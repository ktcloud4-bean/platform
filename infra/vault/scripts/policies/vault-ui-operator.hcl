# VAULT-03: OIDC로 로그인한 UI 운영자가 kv 전체를 읽고 나열한다.
# sys/mounts를 비롯해 명시하지 않은 경로는 Vault 기본 deny다. 자기 token 조회·갱신과
# UI가 쓰는 sys/internal/ui/* 는 Vault 내장 default policy가 이미 제공하므로 여기서
# 다시 열지 않는다.

path "kv/data/*" {
  capabilities = ["read", "list"]
}

path "kv/metadata/*" {
  capabilities = ["read", "list"]
}
