# SCM-01 Gitea Pod가 기동 시점에 소비할 KV 경로만 연다.
path "kv/data/gitea/runtime" {
  capabilities = ["read"]
}

path "kv/metadata/gitea/runtime" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
