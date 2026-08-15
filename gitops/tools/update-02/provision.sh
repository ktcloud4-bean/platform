#!/usr/bin/env bash
# UPDATE-02: Renovate GitHub token 주입 및 Vault runtime bundle, Kubernetes auth role/policy 선언.
# shellcheck disable=SC2029
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법: gitops/tools/update-02/provision.sh --check|--apply|--destroy

--check   안전한 메타데이터와 선언 일치만 읽고 변경하지 않는다.
--apply   GitHub Renovate 토큰을 검증하고 Vault policy/role/KV(github_token)를 구성한다.
--destroy Application과 workload가 제거된 뒤 UPDATE-02가 만든 Vault runtime 객체를 rollback한다.

비밀값은 출력하지 않는다. GitHub Renovate 입력과 Vault root token은 저장소 밖 mode 0600
파일에서 읽고, runtime token은 mode 0700 임시 디렉터리에서 Vault로 직접 옮긴다.
EOF
}

mode=${1:-}
if [[ "${mode}" != --check && "${mode}" != --apply && "${mode}" != --destroy ]]; then
  usage >&2
  exit 2
fi

: "${KTC_SECRET_ROOT:=$HOME/secrets/ktcloud4-bean}"
readonly github_env=${RENOVATE_GITHUB_ENV_FILE:-"$KTC_SECRET_ROOT/renovate/github.env"}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-"$KTC_SECRET_ROOT/vault-root.token"}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly target_owner=ktcloud4-bean
readonly target_repo=hr-system
readonly target_slug=${target_owner}/${target_repo}

repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly policy_file=${repo_root}/infra/vault/scripts/policies/renovate.hcl

ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

check_private_file() {
  local path=$1
  [[ -f "${path}" && ! -L "${path}" ]] || {
    echo "일반 non-symlink 파일이 아니다: ${path}" >&2
    exit 1
  }
  [[ "$(stat -c %u "${path}")" -eq "$(id -u)" && "$(stat -c %a "${path}")" == 600 ]] || {
    echo "파일은 호출자 소유 mode 0600이어야 한다: ${path}" >&2
    exit 1
  }
}

