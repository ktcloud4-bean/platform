# BOARD-DEMO-01 bootstrap Job만 Harbor pull credential과 Cosign trust를 읽는다.
path "kv/data/board-demo/bootstrap" {
  capabilities = ["read"]
}

path "kv/metadata/board-demo/bootstrap" {
  capabilities = ["read"]
}
