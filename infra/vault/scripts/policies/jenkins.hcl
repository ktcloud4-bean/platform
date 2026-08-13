# CI-01 Jenkins controller init container가 단일 runtime bundle만 읽는다.
path "kv/data/jenkins/runtime" {
  capabilities = ["read"]
}

path "kv/metadata/jenkins/runtime" {
  capabilities = ["read"]
}

# AWX-04 build job은 자기 전용 readonly Gitea key와 Harbor push robot만 읽는다.
path "kv/data/awx/jenkins" {
  capabilities = ["read"]
}

path "kv/metadata/awx/jenkins" {
  capabilities = ["read"]
}
