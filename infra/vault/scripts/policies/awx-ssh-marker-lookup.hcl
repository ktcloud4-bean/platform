# AWX-06 Machine credential의 built-in Vault external lookup만 netbird-01 marker
# private key를 resolve한다. runtime/bootstrap/provisioner policy에는 이 권한이 없다.
path "kv/data/awx/ssh-marker" {
  capabilities = ["read"]
}

path "kv/metadata/awx/ssh-marker" {
  capabilities = ["read"]
}
