#!/usr/bin/env bash
# SCM-01 전용 PostgreSQL role/DB, Keycloak client와 Vault KV/auth role을 계획·적용한다.
# shellcheck disable=SC2029
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법: gitops/tools/scm-01/provision.sh --check|--apply|--rotate-jwt

입력은 $KTC_SECRET_ROOT/gitea/env(mode 0600)에서만 읽는다.
--check는 기존 live 객체의 안전한 필드와 선언 차이를 분류하고 변경하지 않는다.
--apply는 gitea_user/DB, Keycloak gitea client, Vault gitea policy/role/KV만 적용한다.
--rotate-jwt는 나머지 KV 필드가 일치할 때만 GITEA_JWT_SECRET 하나를 갱신한다.
EOF
}

mode=${1:-}
if [[ "${mode}" != --check && "${mode}" != --apply && "${mode}" != --rotate-jwt ]]; then
  usage >&2
  exit 2
fi

: "${KTC_SECRET_ROOT:=$HOME/secrets/ktcloud4-bean}"
readonly env_file=${SCM01_ENV_FILE:-"$KTC_SECRET_ROOT/gitea/env"}
readonly kc_secret_dir=${KC01_SECRET_DIR:-"$KTC_SECRET_ROOT/keycloak"}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-"$KTC_SECRET_ROOT/vault-root.token"}
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly postgres_host=${POSTGRES_HOST:-rocky@postgres-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly client_declaration=${repo_root}/gitops/tools/scm-01/keycloak-client.json
readonly policy_file=${repo_root}/infra/vault/scripts/policies/gitea.hcl

ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)
postgres_ssh_options=(
  "${ssh_options[@]}"
  -o HostKeyAlias=10.10.50.10
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

case "${env_file}" in
  "${repo_root}"|"${repo_root}"/*)
    echo "SCM-01 env는 저장소 밖이어야 한다: ${env_file}" >&2
    exit 1
    ;;
esac
check_private_file "${env_file}"
check_private_file "${vault_root_token_file}"
for required in local-admin-password local-admin-totp; do
  check_private_file "${kc_secret_dir}/${required}"
done

allowed_keys=(
  GITEA_DB_PASSWORD
  GITEA_LOCAL_ADMIN_PASSWORD
  GITEA_OIDC_CLIENT_SECRET
  GITEA_SECRET_KEY
  GITEA_INTERNAL_TOKEN
  GITEA_JWT_SECRET
  GITEA_WEBHOOK_SECRET
)
declare -A allowed=() seen=()
for key in "${allowed_keys[@]}"; do
  allowed["${key}"]=1
done
while IFS= read -r raw || [[ -n "${raw}" ]]; do
  line=${raw%$'\r'}
  [[ -z "${line}" || "${line}" == \#* ]] && continue
  [[ "${line}" == *=* ]] || { echo "SCM-01 env 형식 오류" >&2; exit 1; }
  key=${line%%=*}
  value=${line#*=}
  [[ -n "${allowed[${key}]:-}" && -z "${seen[${key}]:-}" ]] || {
    echo "SCM-01 env 키가 중복되거나 허용되지 않았다: ${key}" >&2
    exit 1
  }
  if [[ "${key}" == GITEA_JWT_SECRET ]]; then
    [[ "${value}" =~ ^[A-Za-z0-9_-]+$ ]] || {
      echo "GITEA_JWT_SECRET는 raw URL-safe Base64여야 한다." >&2
      exit 1
    }
  else
    [[ "${value}" =~ ^[A-Za-z0-9]+$ ]] || {
      echo "SCM-01 env 값은 비어 있지 않은 영숫자여야 한다: ${key}" >&2
      exit 1
    }
  fi
  printf -v "${key}" '%s' "${value}"
  seen["${key}"]=1
done <"${env_file}"
for key in "${allowed_keys[@]}"; do
  [[ -n "${seen[${key}]:-}" ]] || { echo "SCM-01 env 필수 키가 없다: ${key}" >&2; exit 1; }
done
[[ "${#GITEA_DB_PASSWORD}" -ge 32 ]]
[[ "${#GITEA_LOCAL_ADMIN_PASSWORD}" -ge 32 ]]
[[ "${#GITEA_OIDC_CLIENT_SECRET}" -eq 48 ]]
[[ "${#GITEA_SECRET_KEY}" -eq 64 ]]
[[ "${#GITEA_INTERNAL_TOKEN}" -eq 64 ]]
[[ "${#GITEA_JWT_SECRET}" -eq 43 ]]
jwt_canonical=$(printf '%s=' "${GITEA_JWT_SECRET}" \
  | tr '_-' '/+' | openssl base64 -d -A | openssl base64 -A \
  | tr '+/' '-_' | tr -d '=')
[[ "${jwt_canonical}" == "${GITEA_JWT_SECRET}" ]] || {
  echo "GITEA_JWT_SECRET는 32 byte canonical raw URL-safe Base64여야 한다." >&2
  exit 1
}
[[ "${#GITEA_WEBHOOK_SECRET}" -eq 64 ]]
jq -e . "${client_declaration}" >/dev/null
[[ -s "${policy_file}" ]]

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  rm -rf "${temp_dir}"
}
trap cleanup EXIT INT TERM

admin_header=${temp_dir}/admin.header
clients_json=${temp_dir}/clients.json
client_payload=${temp_dir}/client-payload.json
client_response=${temp_dir}/client-response.json
vault_payload=${temp_dir}/vault-payload.json
kv_json=${temp_dir}/kv.json
inventory_file=${temp_dir}/inventory
extra_vars=${temp_dir}/extra-vars.json

wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
python3 "${repo_root}/gitops/tools/kc-01/browser-login.py" \
  --issuer "${issuer}" --realm master --client-id kc-recovery \
  --redirect-uri "${issuer}/realms/master/account/" \
  --username imcherry-kc-recovery \
  --password-file "${kc_secret_dir}/local-admin-password" \
  --totp-file "${kc_secret_dir}/local-admin-totp" \
  --header-file "${admin_header}" --connect-ip "${connect_ip}" \
  --expect-realm-role admin >/dev/null

curl_admin() {
  curl --silent --show-error --fail \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --header "@${admin_header}" "$@"
}

curl_admin "${issuer}/admin/realms/platform/clients?clientId=gitea" >"${clients_json}"
client_count=$(jq 'length' "${clients_json}")
[[ "${client_count}" -le 1 ]] || {
  echo "동일 clientId=gitea가 ${client_count}건이다. 변경하지 않는다." >&2
  exit 1
}

client_matches() {
  jq -e '
    length == 1 and
    .[0].clientId == "gitea" and .[0].enabled == true and
    .[0].protocol == "openid-connect" and .[0].publicClient == false and
    .[0].clientAuthenticatorType == "client-secret" and
    .[0].standardFlowEnabled == true and .[0].implicitFlowEnabled == false and
    .[0].directAccessGrantsEnabled == false and .[0].serviceAccountsEnabled == false and
    (.[0].authorizationServicesEnabled != true) and .[0].fullScopeAllowed == false and
    .[0].redirectUris == ["https://git.imcherry5778.xyz/user/oauth2/keycloak/callback"] and
    .[0].webOrigins == ["https://git.imcherry5778.xyz"] and
    .[0].attributes["post.logout.redirect.uris"] == "https://git.imcherry5778.xyz/" and
    (.[0].protocolMappers | map(select(
      .name == "groups" and .protocol == "openid-connect" and
      .protocolMapper == "oidc-group-membership-mapper" and
      .config["claim.name"] == "groups" and .config["full.path"] == "true" and
      .config["id.token.claim"] == "true" and .config["access.token.claim"] == "true" and
      .config["userinfo.token.claim"] == "true"
    )) | length == 1)
  ' "${clients_json}" >/dev/null
}
if [[ "${client_count}" -eq 1 ]]; then
  client_matches || {
    jq '[.[] | {clientId,enabled,protocol,publicClient,standardFlowEnabled,
      implicitFlowEnabled,directAccessGrantsEnabled,serviceAccountsEnabled,
      authorizationServicesEnabled,fullScopeAllowed,redirectUris,webOrigins,
      post_logout:.attributes["post.logout.redirect.uris"]}]' "${clients_json}"
    echo "live Gitea Keycloak client가 선언과 다르다. 변경하지 않는다." >&2
    exit 1
  }
  client_id=$(jq -r '.[0].id' "${clients_json}")
  curl_admin "${issuer}/admin/realms/platform/clients/${client_id}/client-secret" \
    | jq -e --rawfile expected <(printf '%s' "${GITEA_OIDC_CLIENT_SECRET}") \
      '.value == $expected' >/dev/null
  echo "SCM-01 Keycloak: gitea client=match"
else
  echo "SCM-01 Keycloak: gitea client=absent"
fi

db_state=$(ssh "${postgres_ssh_options[@]}" "${postgres_host}" \
  "sudo -u postgres psql -XAt -d postgres -c \"SELECT COALESCE((SELECT rolname||'|'||rolsuper||'|'||rolcreatedb||'|'||rolcreaterole||'|'||rolreplication||'|'||rolcanlogin FROM pg_roles WHERE rolname='gitea_user'),'absent'); SELECT COALESCE((SELECT datname||'|'||pg_get_userbyid(datdba) FROM pg_database WHERE datname='gitea'),'absent');\"")
expected_db_state=$'gitea_user|false|false|false|false|true\ngitea|gitea_user'
if [[ "${db_state}" == $'absent\nabsent' ]]; then
  echo "SCM-01 PostgreSQL: role/database=absent"
elif [[ "${db_state}" == "${expected_db_state}" ]]; then
  echo "SCM-01 PostgreSQL: role/database=match"
else
  printf 'SCM-01 PostgreSQL live drift: %s\n' "${db_state}" >&2
  exit 1
fi

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

policy_json=$(vault_exec <<'REMOTE'
if vault policy read -format=json gitea 2>/dev/null; then :; else printf '%s\n' '{"policy":null}'; fi
REMOTE
)
if jq -e '.policy == null' <<<"${policy_json}" >/dev/null; then
  echo "SCM-01 Vault: policy=absent"
else
  jq -e --rawfile expected "${policy_file}" '.policy == $expected' <<<"${policy_json}" >/dev/null || {
    echo "live Gitea Vault policy가 선언과 다르다. 변경하지 않는다." >&2
    exit 1
  }
  echo "SCM-01 Vault: policy=match"
fi

role_json=$(vault_exec <<'REMOTE'
if vault read -format=json auth/kubernetes/role/gitea 2>/dev/null; then :; else printf '%s\n' '{"data":null}'; fi
REMOTE
)
role_matches() {
  jq -e '
    .data.bound_service_account_names == ["gitea"] and
    .data.bound_service_account_namespaces == ["gitea"] and
    .data.audience == "vault" and .data.token_policies == ["gitea"] and
    .data.token_no_default_policy == true and .data.token_ttl == 900 and
    .data.token_max_ttl == 3600
  ' <<<"${role_json}" >/dev/null
}
if jq -e '.data == null' <<<"${role_json}" >/dev/null; then
  echo "SCM-01 Vault: kubernetes role=absent"
else
  role_matches || {
    echo "live Gitea Vault Kubernetes role이 선언과 다르다. 변경하지 않는다." >&2
    exit 1
  }
  echo "SCM-01 Vault: kubernetes role=match"
fi

jq -n \
  --arg db_password "${GITEA_DB_PASSWORD}" \
  --arg local_admin_password "${GITEA_LOCAL_ADMIN_PASSWORD}" \
  --arg oidc_client_secret "${GITEA_OIDC_CLIENT_SECRET}" \
  --arg secret_key "${GITEA_SECRET_KEY}" \
  --arg internal_token "${GITEA_INTERNAL_TOKEN}" \
  --arg jwt_secret "${GITEA_JWT_SECRET}" \
  --arg webhook_secret "${GITEA_WEBHOOK_SECRET}" \
  '{db_password:$db_password,local_admin_password:$local_admin_password,
    oidc_client_secret:$oidc_client_secret,secret_key:$secret_key,
    internal_token:$internal_token,jwt_secret:$jwt_secret,webhook_secret:$webhook_secret}' \
  >"${vault_payload}"
vault_exec <<'REMOTE' >"${kv_json}"
if vault kv get -format=json kv/gitea/runtime 2>/dev/null; then :; else printf '%s\n' '{"data":null}'; fi
REMOTE
kv_rotation_only=false
if jq -e '.data == null' "${kv_json}" >/dev/null; then
  echo "SCM-01 Vault: kv/gitea/runtime=absent"
else
  if jq -e --slurpfile expected "${vault_payload}" '.data.data == $expected[0]' "${kv_json}" >/dev/null; then
    echo "SCM-01 Vault: kv/gitea/runtime=match"
  elif [[ "${mode}" == --rotate-jwt ]] && jq -e --slurpfile expected "${vault_payload}" '
    (.data.data | del(.jwt_secret)) == ($expected[0] | del(.jwt_secret)) and
    .data.data.jwt_secret != $expected[0].jwt_secret
  ' "${kv_json}" >/dev/null; then
    kv_rotation_only=true
    echo "SCM-01 Vault: JWT secret 1건만 교체 대상"
  else
    echo "live Gitea Vault KV가 외부 입력과 다르다. credential 회전 승인 없이 변경하지 않는다." >&2
    exit 1
  fi
fi

if [[ "${mode}" == --rotate-jwt ]]; then
  [[ "${kv_rotation_only}" == true ]] || {
    echo "--rotate-jwt는 기존 KV에서 JWT 하나만 다른 경우에만 실행한다." >&2
    exit 1
  }
  {
    tr -d '\n' <"${vault_root_token_file}"
    printf '\n'
    cat "${vault_payload}"
  } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
      set -eu
      umask 077
      read -r VAULT_TOKEN
      export VAULT_TOKEN
      trap \"rm -f /tmp/scm01-gitea-kv.json\" EXIT
      cat > /tmp/scm01-gitea-kv.json
      vault kv put kv/gitea/runtime @/tmp/scm01-gitea-kv.json >/dev/null
    '"
  vault_exec <<'REMOTE' >"${kv_json}"
vault kv get -format=json kv/gitea/runtime
REMOTE
  jq -e --slurpfile expected "${vault_payload}" '.data.data == $expected[0]' "${kv_json}" >/dev/null
  echo "SCM-01: 승인된 Gitea JWT secret 1건 교체 검증 통과"
  exit 0
fi

if [[ "${mode}" == --check ]]; then
  echo "SCM-01 --check: 예상된 absent 또는 선언 일치만 확인했다. live 변경 0건"
  exit 0
fi

cat >"${inventory_file}" <<'EOF'
[postgres_nodes]
postgres-01 ansible_host=postgres-01.imcherry5778.xyz ansible_user=rocky
EOF
jq -n --arg password "${GITEA_DB_PASSWORD}" '{pg_gitea_password:$password}' >"${extra_vars}"
ANSIBLE_CONFIG="${repo_root}/infra/ansible/ansible.cfg" \
ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${known_hosts} -o HostKeyAlias=10.10.50.10 -o PasswordAuthentication=no" \
  ansible-playbook -i "${inventory_file}" \
  "${repo_root}/infra/ansible/playbooks/postgres-baseline.yml" --syntax-check >/dev/null
ANSIBLE_CONFIG="${repo_root}/infra/ansible/ansible.cfg" \
ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=${known_hosts} -o HostKeyAlias=10.10.50.10 -o PasswordAuthentication=no" \
  ansible-playbook -i "${inventory_file}" \
  "${repo_root}/infra/ansible/playbooks/postgres-baseline.yml" \
  --extra-vars "@${extra_vars}"

if [[ "${client_count}" -eq 0 ]]; then
  jq --rawfile secret <(printf '%s' "${GITEA_OIDC_CLIENT_SECRET}") \
    '. + {secret:$secret}' "${client_declaration}" >"${client_payload}"
  http_status=$(curl --silent --show-error \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${client_response}" --write-out '%{http_code}' --request POST \
    --header "@${admin_header}" --header 'Content-Type: application/json' \
    --data-binary "@${client_payload}" "${issuer}/admin/realms/platform/clients")
  [[ "${http_status}" == 201 ]] || {
    echo "Gitea Keycloak client 생성 실패: HTTP ${http_status}" >&2
    jq '{error,errorMessage}' "${client_response}" >&2 2>/dev/null || true
    exit 1
  }
fi

{
  printf "cat > /tmp/scm01-gitea-policy.hcl <<'HCL'\n"
  cat "${policy_file}"
  printf "HCL\n"
  cat <<'REMOTE'
vault policy write gitea /tmp/scm01-gitea-policy.hcl >/dev/null
rm -f /tmp/scm01-gitea-policy.hcl
vault write auth/kubernetes/role/gitea \
  bound_service_account_names=gitea \
  bound_service_account_namespaces=gitea \
  audience=vault token_policies=gitea token_no_default_policy=true \
  token_ttl=15m token_max_ttl=1h >/dev/null
REMOTE
} | vault_exec

{
  tr -d '\n' <"${vault_root_token_file}"
  printf '\n'
  cat "${vault_payload}"
} | ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
    set -eu
    umask 077
    read -r VAULT_TOKEN
    export VAULT_TOKEN
    trap \"rm -f /tmp/scm01-gitea-kv.json\" EXIT
    cat > /tmp/scm01-gitea-kv.json
    vault kv put kv/gitea/runtime @/tmp/scm01-gitea-kv.json >/dev/null
  '"

final_db_state=$(ssh "${postgres_ssh_options[@]}" "${postgres_host}" \
  "sudo -u postgres psql -XAt -d postgres -c \"SELECT rolname||'|'||rolsuper||'|'||rolcreatedb||'|'||rolcreaterole||'|'||rolreplication||'|'||rolcanlogin FROM pg_roles WHERE rolname='gitea_user'; SELECT datname||'|'||pg_get_userbyid(datdba) FROM pg_database WHERE datname='gitea';\"")
[[ "${final_db_state}" == "${expected_db_state}" ]]
curl_admin "${issuer}/admin/realms/platform/clients?clientId=gitea" >"${clients_json}"
client_matches
client_id=$(jq -r '.[0].id' "${clients_json}")
curl_admin "${issuer}/admin/realms/platform/clients/${client_id}/client-secret" \
  | jq -e --rawfile expected <(printf '%s' "${GITEA_OIDC_CLIENT_SECRET}") '.value == $expected' >/dev/null
role_json=$(vault_exec <<'REMOTE'
vault read -format=json auth/kubernetes/role/gitea
REMOTE
)
role_matches
vault_exec <<'REMOTE' >"${kv_json}"
vault kv get -format=json kv/gitea/runtime
REMOTE
jq -e --slurpfile expected "${vault_payload}" '.data.data == $expected[0]' "${kv_json}" >/dev/null
echo "SCM-01: PostgreSQL 최소 role/DB, Keycloak client, Vault policy/role/KV 적용 검증 통과"
