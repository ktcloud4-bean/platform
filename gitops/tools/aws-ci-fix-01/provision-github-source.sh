#!/usr/bin/env bash
# shellcheck disable=SC2029,SC1083
# AWS-CI-FIX-01의 GitHub read-only deploy key와 Vault consumer field만 소유한다.
set -Eeuo pipefail

readonly mode=${1:-}
[[ ${mode} == --check || ${mode} == --apply || ${mode} == --destroy ]] || {
  echo 'usage: provision-github-source.sh --check|--apply|--destroy' >&2
  exit 2
}

readonly secret_root=${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly github_repo=ktcloud4-bean/platform
readonly deploy_key_title=AWS-CI-FIX-01-jenkins-readonly-20260810

fail() {
  echo "AWS-CI-FIX-01 GitHub source provisioning 실패: $*" >&2
  exit 1
}

for command in base64 gh jq ssh ssh-keygen stat; do
  command -v "${command}" >/dev/null || fail "${command} command가 없다."
done
[[ -f ${vault_root_token_file} && ! -L ${vault_root_token_file} &&
   $(stat -c %u "${vault_root_token_file}") -eq $(id -u) &&
   $(stat -c %a "${vault_root_token_file}") == 600 ]] \
  || fail 'Vault root token은 호출자 소유 mode 0600 일반 파일이어야 한다.'
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || fail '인증된 k3s known_hosts가 없다.'
gh auth status >/dev/null 2>&1 || fail 'GitHub API 인증이 없다.'

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)

umask 077
temp_dir=$(mktemp -d /dev/shm/aws-ci-fix-01-github.XXXXXX)
created_key_id=
vault_written=false
transaction_complete=false

vault_exec() {
  {
    tr -d '\n' <"${vault_root_token_file}"
    printf '\n'
    cat
  } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
      set -eu
      read -r VAULT_TOKEN
      export VAULT_TOKEN
      exec sh -eu
    '"
}

read_runtime() {
  printf 'vault kv get -format=json kv/jenkins/runtime\n' | vault_exec
}

write_runtime_data() {
  local data_file=$1
  {
    tr -d '\n' <"${vault_root_token_file}"
    printf '\n'
    base64 -w0 <"${data_file}"
    printf '\n'
  } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
      set -eu
      read -r VAULT_TOKEN
      export VAULT_TOKEN
      read -r payload
      runtime_file=\$(mktemp /tmp/aws-ci-fix-01-runtime.XXXXXX)
      trap '\''rm -f -- "\${runtime_file}"'\'' EXIT INT TERM
      printf %s "\${payload}" | base64 -d >"\${runtime_file}"
      vault kv put kv/jenkins/runtime @"\${runtime_file}" >/dev/null
    '"
}

cleanup() {
  local exit_code=$?
  if [[ ${transaction_complete} == false && ${mode} == --apply ]]; then
    if [[ ${vault_written} == true && -s ${temp_dir}/runtime-before-data.json ]]; then
      write_runtime_data "${temp_dir}/runtime-before-data.json" >/dev/null 2>&1 || true
    fi
    if [[ -n ${created_key_id} ]]; then
      gh api --method DELETE "repos/${github_repo}/keys/${created_key_id}" >/dev/null 2>&1 || true
    fi
  fi
  rm -rf -- "${temp_dir}"
  return "${exit_code}"
}
trap cleanup EXIT INT TERM

gh api --paginate "repos/${github_repo}/keys" >"${temp_dir}/github-keys.json"
jq --arg title "${deploy_key_title}" '[.[] | select(.title == $title)]' \
  "${temp_dir}/github-keys.json" >"${temp_dir}/owned-keys.json"
owned_count=$(jq 'length' "${temp_dir}/owned-keys.json")
[[ ${owned_count} -le 1 ]] || fail '같은 제목의 GitHub deploy key가 여러 개다.'
owned_key_id=$(jq -r '.[0].id // empty' "${temp_dir}/owned-keys.json")
owned_key_read_only=$(jq -r '.[0].read_only // empty' "${temp_dir}/owned-keys.json")

read_runtime >"${temp_dir}/runtime-before.json"
jq '.data.data' "${temp_dir}/runtime-before.json" >"${temp_dir}/runtime-before-data.json"
jq -r '.data.data.github_platform_ssh_private_key // empty' \
  "${temp_dir}/runtime-before.json" >"${temp_dir}/private-key"
