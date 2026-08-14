# AWX-05 Machine credential의 built-in Vault external lookup만 k3s-01 canary
# private key를 resolve한다. runtime/bootstrap/provisioner policy에는 이 권한이 없다.
path "kv/data/awx/ssh-canary" {
  capabilities = ["read"]
}

path "kv/metadata/awx/ssh-canary" {
  capabilities = ["read"]
}
