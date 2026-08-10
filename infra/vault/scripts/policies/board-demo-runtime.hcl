# BOARD-DEMO-01 runtime ServiceAccount는 자기 DB 연결 정보만 읽는다.
path "kv/data/board-demo/runtime" {
  capabilities = ["read"]
}

path "kv/metadata/board-demo/runtime" {
  capabilities = ["read"]
}
