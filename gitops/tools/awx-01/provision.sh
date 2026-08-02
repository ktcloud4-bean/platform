#!/usr/bin/env bash
# AWX-01 전용 DB/Keycloak client/Vault KV·policy·role을 check-first로 구성한다.
set -Eeuo pipefail

usage() {
  echo "사용법: KTC_SECRET_ROOT=<저장소 밖 root> $0 --check|--apply" >&2
}

mode=${1:-}
if [[ "${mode}" != --check && "${mode}" != --apply ]]; then
  usage
  exit 2
fi
: "${KTC_SECRET_ROOT:?KTC_SECRET_ROOT가 필요하다}"

repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly awx_secret_dir=${KTC_SECRET_ROOT}/awx
readonly env_file=${awx_secret_dir}/env
readonly kc_secret_dir=${KTC_SECRET_ROOT}/keycloak
readonly vault_root_token_file=${KTC_SECRET_ROOT}/vault-root.token
readonly client_declaration=${repo_root}/gitops/tools/awx-01/keycloak-client.json
readonly policy_file=${repo_root}/infra/vault/scripts/policies/awx.hcl
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
# 관리 SSH known_hosts는 PG-01에서 등록한 고정 주소 항목을 사용한다. AWX의 DB
# application 연결은 아래와 무관하게 canonical FQDN + verify-full이다.
readonly postgres_host=${POSTGRES_HOST:-rocky@10.10.50.10}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

