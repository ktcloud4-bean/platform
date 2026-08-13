# AWX의 HashiCorp Vault external credential이 SCM deploy key 하나를 resolve할 때만
# 사용하는 AppRole policy다.
path "kv/data/awx/scm" {
  capabilities = ["read"]
}

path "kv/metadata/awx/scm" {
  capabilities = ["read"]
}
