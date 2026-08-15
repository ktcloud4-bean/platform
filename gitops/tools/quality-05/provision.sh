#!/usr/bin/env bash
# QUALITY-05의 제품 project/token과 Jenkins Vault 파생 경계를 준비한다.
# SonarQube URL은 호출자가 port-forward로 제공하며, secret 원문은 출력하지 않는다.
set -Eeuo pipefail

mode=${1:-}
if [[ ${mode} != --check && ${mode} != --apply ]]; then
  echo "사용법: SONAR_URL=http://127.0.0.1:39005 ${0} --check|--apply" >&2
  exit 2
fi

readonly repo_root=$(git rev-parse --show-toplevel)
readonly sonar_url=${SONAR_URL:-http://127.0.0.1:39005}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly sonar_env=${SONAR_ENV_FILE:-${secret_root}/sonarqube/env}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly kubeconfig=${KUBECONFIG:-/home/imcherry/.kube/k3s-01-admin.yaml}
readonly kubectl_bin=${KUBECTL_BIN:-kubectl}
readonly policy_file=${repo_root}/infra/vault/scripts/policies/hr-system-jenkins.hcl

[[ -f ${sonar_env} && ! -L ${sonar_env} && $(stat -c %a "${sonar_env}") == 600 ]] || {
  echo "SonarQube env는 regular mode 0600이어야 한다: ${sonar_env}" >&2
  exit 1
}
[[ -f ${vault_root_token_file} && ! -L ${vault_root_token_file} && \
   $(stat -c %a "${vault_root_token_file}") == 600 ]] || {
  echo "Vault root token 입력은 regular mode 0600이어야 한다." >&2
  exit 1
}
case ${vault_root_token_file} in
  "${repo_root}" | "${repo_root}"/*)
    echo "Vault root token 입력은 저장소 밖이어야 한다." >&2
    exit 1
    ;;
esac
[[ -s ${policy_file} ]] || {
  echo "정책 파일이 없다: ${policy_file}" >&2
  exit 1
}
command -v jq >/dev/null
command -v curl >/dev/null

SONARQUBE_ADMIN_PASSWORD=
while IFS='=' read -r key value; do
  case ${key} in
    SONARQUBE_ADMIN_PASSWORD) SONARQUBE_ADMIN_PASSWORD=${value} ;;
    SONARQUBE_DB_PASSWORD|'') ;;
    *) echo "지원하지 않는 SonarQube env key: ${key}" >&2; exit 1 ;;
  esac
done <"${sonar_env}"
readonly SONARQUBE_ADMIN_PASSWORD
[[ -n ${SONARQUBE_ADMIN_PASSWORD} ]] || {
  echo "SonarQube admin password가 없다." >&2
  exit 1
}

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
readonly netrc_file=${temp_dir}/netrc
readonly sonar_response=${temp_dir}/sonar-response.json
readonly role_file=${temp_dir}/jenkins-role.json
readonly vault_secret_file=${temp_dir}/sonar-token.json
readonly vault_metadata_file=${temp_dir}/vault-metadata.json
readonly vault_policy_file=${temp_dir}/vault-policy.txt

printf 'machine 127.0.0.1 login admin password %s\n' "${SONARQUBE_ADMIN_PASSWORD}" >"${netrc_file}"
chmod 0600 "${netrc_file}"
sonar_get() {
  curl --silent --show-error --fail --netrc-file "${netrc_file}" "$@"
}
sonar_post() {
  sonar_get --request POST "$@"
}
sonar_get "${sonar_url}/api/system/status" | jq -e '.status == "UP"' >/dev/null
sonar_get "${sonar_url}/api/authentication/validate" | jq -e '.valid == true' >/dev/null

vault_exec() {
  {
    tr -d '\n' <"${vault_root_token_file}"
    printf '\n'
    cat
  } | KUBECONFIG="${kubeconfig}" "${kubectl_bin}" -n vault exec -i vault-0 -- \
    sh -c 'set -eu; read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh -eu'
}

vault_exec >"${role_file}" <<'REMOTE'
vault read -format=json auth/kubernetes/role/jenkins
REMOTE
jq -e '
  .data.bound_service_account_names == ["jenkins"] and
  .data.bound_service_account_namespaces == ["jenkins"] and
  .data.audience == "vault" and
  .data.token_no_default_policy == true and
  (.data.token_policies | type == "array")
' "${role_file}" >/dev/null
current_policies=$(jq -r '.data.token_policies[]' "${role_file}")
case $'\n'"${current_policies}"$'\n' in
  *$'\nhr-system-jenkins\n'*) updated_policies=${current_policies//$'\n'/,} ;;
  *) updated_policies=${current_policies//$'\n'/,},hr-system-jenkins ;;
esac

project_count=$(sonar_get --get --data-urlencode projects=hr-system "${sonar_url}/api/projects/search" |
  jq '[.components[] | select(.key == "hr-system")] | length')
[[ ${project_count} -le 1 ]] || {
  echo "SonarQube hr-system project가 중복이다." >&2
  exit 1
}

gate_count=$(sonar_get "${sonar_url}/api/qualitygates/list" |
  jq '[.qualitygates[] | select(.name == "Sonar way")] | length')
[[ ${gate_count} -eq 1 ]] || {
  echo "Sonar way quality gate가 정확히 하나가 아니다." >&2
  exit 1
}

token_count=$(sonar_get "${sonar_url}/api/user_tokens/search" |
  jq '[.userTokens[] | select(.name == "hr-system-jenkins" and .type == "PROJECT_ANALYSIS_TOKEN")] | length')
[[ ${token_count} -le 1 ]] || {
  echo "hr-system-jenkins Sonar token 이름이 중복이다." >&2
  exit 1
}

vault_exec >"${vault_metadata_file}" 2>/dev/null <<'REMOTE' || true
vault kv get -format=json kv/hr-system/jenkins
REMOTE
vault_present=false
if jq -e '.data.data.sonar_token | type == "string" and length > 0' \
  "${vault_metadata_file}" >/dev/null 2>&1; then
  vault_present=true
fi

if [[ ${mode} == --check ]]; then
  [[ ${project_count} -eq 1 ]] || { echo "QUALITY-05 Sonar project: absent"; exit 1; }
  project_gate=$(sonar_get --get --data-urlencode project=hr-system \
    "${sonar_url}/api/qualitygates/get_by_project" | jq -r '.qualityGate.name // empty')
  [[ ${project_gate} == "Sonar way" ]] || {
    echo "QUALITY-05 project quality gate: ${project_gate:-absent}" >&2
    exit 1
  }
  [[ ${token_count} -eq 1 && ${vault_present} == true ]] || {
    echo "QUALITY-05 Sonar/Vault token boundary: incomplete" >&2
    exit 1
  }
  vault_exec >"${vault_policy_file}" <<'REMOTE'
vault policy read hr-system-jenkins
REMOTE
  grep -Fqx 'path "kv/data/hr-system/jenkins" {' "${vault_policy_file}"
  role_policies=$(jq -r '.data.token_policies | sort | join(",")' "${role_file}")
  [[ ${role_policies} == *hr-system-jenkins* ]] || {
    echo "QUALITY-05 Jenkins Vault role policy: absent" >&2
    exit 1
  }
  echo "QUALITY-05 Sonar project/gate/token/Vault boundary: match"
  exit 0
fi

if [[ ${project_count} -eq 0 ]]; then
  sonar_post --data-urlencode project=hr-system --data-urlencode name='HR System' \
    "${sonar_url}/api/projects/create" >/dev/null
fi
sonar_post --data-urlencode gateName='Sonar way' --data-urlencode projectKey=hr-system \
  "${sonar_url}/api/qualitygates/select" >/dev/null

if [[ ${token_count} -eq 0 && ${vault_present} == true ]]; then
  echo "Sonar token은 없는데 Vault secret이 남아 있어 자동 재발급하지 않는다." >&2
  exit 1
fi
if [[ ${token_count} -eq 0 ]]; then
  sonar_post --data-urlencode name=hr-system-jenkins \
    --data-urlencode type=PROJECT_ANALYSIS_TOKEN \
    --data-urlencode projectKey=hr-system \
    "${sonar_url}/api/user_tokens/generate" >"${sonar_response}"
  jq -e '.token | type == "string" and length > 0' "${sonar_response}" >/dev/null
  jq -r '.token' "${sonar_response}" >"${temp_dir}/sonar-token"
  jq -n --rawfile token "${temp_dir}/sonar-token" \
    '{sonar_token:($token | rtrimstr("\n"))}' >"${vault_secret_file}"
  vault_present=true
fi

if [[ ${vault_present} != true ]]; then
  echo "Sonar token은 존재하지만 Vault secret이 없어 자동으로 복구할 수 없다." >&2
  exit 1
fi

{
  printf "cat >/tmp/hr-system-jenkins.hcl <<'QUALITY05POLICY'\n"
  cat "${policy_file}"
  printf 'QUALITY05POLICY\n'
  if [[ -s ${vault_secret_file} ]]; then
    printf "cat >/tmp/hr-system-jenkins.json <<'QUALITY05SECRET'\n"
    cat "${vault_secret_file}"
    printf 'QUALITY05SECRET\n'
  fi
  cat <<REMOTE
trap 'find /tmp/hr-system-jenkins.hcl /tmp/hr-system-jenkins.json -type f -delete 2>/dev/null || true' EXIT
umask 077
vault policy write hr-system-jenkins /tmp/hr-system-jenkins.hcl >/dev/null
REMOTE
  if [[ -s ${vault_secret_file} ]]; then
    printf '%s\n' 'vault kv put kv/hr-system/jenkins @/tmp/hr-system-jenkins.json >/dev/null'
  fi
  printf 'vault write auth/kubernetes/role/jenkins token_policies=%q >/dev/null\n' "${updated_policies}"
} | vault_exec >/dev/null

echo "QUALITY-05 Sonar project/gate/token/Vault boundary: applied"
