#!/usr/bin/env bash
# WAZUH-02 Vault provisioning.
#
# Dashboard 전용 Vault policy·Kubernetes auth role·kv/wazuh/dashboard만 새로 만든다.
# 새 credential은 생성하지 않는다: root CA와 admin 비밀번호는 WAZUH-01의 provision.sh가
# 이미 만든 로컬 입력(${secret_dir}/root-ca.pem, indexer-admin-password)을, Wazuh API
# 비밀번호는 같은 wazuh-01 provision의 api-password를 그대로 재사용한다. WAZUH-01이 만든
# indexer·manager·bootstrap policy/role/kv는 건드리지 않는다.
set -euo pipefail

readonly mode=${1:-check}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly secret_dir=${secret_root}/wazuh
readonly vault_token_file=${secret_root}/vault-root.token
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ ${mode} == check || ${mode} == apply || ${mode} == rollback ]] || {
  echo 'usage: provision.sh [check|apply|rollback]' >&2
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
[[ -f ${secret_dir}/root-ca.pem && -f ${secret_dir}/indexer-admin-password && -f ${secret_dir}/api-password ]] || {
  echo 'provision 실패: WAZUH-01 provision.sh apply를 먼저 실행해야 한다(root-ca.pem·indexer-admin-password·api-password 없음).' >&2
  exit 1
}

exec 9>/tmp/wazuh-02-provision.lock
flock -n 9 || {
  echo 'provision 실패: 다른 WAZUH-02 provisioning이 실행 중이다.' >&2
  exit 1
}

vault_exec() {
  local script=$1
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; ${script}'"
}

vault_check() {
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | vault_exec \
    'vault policy read wazuh-dashboard >/dev/null &&
     vault read auth/kubernetes/role/wazuh-dashboard >/dev/null &&
     vault kv metadata get kv/wazuh/dashboard >/dev/null'
}

if [[ ${mode} == check ]]; then
  if vault_check; then
    echo 'VaultRuntime=PASS policy=wazuh-dashboard kv=kv/wazuh/dashboard'
  else
    echo 'VaultRuntime=ABSENT'
  fi
  exit 0
fi

if [[ ${mode} == rollback ]]; then
  # Dashboard 전용 policy·role·kv만 지운다. indexer·manager·bootstrap의 policy/role/kv,
  # 로컬 secret 입력(${secret_dir})은 건드리지 않는다.
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | vault_exec \
    'vault kv metadata delete kv/wazuh/dashboard >/dev/null 2>&1 || true
     vault delete auth/kubernetes/role/wazuh-dashboard >/dev/null 2>&1 || true
     vault policy delete wazuh-dashboard >/dev/null 2>&1 || true'
  vault_check && {
    echo 'provision 실패: rollback 뒤에도 wazuh-dashboard policy/role/kv가 남아 있다.' >&2
    exit 1
  }
  echo 'Rollback=PASS policy=wazuh-dashboard role=wazuh-dashboard kv=kv/wazuh/dashboard removed'
  exit 0
fi

json_field() {
  local path=$1
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(open(sys.argv[1]).read().rstrip("\n")))' "${path}"
}

{
  tr -d '\n' <"${vault_token_file}"
  printf '\npath "kv/data/wazuh/dashboard" {\n  capabilities = ["read"]\n}\n'
} | vault_exec "vault policy write wazuh-dashboard - >/dev/null"

{ tr -d '\n' <"${vault_token_file}"; printf '\n'; } | vault_exec \
  "vault write auth/kubernetes/role/wazuh-dashboard \
     bound_service_account_names=wazuh-dashboard \
     bound_service_account_namespaces=wazuh \
     audience=vault token_policies=wazuh-dashboard token_no_default_policy=true \
     token_ttl=10m token_max_ttl=30m >/dev/null"

dashboard_payload=$(printf '{"root_ca_pem":%s,"dashboard_username":"admin","dashboard_password":%s,"api_username":"wazuh-01-api","api_password":%s}' \
  "$(json_field "${secret_dir}/root-ca.pem")" \
  "$(json_field "${secret_dir}/indexer-admin-password")" \
  "$(json_field "${secret_dir}/api-password")")

{
  tr -d '\n' <"${vault_token_file}"
  printf '\n%s\n' "${dashboard_payload}"
} | vault_exec \
  "umask 077; cat >/tmp/wazuh-02-dashboard.json; \
   vault kv put kv/wazuh/dashboard @/tmp/wazuh-02-dashboard.json >/dev/null; \
   rm -f /tmp/wazuh-02-dashboard.json"

vault_check || {
  echo 'provision 실패: Vault policy·role·KV 최종 확인에 실패했다.' >&2
  exit 1
}
echo 'Provision=PASS policy=wazuh-dashboard role=wazuh-dashboard kv=kv/wazuh/dashboard'
