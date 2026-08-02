# CI-01 Jenkins controller init container가 단일 runtime bundle만 읽는다.
path "kv/data/jenkins/runtime" {
  capabilities = ["read"]
}

path "kv/metadata/jenkins/runtime" {
  capabilities = ["read"]
}
