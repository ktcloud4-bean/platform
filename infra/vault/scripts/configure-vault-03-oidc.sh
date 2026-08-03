#!/usr/bin/env bash
# VAULT-03: Vault UI OIDC auth method, 전용 policy, identity group·group-alias만 만든다.
# init·unseal·seal migration과 VAULT-02가 만든 다른 mount·auth·policy는 건드리지 않는다.
set -Eeuo pipefail

: "${VAULT_ROOT_TOKEN_FILE:?저장소 밖 root token 파일 경로가 필요하다}"
: "${VAULT03_CLIENT_SECRET_FILE:?저장소 밖 VAULT-03 Keycloak client secret 파일 경로가 필요하다}"
K3S_HOST="${K3S_HOST:-rocky@10.10.20.10}"
KUBECTL="${KUBECTL:-sudo /usr/local/bin/k3s kubectl}"
KNOWN_HOSTS="${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"
POLICY_NAME=vault-ui-operator
POLICY_FILE="$(cd "$(dirname "$0")/policies" && pwd)/${POLICY_NAME}.hcl"
GROUP_NAME=vault-ui-platform-privileged
GROUP_ALIAS_NAME=/platform-privileged
ROLE_NAME=ui-viewer
REDIRECT_URI="https://vault.imcherry5778.xyz/ui/vault/auth/oidc/oidc/callback"
DISCOVERY_URL="https://sso.imcherry5778.xyz/realms/platform"

ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${KNOWN_HOSTS}"
)

[[ -r "${VAULT_ROOT_TOKEN_FILE}" ]] || { echo "root token 파일을 읽을 수 없다" >&2; exit 1; }
[[ "$(stat -c %a "${VAULT_ROOT_TOKEN_FILE}")" == 600 ]] || {
  echo "root token 파일은 mode 0600이어야 한다." >&2
  exit 1
}
[[ -r "${VAULT03_CLIENT_SECRET_FILE}" ]] || { echo "client secret 파일을 읽을 수 없다" >&2; exit 1; }
[[ "$(stat -c %a "${VAULT03_CLIENT_SECRET_FILE}")" == 600 ]] || {
  echo "client secret 파일은 mode 0600이어야 한다." >&2
  exit 1
}
[[ -s "${POLICY_FILE}" ]] || { echo "vault-ui-operator policy 파일이 없다" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq가 필요하다" >&2; exit 1; }

vault_exec() {
  { cat "${VAULT_ROOT_TOKEN_FILE}"; cat; } | ssh "${ssh_options[@]}" "${K3S_HOST}" \
    "${KUBECTL} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh'"
}

echo "== 1. auth/oidc 활성화(없으면) =="
auth_list_json=$(vault_exec <<'REMOTE'
vault auth list -format=json
REMOTE
)
oidc_accessor=$(jq -r '."oidc/".accessor // empty' <<<"${auth_list_json}")
if [[ -z "${oidc_accessor}" ]]; then
  vault_exec <<'REMOTE'
vault auth enable -description="VAULT-03 Vault UI OIDC 로그인" oidc
REMOTE
  auth_list_json=$(vault_exec <<'REMOTE'
vault auth list -format=json
REMOTE
)
  oidc_accessor=$(jq -r '."oidc/".accessor // empty' <<<"${auth_list_json}")
fi
[[ -n "${oidc_accessor}" ]] || { echo "oidc auth accessor를 확인할 수 없다" >&2; exit 1; }
echo "   oidc accessor 확인 완료"

echo "== 2. vault-ui-operator policy =="
{
  printf "cat > /tmp/%s.hcl <<'HCL'\n" "${POLICY_NAME}"
  cat "${POLICY_FILE}"
  printf 'HCL\n'
  printf 'vault policy write %s /tmp/%s.hcl >/dev/null\n' "${POLICY_NAME}" "${POLICY_NAME}"
  printf 'rm -f /tmp/%s.hcl\n' "${POLICY_NAME}"
} | vault_exec

echo "== 3. auth/oidc/config (client secret은 stdin -> pod 임시 파일로만 전달) =="
tr -d '\n' <"${VAULT03_CLIENT_SECRET_FILE}" | ssh "${ssh_options[@]}" "${K3S_HOST}" \
  "${KUBECTL} -n vault exec -i vault-0 -- sh -c 'umask 077; cat > /tmp/vault03-oidc-secret'"
vault_exec <<REMOTE
vault write auth/oidc/config \
  oidc_discovery_url="${DISCOVERY_URL}" \
  oidc_client_id="vault" \
  oidc_client_secret=@/tmp/vault03-oidc-secret \
  default_role="${ROLE_NAME}" >/dev/null
rm -f /tmp/vault03-oidc-secret
REMOTE

echo "== 4. auth/oidc/role/${ROLE_NAME} =="
vault_exec <<REMOTE
vault write auth/oidc/role/${ROLE_NAME} \
  role_type="oidc" \
  user_claim="preferred_username" \
  bound_audiences="vault" \
  groups_claim="groups" \
  allowed_redirect_uris="${REDIRECT_URI}" \
  oidc_scopes="profile,email" \
  token_ttl=15m token_max_ttl=1h >/dev/null
REMOTE

echo "== 5. identity group(external)과 group-alias =="
vault_exec <<REMOTE
vault write identity/group/name/${GROUP_NAME} type=external policies=${POLICY_NAME} >/dev/null
REMOTE
group_json=$(vault_exec <<REMOTE
vault read -format=json identity/group/name/${GROUP_NAME}
REMOTE
)
group_id=$(jq -r '.data.id' <<<"${group_json}")
[[ -n "${group_id}" && "${group_id}" != "null" ]] || { echo "identity group id를 확인할 수 없다" >&2; exit 1; }

aliases_json=$(vault_exec <<'REMOTE'
if vault list -format=json identity/group-alias/id 2>/dev/null; then
  :
else
  printf '%s\n' '[]'
fi
REMOTE
)
match_id=""
for alias_id in $(jq -r '.[]?' <<<"${aliases_json}"); do
  detail_json=$(vault_exec <<REMOTE
vault read -format=json identity/group-alias/id/${alias_id}
REMOTE
)
  alias_name=$(jq -r '.data.name' <<<"${detail_json}")
  alias_accessor=$(jq -r '.data.mount_accessor' <<<"${detail_json}")
  alias_canonical=$(jq -r '.data.canonical_id' <<<"${detail_json}")
  if [[ "${alias_name}" == "${GROUP_ALIAS_NAME}" && "${alias_accessor}" == "${oidc_accessor}" ]]; then
    match_id=${alias_id}
    if [[ "${alias_canonical}" != "${group_id}" ]]; then
      vault_exec <<REMOTE
vault write identity/group-alias/id/${alias_id} \
  name=${GROUP_ALIAS_NAME} mount_accessor=${oidc_accessor} canonical_id=${group_id} >/dev/null
REMOTE
      echo "   기존 group-alias의 canonical_id를 보정했다"
    fi
    break
  fi
done
if [[ -z "${match_id}" ]]; then
  vault_exec <<REMOTE
vault write identity/group-alias \
  name=${GROUP_ALIAS_NAME} mount_accessor=${oidc_accessor} canonical_id=${group_id} >/dev/null
REMOTE
  echo "   신규 group-alias(${GROUP_ALIAS_NAME} -> ${GROUP_NAME})를 추가했다"
else
  echo "   기존 group-alias(${GROUP_ALIAS_NAME})를 재사용한다"
fi

echo
echo "완료. root token은 더 이상 필요하지 않다."
echo "vault token revoke -self 로 폐기하고 파일을 shred 한다."
