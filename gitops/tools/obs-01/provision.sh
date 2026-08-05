#!/usr/bin/env bash
set -euo pipefail

readonly mode=${1:-check}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly secret_dir=${secret_root}/obs
readonly password_file=${secret_dir}/grafana-admin-password
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

exec 9>/tmp/obs-01-provision.lock
flock -n 9 || {
  echo 'provision 실패: 다른 OBS-01 provisioning이 실행 중이다.' >&2
  exit 1
}

vault_check() {
  # shellcheck disable=SC2029
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | \
    ssh "${ssh_options[@]}" "${k3s_host}" \
      "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault policy read obs-grafana >/dev/null && vault read auth/kubernetes/role/obs-grafana >/dev/null && vault kv metadata get kv/obs/grafana >/dev/null'"
}

if [[ ${mode} == check ]]; then
  if [[ -f ${password_file} && ! -L ${password_file} && $(stat -c %a "${password_file}") == 600 ]]; then
    echo 'SecretInput=PRESENT'
  else
    echo 'SecretInput=ABSENT'
  fi
  vault_check || {
    echo 'VaultRuntime=ABSENT'
    exit 0
  }
  echo 'VaultRuntime=PASS policy=obs-grafana role=obs-grafana kv=kv/obs/grafana'
  exit 0
fi

if [[ ! -f ${password_file} ]]; then
  install -d -m 0700 "${secret_dir}"
  umask 077
  openssl rand -base64 36 | tr -d '\n' >"${password_file}"
  printf '\n' >>"${password_file}"
fi
[[ ! -L ${password_file} && $(stat -c %a "${password_file}") == 600 ]] || {
  echo 'provision 실패: Grafana password input이 regular file mode 0600이 아니다.' >&2
  exit 1
}

# shellcheck disable=SC2029
{ tr -d '\n' <"${vault_token_file}"; printf '\n'; cat <<'HCL'
path "kv/data/obs/grafana" {
  capabilities = ["read"]
}
HCL
} | ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault policy write obs-grafana - >/dev/null'"

# shellcheck disable=SC2029
{ tr -d '\n' <"${vault_token_file}"; printf '\n'; } | \
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; vault write auth/kubernetes/role/obs-grafana bound_service_account_names=obs-grafana bound_service_account_namespaces=obs audience=vault token_policies=obs-grafana token_no_default_policy=true token_ttl=10m token_max_ttl=30m >/dev/null'"

# shellcheck disable=SC2029
{
  tr -d '\n' <"${vault_token_file}"
  printf '\n{"admin_password":"'
  tr -d '\n' <"${password_file}"
  printf '"}\n'
} | ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; umask 077; cat >/tmp/obs-01-grafana.json; trap \"rm -f /tmp/obs-01-grafana.json\" EXIT; if vault kv metadata get kv/obs/grafana >/dev/null 2>&1; then vault kv patch -method=rw kv/obs/grafana @/tmp/obs-01-grafana.json >/dev/null; else vault kv put kv/obs/grafana @/tmp/obs-01-grafana.json >/dev/null; fi'"

vault_check
echo 'Provision=PASS secret_input=0600 policy=obs-grafana role=obs-grafana kv=kv/obs/grafana'
