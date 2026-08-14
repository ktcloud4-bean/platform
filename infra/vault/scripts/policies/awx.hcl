path "kv/data/awx/runtime" {
  capabilities = ["read"]
}

path "kv/metadata/awx/runtime" {
  capabilities = ["read"]
}

# bootstrap Hook만 private EE image pull Secret을 만들 수 있다. SCM deploy key나
# external lookup AppRole은 이 기존 workload policy에 넣지 않는다.
path "kv/data/awx/pull" {
  capabilities = ["read"]
}

path "kv/metadata/awx/pull" {
  capabilities = ["read"]
}

# Gitea SSH host key는 비밀이 아니지만, bootstrap Hook이 authenticated pin을
# task Pod의 strict known_hosts Secret으로만 만들 수 있게 별도 path로 분리한다.
path "kv/data/awx/scm-hostkeys" {
  capabilities = ["read"]
}

path "kv/metadata/awx/scm-hostkeys" {
  capabilities = ["read"]
}

# AWX-05의 public SSH host key는 bootstrap Hook만 execution Pod mount Secret으로
# 만든다. private Machine key와 lookup bootstrap은 이 workload policy로 읽지 못한다.
path "kv/data/awx/ssh-canary-hostkeys" {
  capabilities = ["read"]
}

path "kv/metadata/awx/ssh-canary-hostkeys" {
  capabilities = ["read"]
}
