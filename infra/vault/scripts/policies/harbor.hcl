# REG-01 Harbor Pod만 자기 runtime KV v2 data를 읽는다.
path "kv/data/harbor/runtime" {
  capabilities = ["read"]
}

path "kv/metadata/harbor/runtime" {
  capabilities = ["read"]
}