for private_input in "${github_env}" "${vault_root_token_file}"; do
  case "${private_input}" in
    "${repo_root}"|"${repo_root}"/*)
      echo "credential 입력은 저장소 밖이어야 한다: ${private_input}" >&2
      exit 1
      ;;
  esac
  check_private_file "${private_input}"
done
[[ -s "${policy_file}" ]] || {
  echo "Vault policy 파일을 찾을 수 없다: ${policy_file}" >&2
  exit 1
}

github_token=$(awk -F= '$1=="GITHUB_RENOVATE_TOKEN"{print substr($0,index($0,"=")+1)}' "${github_env}" | tr -d '\r\n')
[[ -n "${github_token}" ]] || {
  echo "GitHub Renovate token 입력이 비어 있다" >&2
  exit 1
}

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
token_file=${temp_dir}/token
policy_json=${temp_dir}/policy.json
role_json=${temp_dir}/role.json
kv_json=${temp_dir}/kv.json
api_response=${temp_dir}/api.json
runtime_payload=${temp_dir}/runtime.json

printf '%s' "${github_token}" >"${token_file}"
unset github_token

cleanup() {
  local status=$?
  rm -rf "${temp_dir}"
  return "${status}"
}
trap cleanup EXIT INT TERM

kube() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}

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

verify_github_token() {
  local http_code
  http_code=$(curl --silent --show-error \
    --header "Authorization: Bearer $(tr -d '\r\n' <"${token_file}")" \
    --header "Accept: application/vnd.github+json" \
    --header "User-Agent: update-02-provisioner" \
    --output "${api_response}" --write-out '%{http_code}' \
    "https://api.github.com/repos/${target_slug}")
  [[ "${http_code}" == 200 ]] || {
    echo "GitHub repository 조회 실패: target=${target_slug} HTTP ${http_code}" >&2
    return 1
  }
  jq -e '.permissions.push == true' "${api_response}" >/dev/null || {
    echo "GitHub token이 target repo(${target_slug})의 push 권한을 가지고 있지 않다" >&2
    return 1
  }
}

role_matches() {
  jq -e '
    .data.bound_service_account_names == ["renovate"] and
    .data.bound_service_account_namespaces == ["renovate"] and
    .data.audience == "vault" and .data.token_policies == ["renovate"] and
    .data.token_no_default_policy == true and .data.token_ttl == 600 and
    .data.token_max_ttl == 900
  ' "${role_json}" >/dev/null
}

read_vault_state() {
  vault_exec <<'REMOTE' >"${policy_json}"
if vault policy read -format=json renovate 2>/dev/null; then :; else printf '%s\n' '{"policy":null}'; fi
REMOTE
  vault_exec <<'REMOTE' >"${role_json}"
if vault read -format=json auth/kubernetes/role/renovate 2>/dev/null; then :; else printf '%s\n' '{"data":null}'; fi
REMOTE
  vault_exec <<'REMOTE' >"${kv_json}"
if vault kv get -format=json kv/renovate/runtime 2>/dev/null; then :; else printf '%s\n' '{"data":null}'; fi
REMOTE
}

existing_matches() {
  verify_github_token || return 1
  jq -e --rawfile expected "${policy_file}" '.policy == $expected' "${policy_json}" >/dev/null \
    || { echo "UPDATE-02 mismatch: Vault policy" >&2; return 1; }
  role_matches || { echo "UPDATE-02 mismatch: Vault Kubernetes auth role" >&2; return 1; }
  jq -e '
    (.data.data | keys | sort) == (["github_token"] | sort)
  ' "${kv_json}" >/dev/null || { echo "UPDATE-02 mismatch: Vault KV key set (expected [github_token])" >&2; return 1; }
}

read_vault_state

if [[ "${mode}" == --check ]]; then
  if existing_matches; then
    echo "UPDATE-02 --check: GitHub token push 권한 확인, Vault policy/role/KV(github_token) 일치"
    exit 0
  else
    echo "UPDATE-02 --check: Vault 상태 또는 GitHub 토큰이 일치하지 않는다." >&2
    exit 1
  fi
fi

if [[ "${mode}" == --destroy ]]; then
  application_status=$(kube -n argocd get application renovate --ignore-not-found -o name)
  [[ -z "${application_status}" ]] || {
    echo "Application/renovate가 남아 있어 credential을 제거하지 않는다." >&2
    exit 1
  }
  vault_exec <<'REMOTE' >/dev/null
vault kv metadata delete kv/renovate/runtime >/dev/null 2>&1 || true
vault delete auth/kubernetes/role/renovate >/dev/null 2>&1 || true
vault policy delete renovate >/dev/null 2>&1 || true
REMOTE
  echo "UPDATE-02 rollback: Vault KV/role/policy 제거 완료"
  exit 0
fi

# --apply mode
verify_github_token || {
  echo "GitHub token 검증 실패" >&2
  exit 1
}

# 1. Apply Vault policy and role
{
  printf "cat > /tmp/update02-renovate-policy.hcl <<'HCL'\n"
  cat "${policy_file}"
  printf "HCL\n"
  cat <<'REMOTE'
vault policy write renovate /tmp/update02-renovate-policy.hcl >/dev/null
rm -f /tmp/update02-renovate-policy.hcl
vault write auth/kubernetes/role/renovate \
  bound_service_account_names=renovate \
  bound_service_account_namespaces=renovate \
  audience=vault token_policies=renovate token_no_default_policy=true \
  token_ttl=10m token_max_ttl=15m >/dev/null
REMOTE
} | vault_exec
echo "UPDATE-02 apply stage: vault-policy-role=configured"

# 2. Put github_token into kv/renovate/runtime
jq -n \
  --rawfile github_token "${token_file}" \
  '{
    github_token:($github_token|rtrimstr("\n")|rtrimstr("\r"))
  }' >"${runtime_payload}"

{
  tr -d '\n' <"${vault_root_token_file}"
  printf '\n'
  cat "${runtime_payload}"
} | ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
    set -eu
    umask 077
    read -r VAULT_TOKEN
    export VAULT_TOKEN
    trap \"rm -f /tmp/update02-runtime.json\" EXIT
    cat > /tmp/update02-runtime.json
    vault kv put kv/renovate/runtime @/tmp/update02-runtime.json >/dev/null
  '"
echo "UPDATE-02 apply stage: vault-kv=configured"

# 3. Final verification
read_vault_state
existing_matches || {
  echo "UPDATE-02 최종 선언 일치 검증 실패" >&2
  exit 1
}

echo "UPDATE-02 apply: GitHub token 권한 검증, Vault policy/role/KV(github_token) 적용 검증 통과"
