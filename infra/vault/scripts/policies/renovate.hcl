# UPDATE-01 Renovate init container가 단일 runtime bundle만 읽는다.
path "kv/data/renovate/runtime" {
  capabilities = ["read"]
}

path "kv/metadata/renovate/runtime" {
  capabilities = ["read"]
}
