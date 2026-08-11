#!/usr/bin/env bash
# WAZUH-02-FIX-01은 기존 kv/wazuh/dashboard에 OIDC client secret 한 key만 추가한다.
set -Eeuo pipefail

usage() {
  echo '사용법: ./gitops/tools/wazuh-02-fix-01/provision-vault.sh --check|--apply|--rollback' >&2
}

readonly mode=${1:-}
case ${mode} in
  --check|--apply|--rollback) ;;
  *) usage; exit 2 ;;
esac

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly wazuh_secret_dir=${WAZUH01_SECRET_DIR:-${secret_root}/wazuh}
readonly client_secret_file=${WAZUH02_OIDC_CLIENT_SECRET_FILE:-${wazuh_secret_dir}/wazuh-oidc-client-secret}
readonly vault_token_file=${secret_root}/vault-root.token
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

case ${wazuh_secret_dir} in
  /|/home|/home/*/projects|/home/*/projects/*) echo 'Wazuh secret directory가 너무 넓다.' >&2; exit 1 ;;
esac
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo '인증된 k3s known_hosts 파일이 없다.' >&2; exit 1;
}
[[ -f ${vault_token_file} && ! -L ${vault_token_file} && $(stat -c %a "${vault_token_file}") == 600 ]] || {
  echo 'Vault root token file이 없거나 mode 0600이 아니다.' >&2; exit 1;
}

client_secret_valid() {
  [[ -f ${client_secret_file} && ! -L ${client_secret_file} &&
     $(stat -c %a "${client_secret_file}") == 600 ]] || return 1
  [[ $(wc -c <"${client_secret_file}") -eq 49 && $(wc -l <"${client_secret_file}") -eq 1 ]] || return 1
  [[ $(tail -c 1 "${client_secret_file}" | od -An -tu1 | tr -d ' ') == 10 ]] || return 1
  head -n 1 "${client_secret_file}" | LC_ALL=C grep -Eq '^[A-Za-z0-9]{48}$'
}

exec 9>/tmp/wazuh-02-fix-01-vault-provision.lock
flock -n 9 || { echo '다른 WAZUH-02-FIX-01 Vault provisioning이 실행 중이다.' >&2; exit 1; }

vault_exec() {
  local script=$1
  # shellcheck disable=SC2029
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; ${script}'"
}

vault_key_exists() {
  { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | vault_exec \
    'vault kv get -field=oidc_client_secret kv/wazuh/dashboard >/dev/null 2>&1'
}

vault_secret_matches_local() {
  local expected_hash
  # Vault `kv get -field` emits the field bytes without the local input file's
  # terminal newline, so compare exactly those 48 secret bytes rather than the
  # canonical input file representation.
  expected_hash=$(head -n 1 "${client_secret_file}" | tr -d '\n' | sha256sum | awk '{print $1}')
  {
    tr -d '\n' <"${vault_token_file}"
    printf '\n%s\n' "${expected_hash}"
  } | vault_exec '
    read -r expected_hash
    actual_hash=$(vault kv get -field=oidc_client_secret kv/wazuh/dashboard | sha256sum | awk "{print \$1}")
    test "${actual_hash}" = "${expected_hash}"
  '
}

case ${mode} in
  --check)
    if ! client_secret_valid; then
      echo 'VaultWazuhOidc=PENDING local-client-secret'
      exit 0
    fi
    vault_key_exists && vault_secret_matches_local || {
      echo 'VaultWazuhOidc=PENDING kv/wazuh/dashboard.oidc_client_secret'
      exit 0
    }
    echo 'VaultWazuhOidc=PASS path=kv/wazuh/dashboard key=oidc_client_secret'
    ;;
  --apply)
    client_secret_valid || { echo 'Wazuh OIDC client secret input이 mode 0600 canonical file이 아니다.' >&2; exit 1; }
    payload=$(mktemp)
    cleanup() { find "${payload}" -type f -delete 2>/dev/null || true; }
    trap cleanup EXIT INT TERM
    jq -n --rawfile secret "${client_secret_file}" '{oidc_client_secret:($secret | rtrimstr("\n"))}' >"${payload}"
    {
      tr -d '\n' <"${vault_token_file}"
      printf '\n'
      cat "${payload}"
    } | vault_exec '
      umask 077
      payload=/tmp/wazuh-02-fix-01-vault.json
      cat >"${payload}"
      vault kv patch kv/wazuh/dashboard @"${payload}" >/dev/null
      find /tmp -maxdepth 1 -type f -name wazuh-02-fix-01-vault.json -delete
    '
    vault_key_exists && vault_secret_matches_local || {
      echo 'Vault OIDC key 적용 후 일치 검증에 실패했다.' >&2; exit 1;
    }
    echo 'VaultWazuhOidc=PASS path=kv/wazuh/dashboard key=oidc_client_secret'
    ;;
  --rollback)
    { tr -d '\n' <"${vault_token_file}"; printf '\n'; } | vault_exec \
      'vault kv patch -remove-data=oidc_client_secret kv/wazuh/dashboard >/dev/null 2>&1 || true'
    if vault_key_exists; then
      echo 'Vault OIDC key rollback 뒤에도 남아 있다.' >&2; exit 1
    fi
    echo 'VaultWazuhOidc=ROLLBACK path=kv/wazuh/dashboard key=oidc_client_secret removed'
    ;;
esac
