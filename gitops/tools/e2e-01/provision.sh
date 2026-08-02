#!/usr/bin/env bash
# E2E-01이 소비할 최소 파생 KV/policy/auth role만 선언한다. 비밀 원문은 출력하지 않는다.
# shellcheck disable=SC2029
set -Eeuo pipefail

mode=${1:-}
if [[ ${mode} != --check && ${mode} != --apply && ${mode} != --destroy ]]; then
  echo "사용법: $0 --check|--apply|--destroy" >&2
  exit 2
fi

readonly secret_root=${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly jenkins_policy=${repo_root}/infra/vault/scripts/policies/e2e-01-jenkins.hcl
readonly verifier_policy=${repo_root}/infra/vault/scripts/policies/e2e-01-verifier.hcl

[[ -f ${vault_root_token_file} && ! -L ${vault_root_token_file} && \
   $(stat -c %u "${vault_root_token_file}") -eq $(id -u) && \
   $(stat -c %a "${vault_root_token_file}") == 600 ]] || {
  echo "Vault root token 입력은 호출자 소유 mode 0600 일반 파일이어야 한다." >&2
  exit 1
}
case ${vault_root_token_file} in
  "${repo_root}" | "${repo_root}"/*)
    echo "Vault root token 입력은 저장소 밖이어야 한다." >&2
    exit 1
    ;;
esac
[[ -s ${jenkins_policy} && -s ${verifier_policy} ]]
command -v jq >/dev/null

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)

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

if [[ ${mode} == --destroy ]]; then
  vault_exec <<'REMOTE' >/dev/null
vault write auth/kubernetes/role/jenkins \
  bound_service_account_names=jenkins \
  bound_service_account_namespaces=jenkins \
  audience=vault token_policies=jenkins token_no_default_policy=true \
  token_ttl=10m token_max_ttl=15m >/dev/null
vault delete auth/kubernetes/role/e2e-01-verifier >/dev/null 2>&1 || true
vault policy delete e2e-01-jenkins >/dev/null 2>&1 || true
vault policy delete e2e-01-verifier >/dev/null 2>&1 || true
vault kv metadata delete kv/e2e-01/jenkins >/dev/null 2>&1 || true
vault kv metadata delete kv/e2e-01/runtime >/dev/null 2>&1 || true
REMOTE
  echo "E2E-01 Vault 파생 경계 제거 완료"
  exit 0
fi

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  local status=$?
  find "${temp_dir}" -type f -delete 2>/dev/null || true
  rmdir "${temp_dir}" 2>/dev/null || true
  return "${status}"
}
trap cleanup EXIT INT TERM

vault_exec >"${temp_dir}/source-jenkins.json" <<'REMOTE'
vault kv get -format=json kv/jenkins/runtime
REMOTE
vault_exec >"${temp_dir}/source-sonar.json" <<'REMOTE'
vault kv get -format=json kv/sonarqube/verification
REMOTE
jq -e '
  (.data.data.cosign_public_key | type == "string" and length > 0) and
  (.data.data.cosign_previous_public_key | type == "string" and length > 0) and
  (.data.data.harbor_robot_name | type == "string" and length > 0) and
  (.data.data.harbor_robot_secret | type == "string" and length > 0)
' "${temp_dir}/source-jenkins.json" >/dev/null
jq -e '(.data.data.pass_token | type == "string" and length > 0)' \
  "${temp_dir}/source-sonar.json" >/dev/null
jq '.data.data | {
  cosign_public_key,
  cosign_previous_public_key,
  harbor_robot_name,
  harbor_robot_secret
}' "${temp_dir}/source-jenkins.json" >"${temp_dir}/runtime.json"
jq '.data.data | {sonar_token: .pass_token}' \
  "${temp_dir}/source-sonar.json" >"${temp_dir}/jenkins.json"

if [[ ${mode} == --apply ]]; then
  {
    printf "cat >/tmp/e2e-01-jenkins.hcl <<'E2EJENKINS'\n"
    cat "${jenkins_policy}"
    printf 'E2EJENKINS\n'
    printf "cat >/tmp/e2e-01-verifier.hcl <<'E2EVERIFIER'\n"
    cat "${verifier_policy}"
    printf 'E2EVERIFIER\n'
    printf "cat >/tmp/e2e-01-runtime.json <<'E2ERUNTIME'\n"
    cat "${temp_dir}/runtime.json"
    printf 'E2ERUNTIME\n'
    printf "cat >/tmp/e2e-01-jenkins.json <<'E2EJENKINSKV'\n"
    cat "${temp_dir}/jenkins.json"
    printf 'E2EJENKINSKV\n'
    cat <<'REMOTE'
trap 'find /tmp/e2e-01-* -type f -delete 2>/dev/null || true' EXIT
umask 077
vault policy write e2e-01-jenkins /tmp/e2e-01-jenkins.hcl >/dev/null
vault policy write e2e-01-verifier /tmp/e2e-01-verifier.hcl >/dev/null
vault kv put kv/e2e-01/runtime @/tmp/e2e-01-runtime.json >/dev/null
vault kv put kv/e2e-01/jenkins @/tmp/e2e-01-jenkins.json >/dev/null
vault write auth/kubernetes/role/e2e-01-verifier \
  bound_service_account_names=e2e-01-vault-bootstrap \
  bound_service_account_namespaces=e2e-01 \
  audience=vault token_policies=e2e-01-verifier token_no_default_policy=true \
  token_ttl=10m token_max_ttl=15m >/dev/null
vault write auth/kubernetes/role/jenkins \
  bound_service_account_names=jenkins \
  bound_service_account_namespaces=jenkins \
  audience=vault token_policies=jenkins,e2e-01-jenkins token_no_default_policy=true \
  token_ttl=10m token_max_ttl=15m >/dev/null
REMOTE
  } | vault_exec >/dev/null
fi

if ! vault_exec >"${temp_dir}/derived-runtime.json" 2>/dev/null <<'REMOTE'
vault kv get -format=json kv/e2e-01/runtime
REMOTE
then
  echo "E2E-01 Vault 파생 경계: absent"
  exit 0
fi
if ! vault_exec >"${temp_dir}/derived-jenkins.json" 2>/dev/null <<'REMOTE'
vault kv get -format=json kv/e2e-01/jenkins
REMOTE
then
  echo "E2E-01 Vault 파생 경계: absent"
  exit 0
fi
if ! vault_exec >"${temp_dir}/role.json" 2>/dev/null <<'REMOTE'
vault read -format=json auth/kubernetes/role/e2e-01-verifier
REMOTE
then
  echo "E2E-01 Vault 파생 경계: absent"
  exit 0
fi
if ! vault_exec >"${temp_dir}/jenkins-role.json" 2>/dev/null <<'REMOTE'
vault read -format=json auth/kubernetes/role/jenkins
REMOTE
then
  echo "E2E-01 Vault 파생 경계: absent"
  exit 0
fi

jq -e --slurpfile source "${temp_dir}/source-jenkins.json" '
  .data.data == ($source[0].data.data | {
    cosign_public_key,
    cosign_previous_public_key,
    harbor_robot_name,
    harbor_robot_secret
  })
' "${temp_dir}/derived-runtime.json" >/dev/null
jq -e --slurpfile source "${temp_dir}/source-sonar.json" '
  .data.data == {sonar_token: $source[0].data.data.pass_token}
' "${temp_dir}/derived-jenkins.json" >/dev/null
jq -e '
  .data.bound_service_account_names == ["e2e-01-vault-bootstrap"] and
  .data.bound_service_account_namespaces == ["e2e-01"] and
  .data.audience == "vault" and
  .data.token_policies == ["e2e-01-verifier"] and
  .data.token_no_default_policy == true
' "${temp_dir}/role.json" >/dev/null
jq -e '
  .data.bound_service_account_names == ["jenkins"] and
  .data.bound_service_account_namespaces == ["jenkins"] and
  .data.audience == "vault" and
  (.data.token_policies | sort) == ["e2e-01-jenkins", "jenkins"] and
  .data.token_no_default_policy == true
' "${temp_dir}/jenkins-role.json" >/dev/null
echo "E2E-01 Vault 파생 경계: match"