case "${awx_secret_dir}" in
  /|/home|/home/*/projects|/home/*/projects/*|"${repo_root}"|"${repo_root}"/*)
    echo "AWX 비밀 경로가 너무 넓거나 저장소 안이다: ${awx_secret_dir}" >&2
    exit 1
    ;;
esac
for required in "${env_file}" "${vault_root_token_file}" \
  "${kc_secret_dir}/local-admin-password" "${kc_secret_dir}/local-admin-totp"; do
  [[ -s "${required}" && "$(stat -c %a "${required}")" == 600 ]] || {
    echo "필수 비밀 파일은 mode 0600이어야 한다: ${required}" >&2
    exit 1
  }
done
jq -e . "${client_declaration}" >/dev/null
[[ -s "${policy_file}" ]]

set -a
# shellcheck disable=SC1090
source "${env_file}"
set +a
for variable in AWX_DB_PASSWORD AWX_ADMIN_PASSWORD AWX_SECRET_KEY \
  AWX_OIDC_CLIENT_SECRET AWX_VERIFIER_PASSWORD AWX_VERIFIER_DENIED_PASSWORD; do
  [[ "${!variable:-}" =~ ^[A-Za-z0-9]{48,64}$ ]] || {
    echo "${variable} 형식이 예상과 다르다." >&2
    exit 1
  }
done

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  rm -rf "${temp_dir}"
}
trap cleanup EXIT INT TERM

admin_header=${temp_dir}/admin.header
clients_json=${temp_dir}/clients.json
client_payload=${temp_dir}/client.json
response_json=${temp_dir}/response.json
vault_payload=${temp_dir}/vault.json
htpasswd_file=${temp_dir}/htpasswd

printf '%s' "${AWX_VERIFIER_PASSWORD}" | openssl passwd -apr1 -stdin >"${htpasswd_file}"
jq -n \
  --arg db_password "${AWX_DB_PASSWORD}" \
  --arg admin_password "${AWX_ADMIN_PASSWORD}" \
  --arg secret_key "${AWX_SECRET_KEY}" \
  --arg oidc_client_secret "${AWX_OIDC_CLIENT_SECRET}" \
  --arg verifier_password "${AWX_VERIFIER_PASSWORD}" \
  --arg verifier_denied_password "${AWX_VERIFIER_DENIED_PASSWORD}" \
  --rawfile verifier_htpasswd "${htpasswd_file}" \
  '{db_password:$db_password,admin_password:$admin_password,secret_key:$secret_key,
    oidc_client_secret:$oidc_client_secret,verifier_password:$verifier_password,
    verifier_denied_password:$verifier_denied_password,
    verifier_htpasswd:($verifier_htpasswd|rtrimstr("\n"))}' >"${vault_payload}"

echo "AWX-01 PostgreSQL 전용 role/DB 경계를 확인한다."
postgres_facts=$(ssh "${ssh_options[@]}" "${postgres_host}" \
  "sudo -n -u postgres psql -XAt --set=ON_ERROR_STOP=1 postgres" <<'SQL'
SELECT coalesce((SELECT rolname || '|' || rolsuper || '|' || rolcreatedb || '|' || rolcreaterole || '|' || rolreplication || '|' || rolcanlogin
  FROM pg_roles WHERE rolname = 'awx_user'), 'ABSENT');
SELECT coalesce((SELECT datname || '|' || pg_get_userbyid(datdba) || '|' || datallowconn
  FROM pg_database WHERE datname = 'awx'), 'ABSENT');
SQL
)
role_fact=$(sed -n '1p' <<<"${postgres_facts}")
db_fact=$(sed -n '2p' <<<"${postgres_facts}")
unset postgres_facts
if [[ "${role_fact}" == ABSENT && "${db_fact}" == ABSENT ]]; then
  echo "PostgreSQL 차이: awx_user/awx 없음 -> 신규 생성 대상"
  postgres_absent=true
elif [[ "${role_fact}" == 'awx_user|f|f|f|f|t' && "${db_fact}" == 'awx|awx_user|t' ]]; then
  echo "PostgreSQL 차이: 전용 role/DB 기본 속성 일치"
  postgres_absent=false
else
  echo "PostgreSQL live role/DB가 AWX-01 선언과 다르다: ${role_fact}, ${db_fact}" >&2
  exit 1
fi
unset role_fact db_fact

wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
python3 "${repo_root}/gitops/tools/kc-01/browser-login.py" \
  --issuer "${issuer}" --realm master --client-id kc-recovery \
  --redirect-uri "${issuer}/realms/master/account/" \
  --username imcherry-kc-recovery \
  --password-file "${kc_secret_dir}/local-admin-password" \
  --totp-file "${kc_secret_dir}/local-admin-totp" \
  --header-file "${admin_header}" --connect-ip "${connect_ip}" \
  --capture-callback --expect-realm-role admin >/dev/null

curl_admin() {
  curl --silent --show-error --fail --resolve "${issuer_host}:443:${connect_ip}" \
    --header "@${admin_header}" "$@"
}
curl_admin "${issuer}/admin/realms/platform/clients?clientId=awx" >"${clients_json}"
client_count=$(jq 'length' "${clients_json}")
client_matches() {
  jq -e '
    length == 1 and .[0].clientId == "awx" and .[0].enabled == true and
    .[0].protocol == "openid-connect" and .[0].publicClient == false and
    .[0].clientAuthenticatorType == "client-secret" and .[0].standardFlowEnabled == true and
    .[0].implicitFlowEnabled == false and .[0].directAccessGrantsEnabled == false and
    .[0].serviceAccountsEnabled == false and (.[0].authorizationServicesEnabled != true) and
    .[0].fullScopeAllowed == false and
    .[0].redirectUris == ["https://awx.imcherry5778.xyz/sso/complete/oidc/"] and
    .[0].webOrigins == ["https://awx.imcherry5778.xyz"] and
    .[0].attributes["post.logout.redirect.uris"] == "https://awx.imcherry5778.xyz/" and
    ([.[0].protocolMappers[]? | select(.name == "groups" and
      .protocolMapper == "oidc-group-membership-mapper" and .config["claim.name"] == "groups" and
      .config["full.path"] == "true" and .config["id.token.claim"] == "true" and
      .config["access.token.claim"] == "true")] | length == 1)
  ' "${clients_json}" >/dev/null
}
case "${client_count}" in
  0) echo "Keycloak 차이: awx client 없음 -> 신규 생성 대상"; keycloak_absent=true ;;
  1)
    client_matches || { echo "live awx client가 비밀 제외 선언과 다르다." >&2; exit 1; }
    client_uuid=$(jq -r '.[0].id' "${clients_json}")
    curl_admin "${issuer}/admin/realms/platform/clients/${client_uuid}/client-secret" >"${response_json}"
    [[ "$(jq -r '.value' "${response_json}")" == "${AWX_OIDC_CLIENT_SECRET}" ]] || {
      echo "기존 awx client secret이 입력과 다르다. 자동 교체하지 않는다." >&2
      exit 1
    }
    echo "Keycloak 차이: awx confidential client 선언 일치"
    keycloak_absent=false
    ;;
  *) echo "동일 clientId=awx가 ${client_count}건이다. 변경하지 않는다." >&2; exit 1 ;;
esac

vault_exec() {
  {
    tr -d '\n' <"${vault_root_token_file}"
    printf '\n'
    cat
  } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c 'read -r VAULT_TOKEN; export VAULT_TOKEN; exec sh -eu'"
}

policy_state=$(vault_exec <<'REMOTE'
if vault policy read awx >/dev/null 2>&1; then echo PRESENT; else echo ABSENT; fi
REMOTE
)
role_state=$(vault_exec <<'REMOTE'
if vault read auth/kubernetes/role/awx >/dev/null 2>&1; then echo PRESENT; else echo ABSENT; fi
REMOTE
)
kv_state=$(vault_exec <<'REMOTE'
if vault kv get kv/awx/runtime >/dev/null 2>&1; then echo PRESENT; else echo ABSENT; fi
REMOTE
)
printf 'Vault 차이: policy=%s role=%s kv=%s\n' "${policy_state}" "${role_state}" "${kv_state}"

if [[ "${mode}" == --check ]]; then
  echo "AWX-01 check 완료. 어떤 live 상태도 바꾸지 않았다."
  exit 0
fi

if [[ "${postgres_absent}" == true ]]; then
  remote_password_file=$(ssh "${ssh_options[@]}" "${postgres_host}" 'umask 077; mktemp')
  tr -d '\n' <<<"${AWX_DB_PASSWORD}" | ssh "${ssh_options[@]}" "${postgres_host}" "cat > '${remote_password_file}'"
  ssh "${ssh_options[@]}" "${postgres_host}" "bash -s -- '${remote_password_file}'" <<'REMOTE'
set -Eeuo pipefail
password_file=$1
trap 'rm -f "${password_file}"' EXIT
password=$(cat "${password_file}")
[[ "${password}" =~ ^[A-Za-z0-9]{48}$ ]]
sql_file=$(mktemp)
trap 'rm -f "${password_file}" "${sql_file}"' EXIT
printf "CREATE ROLE awx_user WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION PASSWORD '%s';\n" "${password}" >"${sql_file}"
sudo -n -u postgres psql -Xq --set=ON_ERROR_STOP=1 postgres <"${sql_file}"
sudo -n -u postgres createdb --owner=awx_user awx
sudo -n -u postgres psql -Xq --set=ON_ERROR_STOP=1 postgres <<'SQL'
REVOKE CONNECT ON DATABASE awx FROM PUBLIC;
GRANT CONNECT ON DATABASE awx TO awx_user;
SQL
sudo -n -u postgres psql -Xq --set=ON_ERROR_STOP=1 awx <<'SQL'
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE, CREATE ON SCHEMA public TO awx_user;
SQL
REMOTE
  echo "PostgreSQL awx_user와 awx DB를 신규 생성했다."
fi

if [[ "${keycloak_absent}" == true ]]; then
  jq --arg secret "${AWX_OIDC_CLIENT_SECRET}" '. + {secret:$secret}' \
    "${client_declaration}" >"${client_payload}"
  http_status=$(curl --silent --show-error --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${response_json}" --write-out '%{http_code}' --request POST \
    --header "@${admin_header}" --header 'Content-Type: application/json' \
    --data-binary "@${client_payload}" "${issuer}/admin/realms/platform/clients")
  [[ "${http_status}" == 201 ]] || { echo "Keycloak awx client 생성 실패: HTTP ${http_status}" >&2; exit 1; }
  echo "Keycloak awx confidential client를 신규 생성했다."
fi

if [[ "${policy_state}" == PRESENT || "${role_state}" == PRESENT || "${kv_state}" == PRESENT ]]; then
  echo "기존 AWX Vault 객체가 있다. credential 교체를 피하기 위해 자동 보정하지 않는다." >&2
  exit 1
fi
{
  echo "cat > /tmp/awx.hcl <<'HCL'"
  cat "${policy_file}"
  echo HCL
  echo 'vault policy write awx /tmp/awx.hcl >/dev/null; rm -f /tmp/awx.hcl'
  echo 'vault write auth/kubernetes/role/awx bound_service_account_names="awx-vault-bootstrap,awx-provisioner,awx-verifier" bound_service_account_namespaces="awx" audience="vault" token_policies="awx" token_no_default_policy=true token_ttl=15m token_max_ttl=1h >/dev/null'
} | vault_exec
{
  tr -d '\n' <"${vault_root_token_file}"
  printf '\n'
  cat "${vault_payload}"
} | ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
    set -eu; umask 077; read -r VAULT_TOKEN; export VAULT_TOKEN
    trap \"rm -f /tmp/awx-kv.json\" EXIT
    cat > /tmp/awx-kv.json
    vault kv put kv/awx/runtime @/tmp/awx-kv.json >/dev/null
  '"
date -u +'%Y-%m-%dT%H:%M:%SZ' >"${awx_secret_dir}/.provisioned"
chmod 0600 "${awx_secret_dir}/.provisioned"
unset AWX_DB_PASSWORD AWX_ADMIN_PASSWORD AWX_SECRET_KEY AWX_OIDC_CLIENT_SECRET
unset AWX_VERIFIER_PASSWORD AWX_VERIFIER_DENIED_PASSWORD
echo "AWX-01 DB, Keycloak, Vault 초기 provisioning 완료"