vault_key_present=false
[[ -s ${temp_dir}/private-key ]] && vault_key_present=true

verify_pair() {
  [[ ${owned_count} == 1 && ${owned_key_read_only} == true && ${vault_key_present} == true ]] \
    || fail "deploy key/Vault field 상태가 완결되지 않았다: github=${owned_count} vault=${vault_key_present}"
  chmod 0600 "${temp_dir}/private-key"
  ssh-keygen -y -f "${temp_dir}/private-key" >"${temp_dir}/derived-public-key"
  github_public=$(jq -r '.[0].key' "${temp_dir}/owned-keys.json" | awk '{print $1" "$2}')
  derived_public=$(awk '{print $1" "$2}' "${temp_dir}/derived-public-key")
  [[ -n ${github_public} && ${github_public} == "${derived_public}" ]] \
    || fail 'Vault private key와 GitHub deploy key가 같은 keypair가 아니다.'
}

case ${mode} in
  --check)
    verify_pair
    echo "AWS-CI-FIX-01 GitHubSource=PASS repo=${github_repo} deploy-key-id=${owned_key_id} read-only=true vault-field=present"
    ;;
  --apply)
    [[ ${owned_count} == 0 && ${vault_key_present} == false ]] \
      || fail "기존 credential을 덮어쓰지 않는다: github=${owned_count} vault=${vault_key_present}"
    ssh-keygen -q -t ed25519 -N '' -C "${deploy_key_title}" -f "${temp_dir}/new-key"
    jq -n \
      --arg title "${deploy_key_title}" \
      --arg key "$(<"${temp_dir}/new-key.pub")" \
      '{title: $title, key: $key, read_only: true}' >"${temp_dir}/create-key.json"
    gh api --method POST "repos/${github_repo}/keys" \
      --input "${temp_dir}/create-key.json" >"${temp_dir}/created-key.json"
    created_key_id=$(jq -er 'select(.read_only == true) | .id' "${temp_dir}/created-key.json")

    jq --rawfile key "${temp_dir}/new-key" \
      '. + {github_platform_ssh_private_key: $key}' \
      "${temp_dir}/runtime-before-data.json" >"${temp_dir}/runtime-after-data.json"
    write_runtime_data "${temp_dir}/runtime-after-data.json"
    vault_written=true

    gh api --paginate "repos/${github_repo}/keys" >"${temp_dir}/github-keys.json"
    jq --arg title "${deploy_key_title}" '[.[] | select(.title == $title)]' \
      "${temp_dir}/github-keys.json" >"${temp_dir}/owned-keys.json"
    owned_count=$(jq 'length' "${temp_dir}/owned-keys.json")
    owned_key_id=$(jq -r '.[0].id // empty' "${temp_dir}/owned-keys.json")
    owned_key_read_only=$(jq -r '.[0].read_only // empty' "${temp_dir}/owned-keys.json")
    cp "${temp_dir}/new-key" "${temp_dir}/private-key"
    vault_key_present=true
    verify_pair
    transaction_complete=true
    echo "AWS-CI-FIX-01 GitHubSource=APPLIED repo=${github_repo} deploy-key-id=${owned_key_id} read-only=true vault-field=present"
    ;;
  --destroy)
    if [[ ${owned_count} == 0 && ${vault_key_present} == false ]]; then
      transaction_complete=true
      echo "AWS-CI-FIX-01 GitHubSource=ABSENT repo=${github_repo}"
      exit 0
    fi
    if [[ ${owned_count} == 1 && ${vault_key_present} == true ]]; then
      verify_pair
    else
      fail "foreign/partial credential 상태라 자동 제거하지 않는다: github=${owned_count} vault=${vault_key_present}"
    fi
    gh api --method DELETE "repos/${github_repo}/keys/${owned_key_id}" >/dev/null
    jq 'del(.github_platform_ssh_private_key)' \
      "${temp_dir}/runtime-before-data.json" >"${temp_dir}/runtime-after-data.json"
    write_runtime_data "${temp_dir}/runtime-after-data.json"
    transaction_complete=true
    echo "AWS-CI-FIX-01 GitHubSource=DESTROYED repo=${github_repo} deploy-key=absent vault-field=absent"
    ;;
esac
