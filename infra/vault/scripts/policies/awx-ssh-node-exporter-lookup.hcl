# AWX-07 Machine credential의 built-in Vault external lookup만 netbird-01
# node_exporter baseline private key를 resolve한다. runtime/bootstrap/provisioner policy에는 이 권한이 없다.
path "kv/data/awx/ssh-node-exporter" {
  capabilities = ["read"]
}

path "kv/metadata/awx/ssh-node-exporter" {
  capabilities = ["read"]
}
