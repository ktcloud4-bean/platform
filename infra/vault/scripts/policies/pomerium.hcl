# POM-01이 소비할 경로만 연다.
# keycloak policy 와 경로가 겹치지 않아 앱 간 격리를 확인하는 대조군이 된다.

path "kv/data/pomerium/*" {
  capabilities = ["read"]
}

path "kv/metadata/pomerium/*" {
  capabilities = ["read", "list"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
