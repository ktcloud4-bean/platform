# AWX provisioning Hook은 기존 runtime 수렴과 SCM external credential의 AppRole
# 입력값만 읽는다. deploy key 자체는 Vault lookup role만 읽을 수 있다.
path "kv/data/awx/runtime" {
  capabilities = ["read"]
}

path "kv/metadata/awx/runtime" {
  capabilities = ["read"]
}

path "kv/data/awx/scm-lookup" {
  capabilities = ["read"]
}

path "kv/metadata/awx/scm-lookup" {
  capabilities = ["read"]
}

# AWX provision Hook은 Machine credential external lookup의 AppRole bootstrap만
# 읽는다. SSH private key와 authenticated host key는 읽지 못한다.
path "kv/data/awx/ssh-canary-lookup" {
  capabilities = ["read"]
}

path "kv/metadata/awx/ssh-canary-lookup" {
  capabilities = ["read"]
}
