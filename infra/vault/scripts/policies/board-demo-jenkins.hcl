# BOARD-DEMO-01 Jenkins controller가 전용 Gitea deploy key와 Harbor robot만 읽는다.
path "kv/data/board-demo/jenkins" {
  capabilities = ["read"]
}

path "kv/metadata/board-demo/jenkins" {
  capabilities = ["read"]
}
