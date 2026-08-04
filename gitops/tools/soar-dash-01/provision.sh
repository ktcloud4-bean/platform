#!/usr/bin/env bash
# SOAR-DASH-01 Vault provisioning.
#
# Shuffle 전용 OpenSearch admin password와 backend encryption modifier를 로컬 mode 0600
# 입력으로 만들고 Vault policy·Kubernetes auth role·KV에 넣는다. Git과 Kubernetes Secret에는
# 아무 값도 남기지 않으며 이 스크립트는 어떤 credential도 출력하지 않는다.
set -euo pipefail

readonly mode=${1:-check}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly secret_dir=${secret_root}/shuffle
readonly vault_token_file=${secret_root}/vault-root.token
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ ${mode} == check || ${mode} == apply ]] || {
  echo 'usage: provision.sh [check|apply]' >&2
  exit 2
}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'provision 실패: 인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}
[[ -f ${vault_token_file} && ! -L ${vault_token_file} && $(stat -c %a "${vault_token_file}") == 600 ]] || {
  echo 'provision 실패: Vault root token file이 없거나 mode 0600이 아니다.' >&2
  exit 1
}

exec 9>/tmp/soar-dash-01-provision.lock
flock -n 9 || {
  echo 'provision 실패: 다른 SOAR-DASH-01 provisioning이 실행 중이다.' >&2
  exit 1
}

vault_exec() {
  local script=$1
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; ${script}'"
}

vault_check() {
  # shellcheck disable=SC2016
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | vault_exec \
    'for r in opensearch backend; do
       vault policy read shuffle-${r} >/dev/null || exit 1
       vault read auth/kubernetes/role/shuffle-${r} >/dev/null || exit 1
     done
     vault kv metadata get kv/shuffle/opensearch >/dev/null || exit 1
     vault kv metadata get kv/shuffle/backend >/dev/null || exit 1'
}

if [[ ${mode} == check ]]; then
  if [[ -d ${secret_dir} && -f ${secret_dir}/opensearch-admin-password ]]; then
    echo 'SecretInput=PRESENT'
  else
    echo 'SecretInput=ABSENT'
  fi
  if vault_check; then
    echo 'VaultRuntime=PASS policy=shuffle-opensearch,shuffle-backend kv=kv/shuffle/{opensearch,backend}'
  else
    echo 'VaultRuntime=ABSENT'
  fi
  exit 0
fi

install -d -m 0700 "${secret_dir}"
umask 077

random_alnum() {
  openssl rand -base64 48 | tr -d '\n=+/' | cut -c1-32
}

# OpenSearch 2.12+는 OPENSEARCH_INITIAL_ADMIN_PASSWORD가 대/소문자·숫자·특수문자를
# 모두 포함한 강한 값이 아니면 부팅을 거부한다.
ensure_strong_password() {
  local file=${secret_dir}/$1
  if [[ ! -f ${file} ]]; then
    { random_alnum | tr -d '\n'; printf 'Aa1!\n'; } >"${file}"
  fi
  [[ ! -L ${file} && $(stat -c %a "${file}") == 600 ]] || {
    echo "provision 실패: ${1} 입력이 regular file mode 0600이 아니다." >&2
    exit 1
  }
}

ensure_strong_password opensearch-admin-password
ensure_strong_password encryption-modifier

json_field() {
  local path=$1
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(open(sys.argv[1]).read().rstrip("\n")))' "${path}"
}

write_policy() {
  local role=$1
  {
    tr -d '\n' <"${vault_token_file}"
    printf '\npath "kv/data/shuffle/%s" {\n  capabilities = ["read"]\n}\n' "${role}"
  } | vault_exec "vault policy write shuffle-${role} - >/dev/null"
}

write_role() {
  local role=$1 service_account=$2
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | vault_exec \
    "vault write auth/kubernetes/role/shuffle-${role} \
       bound_service_account_names=${service_account} \
       bound_service_account_namespaces=shuffle \
       audience=vault token_policies=shuffle-${role} token_no_default_policy=true \
       token_ttl=10m token_max_ttl=30m >/dev/null"
}

write_kv() {
  local role=$1 payload=$2
  {
    tr -d '\n' <"${vault_token_file}"
    printf '\n%s\n' "${payload}"
  } | vault_exec \
    "umask 077; cat >/tmp/soar-dash-01-${role}.json; \
     vault kv put kv/shuffle/${role} @/tmp/soar-dash-01-${role}.json >/dev/null; \
     rm -f /tmp/soar-dash-01-${role}.json"
}

opensearch_payload=$(printf '{"admin_password":%s}' \
  "$(json_field "${secret_dir}/opensearch-admin-password")")

# backend는 opensearch admin_password도 읽어야 하므로 두 policy에 kv/shuffle/opensearch를 함께
# 허용하지 않고, 대신 opensearch admin_password를 backend용 KV에도 복사해 둔다(같은 값,
# 두 KV path). backend policy가 kv/shuffle/opensearch를 직접 읽게 하면 opensearch ServiceAccount
# 전용 경로 분리 원칙이 깨진다.
backend_payload=$(printf '{"opensearch_admin_password":%s,"encryption_modifier":%s}' \
  "$(json_field "${secret_dir}/opensearch-admin-password")" \
  "$(json_field "${secret_dir}/encryption-modifier")")

write_policy opensearch
write_policy backend
write_role opensearch shuffle-opensearch
write_role backend shuffle-backend
write_kv opensearch "${opensearch_payload}"
write_kv backend "${backend_payload}"

vault_check || {
  echo 'provision 실패: Vault policy·role·KV 최종 확인에 실패했다.' >&2
  exit 1
}
echo 'Provision=PASS secret_input=0600 policy=shuffle-opensearch,shuffle-backend role=shuffle-opensearch,shuffle-backend kv=kv/shuffle/{opensearch,backend}'
