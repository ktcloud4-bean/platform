#!/usr/bin/env bash
# shellcheck disable=SC2029
# POM-01 전용 Keycloak clients와 Vault KV/auth role만 계획·적용한다.
# 기존 realm/client/group/user와 Vault seal/init/Raft는 수정하지 않는다.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법:
  POM01_SECRET_DIR=<저장소 밖 디렉터리> \
  KC01_SECRET_DIR=<저장소 밖 KC-01 디렉터리> \
  VAULT_ROOT_TOKEN_FILE=<mode 0600 root token 파일> \
  ./gitops/tools/pom-01/provision.sh --check|--apply

--check는 현재 realm과 POM-01 선언의 차이를 안전한 필드만으로 분류한다.
--apply는 Pomerium confidential client와 Dashy public PKCE client가 없을 때만
추가하고, 정확히 kv/pomerium/runtime, pomerium policy와 Kubernetes auth role만 구성한다.
EOF
}

mode=${1:-}
if [[ "${mode}" != --check && "${mode}" != --apply ]]; then
  usage >&2
  exit 2
fi

: "${POM01_SECRET_DIR:?저장소 밖 POM-01 비밀 디렉터리가 필요하다}"
: "${KC01_SECRET_DIR:?저장소 밖 KC-01 비밀 디렉터리가 필요하다}"
: "${VAULT_ROOT_TOKEN_FILE:?저장소 밖 Vault root token 파일이 필요하다}"

readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly pomerium_client_declaration=${repo_root}/gitops/tools/pom-01/keycloak-client.json
readonly dashy_client_declaration=${repo_root}/gitops/tools/pom-01/dashy-keycloak-client.json
readonly policy_file=${repo_root}/infra/vault/scripts/policies/pomerium.hcl
readonly marker_file=${POM01_SECRET_DIR}/.provisioned
ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

case "${POM01_SECRET_DIR}" in
  /|/home|/home/*/projects|/home/*/projects/*|"${repo_root}"|"${repo_root}"/*)
    echo "POM01_SECRET_DIR가 너무 넓거나 저장소 안이다: ${POM01_SECRET_DIR}" >&2
    exit 1
    ;;
esac
[[ "${POM01_SECRET_DIR}" = /* ]] || {
  echo "POM01_SECRET_DIR는 절대 경로여야 한다." >&2
  exit 1
}
[[ -r "${VAULT_ROOT_TOKEN_FILE}" ]] || {
  echo "Vault root token 파일을 읽을 수 없다." >&2
  exit 1
}
[[ "$(stat -c %a "${VAULT_ROOT_TOKEN_FILE}")" == 600 ]] || {
  echo "Vault root token 파일은 mode 0600이어야 한다." >&2
  exit 1
}
for required in local-admin-password local-admin-totp; do
  [[ -s "${KC01_SECRET_DIR}/${required}" ]] || {
    echo "KC-01 복구 입력이 없다: ${required}" >&2
    exit 1
  }
done

python3 - "${connect_ip}" <<'PY'
import ipaddress, sys
assert ipaddress.ip_address(sys.argv[1]).version == 4
PY
jq -e . "${pomerium_client_declaration}" >/dev/null
jq -e . "${dashy_client_declaration}" >/dev/null
[[ -s "${policy_file}" ]]

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  rm -rf "${temp_dir}"
}
trap cleanup EXIT INT TERM

admin_header=${temp_dir}/admin.header
pomerium_clients_json=${temp_dir}/pomerium-clients.json
dashy_clients_json=${temp_dir}/dashy-clients.json
pomerium_client_payload=${temp_dir}/pomerium-client-payload.json
client_response=${temp_dir}/client-response.json
vault_payload=${temp_dir}/vault-payload.json

# KC-01 검증 직후 같은 복구 TOTP를 재사용하지 않도록 새 구간에서 로그인한다.
wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
python3 "${repo_root}/gitops/tools/kc-01/browser-login.py" \
  --issuer "${issuer}" \
  --realm master \
  --client-id kc-recovery \
  --redirect-uri "${issuer}/realms/master/account/" \
  --username imcherry-kc-recovery \
  --password-file "${KC01_SECRET_DIR}/local-admin-password" \
  --totp-file "${KC01_SECRET_DIR}/local-admin-totp" \
  --header-file "${admin_header}" \
  --connect-ip "${connect_ip}" \
  --expect-realm-role admin >/dev/null

curl_admin() {
  curl --silent --show-error --fail \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --header "@${admin_header}" \
    "$@"
}

curl_admin "${issuer}/admin/realms/platform/clients?clientId=pomerium" >"${pomerium_clients_json}"
curl_admin "${issuer}/admin/realms/platform/clients?clientId=dashy-portal" >"${dashy_clients_json}"
pomerium_client_count=$(jq 'length' "${pomerium_clients_json}")
dashy_client_count=$(jq 'length' "${dashy_clients_json}")

echo "POM-01 realm 차이 분류: Git bootstrap은 kc-verify만 소유하며 POM 선언은 pomerium과 dashy-portal만 추가한다."
case "${pomerium_client_count}" in
  0)
    echo "POM-01 realm 차이 분류: live pomerium client 0건 -> 기대된 신규 추가"
    ;;
  1)
    echo "POM-01 realm 차이 분류: live pomerium client 1건 -> 선언 일치 여부를 검사"
    ;;
  *)
    echo "동일 clientId=pomerium의 live client가 ${pomerium_client_count}건이다. 변경하지 않는다." >&2
    exit 1
    ;;
esac
case "${dashy_client_count}" in
  0)
    echo "POM-01 realm 차이 분류: live dashy-portal client 0건 -> 기대된 신규 추가"
    ;;
  1)
    echo "POM-01 realm 차이 분류: live dashy-portal client 1건 -> 선언 일치 여부를 검사"
    ;;
  *)
    echo "동일 clientId=dashy-portal의 live client가 ${dashy_client_count}건이다. 변경하지 않는다." >&2
    exit 1
    ;;
esac

client_matches_with_post_logout() {
  local expected_post_logout=$1
  jq -e --arg expected_post_logout "${expected_post_logout}" '
    length == 1 and
    .[0].clientId == "pomerium" and
    .[0].enabled == true and
    .[0].protocol == "openid-connect" and
    .[0].publicClient == false and
    .[0].clientAuthenticatorType == "client-secret" and
    .[0].standardFlowEnabled == true and
    .[0].implicitFlowEnabled == false and
    .[0].directAccessGrantsEnabled == false and
    .[0].serviceAccountsEnabled == false and
    (.[0].authorizationServicesEnabled != true) and
    .[0].fullScopeAllowed == false and
    .[0].redirectUris == ["https://k3s-01.imcherry5778.xyz/oauth2/callback"] and
    .[0].webOrigins == ["https://k3s-01.imcherry5778.xyz"] and
    (
      if $expected_post_logout == "missing" then
        (.[0].attributes["post.logout.redirect.uris"] // "") == ""
      else
        .[0].attributes["post.logout.redirect.uris"] == $expected_post_logout
      end
    ) and
    (. [0].protocolMappers | map(select(
      .name == "groups" and
      .protocol == "openid-connect" and
      .protocolMapper == "oidc-group-membership-mapper" and
      .config["claim.name"] == "groups" and
      .config["full.path"] == "true" and
      .config["id.token.claim"] == "true" and
      .config["access.token.claim"] == "true" and
      .config["userinfo.token.claim"] == "true"
    )) | length == 1)
  ' "${pomerium_clients_json}" >/dev/null
}

client_matches() {
  client_matches_with_post_logout "https://access.imcherry5778.xyz/"
}

client_needs_post_logout_migration() {
  client_matches_with_post_logout missing
}

dashy_client_matches() {
  jq -e '
    length == 1 and
    .[0].clientId == "dashy-portal" and
    .[0].enabled == true and
    .[0].protocol == "openid-connect" and
    .[0].publicClient == true and
    .[0].standardFlowEnabled == true and
    .[0].implicitFlowEnabled == false and
    .[0].directAccessGrantsEnabled == false and
    .[0].serviceAccountsEnabled == false and
    (.[0].authorizationServicesEnabled != true) and
    .[0].fullScopeAllowed == false and
    .[0].redirectUris == ["https://access.imcherry5778.xyz/*"] and
    .[0].webOrigins == ["https://access.imcherry5778.xyz"] and
    .[0].attributes["pkce.code.challenge.method"] == "S256" and
    .[0].attributes["post.logout.redirect.uris"] == "https://access.imcherry5778.xyz/*" and
    (. [0].protocolMappers | map(select(
      .name == "groups" and
      .protocol == "openid-connect" and
      .protocolMapper == "oidc-group-membership-mapper" and
      .config["claim.name"] == "groups" and
      .config["full.path"] == "true" and
      .config["id.token.claim"] == "true" and
      .config["access.token.claim"] == "true" and
      .config["userinfo.token.claim"] == "true"
    )) | length == 1)
  ' "${dashy_clients_json}" >/dev/null
}

safe_client_summary() {
  jq '[.[] | {clientId,enabled,protocol,publicClient,clientAuthenticatorType,
    standardFlowEnabled,implicitFlowEnabled,directAccessGrantsEnabled,
    serviceAccountsEnabled,authorizationServicesEnabled,fullScopeAllowed,
    redirectUris,webOrigins,
    attributes:{pkce_code_challenge_method:.attributes["pkce.code.challenge.method"],
      post_logout_redirect_uris:.attributes["post.logout.redirect.uris"]},
    protocolMappers:[.protocolMappers[]? | select(.name == "groups") |
      {name,protocol,protocolMapper,config}]}]' "$1"
}

needs_post_logout_migration=false
if [[ "${pomerium_client_count}" -eq 1 ]] && ! client_matches; then
  if client_needs_post_logout_migration; then
    needs_post_logout_migration=true
    echo "POM-01 realm 차이 분류: task 소유 Pomerium client에 exact post-logout URI 추가가 필요하다."
  else
    safe_client_summary "${pomerium_clients_json}"
    echo "live Pomerium client가 선언과 다르다. 기존 client를 자동 교정하지 않는다." >&2
    exit 1
  fi
fi
if [[ "${dashy_client_count}" -eq 1 ]] && ! dashy_client_matches; then
  safe_client_summary "${dashy_clients_json}"
  echo "live Dashy client가 선언과 다르다. 기존 client를 자동 교정하지 않는다." >&2
  exit 1
fi

vault_exec() {
  {
    tr -d '\n' <"${VAULT_ROOT_TOKEN_FILE}"
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

echo "POM-01 Vault 차이 분류: policy와 Kubernetes auth role의 안전한 상태만 조회한다."
policy_json=$(vault_exec <<'REMOTE'
if vault policy read -format=json pomerium 2>/dev/null; then
  :
else
  printf '%s\n' '{"policy":null}'
fi
REMOTE
)
policy_matches() {
  jq -e --rawfile expected "${policy_file}" '
    .policy == $expected
  ' <<<"${policy_json}" >/dev/null
}
if jq -e '.policy == null' <<<"${policy_json}" >/dev/null; then
  printf '%s\n' '{"policy":"absent"}'
else
  printf '%s\n' '{"policy":"present"}'
  policy_matches || {
    echo "live Pomerium Vault policy가 선언과 다르다. 기존 policy를 자동 교정하지 않는다." >&2
    exit 1
  }
fi

role_json=$(vault_exec <<'REMOTE'
if vault read -format=json auth/kubernetes/role/pomerium 2>/dev/null; then
  :
else
  printf '%s\n' '{"data":null}'
fi
REMOTE
)
role_matches() {
  jq -e '
    .data.bound_service_account_names == ["pomerium"] and
    .data.bound_service_account_namespaces == ["pomerium"] and
    .data.audience == "vault" and
    .data.token_policies == ["pomerium"] and
    .data.token_no_default_policy == true and
    .data.token_ttl == 900 and
    .data.token_max_ttl == 3600
  ' <<<"${role_json}" >/dev/null
}
legacy_role_matches() {
  jq -e '
    .data.bound_service_account_names == ["pomerium"] and
    .data.bound_service_account_namespaces == ["pomerium"] and
    (.data.audience == null or .data.audience == "") and
    .data.token_policies == ["pomerium"] and
    .data.token_no_default_policy == true and
    .data.token_ttl == 900 and
    .data.token_max_ttl == 3600
  ' <<<"${role_json}" >/dev/null
}
if jq -e '.data == null' <<<"${role_json}" >/dev/null; then
  printf '%s\n' '{"role":"absent"}'
else
  jq '{role:"present", bound_service_account_names:.data.bound_service_account_names,
    bound_service_account_namespaces:.data.bound_service_account_namespaces,
    audience:.data.audience, token_policies:.data.token_policies, token_ttl:.data.token_ttl,
    token_max_ttl:.data.token_max_ttl, token_no_default_policy:.data.token_no_default_policy}' \
    <<<"${role_json}"
  if ! role_matches; then
    if [[ "${mode}" == --apply ]] && legacy_role_matches; then
      echo "POM-01 Vault 차이 분류: 기존 전용 role은 audience만 비어 있음 -> vault audience 최소화 마이그레이션"
    else
      echo "live Pomerium Vault role이 선언과 다르다. 기존 role을 자동 교정하지 않는다." >&2
      exit 1
    fi
  fi
fi

if [[ "${mode}" == --check ]]; then
  if [[ "${pomerium_client_count}" -eq 0 ]]; then
    echo "POM-01 --check: 신규 pomerium client 추가가 필요하다."
  elif [[ "${needs_post_logout_migration}" == true ]]; then
    echo "POM-01 --check: task 소유 pomerium client의 exact post-logout URI 보정이 필요하다."
  else
    echo "POM-01 --check: live pomerium client 선언 필드가 일치한다."
  fi
  [[ "${dashy_client_count}" -eq 1 ]] \
    && echo "POM-01 --check: live dashy-portal client 선언 필드가 일치한다." \
    || echo "POM-01 --check: 신규 dashy-portal client 추가가 필요하다."
  jq -e '.policy != null' <<<"${policy_json}" >/dev/null \
    && echo "POM-01 --check: live pomerium Vault policy가 일치한다." \
    || echo "POM-01 --check: 신규 pomerium Vault policy 적용이 필요하다."
  exit 0
fi

mkdir -p "${POM01_SECRET_DIR}"
chmod 0700 "${POM01_SECRET_DIR}"

ensure_base64_secret() {
  local target=$1
  if [[ ! -e "${target}" ]]; then
    openssl rand -base64 32 | tr -d '\n' >"${target}"
    printf '\n' >>"${target}"
  fi
  chmod 0600 "${target}"
  [[ -s "${target}" ]]
}

ensure_client_secret() {
  local target=$1
  if [[ ! -e "${target}" ]]; then
    openssl rand -base64 48 | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-48 >"${target}"
    printf '\n' >>"${target}"
  fi
  chmod 0600 "${target}"
  [[ "$(tr -d '\n' <"${target}" | wc -c)" -eq 48 ]]
}

ensure_signing_key() {
  local target=$1
  if [[ ! -e "${target}" ]]; then
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "${target}" 2>/dev/null
  fi
  chmod 0600 "${target}"
  openssl pkey -in "${target}" -check -noout >/dev/null 2>&1
}

ensure_client_secret "${POM01_SECRET_DIR}/client-secret"
ensure_base64_secret "${POM01_SECRET_DIR}/shared-secret"
ensure_base64_secret "${POM01_SECRET_DIR}/cookie-secret"
ensure_signing_key "${POM01_SECRET_DIR}/signing-key.pem"

if [[ "${pomerium_client_count}" -eq 0 ]]; then
  jq --rawfile client_secret "${POM01_SECRET_DIR}/client-secret" \
    '. + {secret: ($client_secret | rtrimstr("\n"))}' \
    "${pomerium_client_declaration}" >"${pomerium_client_payload}"
  http_status=$(curl --silent --show-error \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${client_response}" --write-out '%{http_code}' \
    --request POST \
    --header "@${admin_header}" \
    --header 'Content-Type: application/json' \
    --data-binary "@${pomerium_client_payload}" \
    "${issuer}/admin/realms/platform/clients")
  [[ "${http_status}" == 201 ]] || {
    echo "Pomerium client 생성 실패: HTTP ${http_status}" >&2
    jq '{error,errorMessage}' "${client_response}" >&2 2>/dev/null || true
    exit 1
  }
  echo "POM-01: 기존 realm 객체를 수정하지 않고 Pomerium client 1건을 추가했다."
elif [[ "${needs_post_logout_migration}" == true ]]; then
  client_id=$(jq -r '.[0].id' "${pomerium_clients_json}")
  jq --arg id "${client_id}" \
    --rawfile client_secret "${POM01_SECRET_DIR}/client-secret" \
    '. + {id: $id, secret: ($client_secret | rtrimstr("\n"))}' \
    "${pomerium_client_declaration}" >"${pomerium_client_payload}"
  http_status=$(curl --silent --show-error \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${client_response}" --write-out '%{http_code}' \
    --request PUT \
    --header "@${admin_header}" \
    --header 'Content-Type: application/json' \
    --data-binary "@${pomerium_client_payload}" \
    "${issuer}/admin/realms/platform/clients/${client_id}")
  [[ "${http_status}" == 204 ]] || {
    echo "Pomerium client post-logout URI 보정 실패: HTTP ${http_status}" >&2
    jq '{error,errorMessage}' "${client_response}" >&2 2>/dev/null || true
    exit 1
  }
  echo "POM-01: task 소유 Pomerium client에 exact post-logout URI 한 건을 추가했다."
fi

if [[ "${dashy_client_count}" -eq 0 ]]; then
  http_status=$(curl --silent --show-error \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${client_response}" --write-out '%{http_code}' \
    --request POST \
    --header "@${admin_header}" \
    --header 'Content-Type: application/json' \
    --data-binary "@${dashy_client_declaration}" \
    "${issuer}/admin/realms/platform/clients")
  [[ "${http_status}" == 201 ]] || {
    echo "Dashy client 생성 실패: HTTP ${http_status}" >&2
    jq '{error,errorMessage}' "${client_response}" >&2 2>/dev/null || true
    exit 1
  }
  echo "POM-01: 기존 realm 객체를 수정하지 않고 Dashy public PKCE client 1건을 추가했다."
fi

curl_admin "${issuer}/admin/realms/platform/clients?clientId=pomerium" >"${pomerium_clients_json}"
curl_admin "${issuer}/admin/realms/platform/clients?clientId=dashy-portal" >"${dashy_clients_json}"
client_matches || {
  echo "생성 후 Pomerium client 선언이 일치하지 않는다." >&2
  exit 1
}
dashy_client_matches || {
  echo "생성 후 Dashy client 선언이 일치하지 않는다." >&2
  exit 1
}
client_id=$(jq -r '.[0].id' "${pomerium_clients_json}")
curl_admin "${issuer}/admin/realms/platform/clients/${client_id}/client-secret" \
  | jq -e --rawfile expected "${POM01_SECRET_DIR}/client-secret" \
    '.value == ($expected | rtrimstr("\n"))' >/dev/null

echo "POM-01: 기존 pomerium policy를 선언과 일치시키고 전용 auth role만 쓴다."
{
  printf "cat > /tmp/pom01-policy.hcl <<'HCL'\n"
  cat "${policy_file}"
  printf "HCL\n"
  cat <<'REMOTE'
vault policy write pomerium /tmp/pom01-policy.hcl >/dev/null
rm -f /tmp/pom01-policy.hcl
vault write auth/kubernetes/role/pomerium \
  bound_service_account_names=pomerium \
  bound_service_account_namespaces=pomerium \
  audience=vault \
  token_policies=pomerium \
  token_no_default_policy=true \
  token_ttl=15m token_max_ttl=1h >/dev/null
REMOTE
} | vault_exec

jq -n \
  --rawfile idp_client_secret "${POM01_SECRET_DIR}/client-secret" \
  --rawfile shared_secret "${POM01_SECRET_DIR}/shared-secret" \
  --rawfile cookie_secret "${POM01_SECRET_DIR}/cookie-secret" \
  --rawfile signing_key "${POM01_SECRET_DIR}/signing-key.pem" \
  '{
    idp_client_secret: ($idp_client_secret | rtrimstr("\n")),
    shared_secret: ($shared_secret | rtrimstr("\n")),
    cookie_secret: ($cookie_secret | rtrimstr("\n")),
    signing_key: ($signing_key | rtrimstr("\n"))
  }' >"${vault_payload}"

{
  tr -d '\n' <"${VAULT_ROOT_TOKEN_FILE}"
  printf '\n'
  cat "${vault_payload}"
} | ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
    set -eu
    umask 077
    read -r VAULT_TOKEN
    export VAULT_TOKEN
    trap \"rm -f /tmp/pom01-kv.json\" EXIT
    cat > /tmp/pom01-kv.json
    vault kv put kv/pomerium/runtime @/tmp/pom01-kv.json >/dev/null
  '"

policy_json=$(vault_exec <<'REMOTE'
vault policy read -format=json pomerium
REMOTE
)
policy_matches
role_json=$(vault_exec <<'REMOTE'
vault read -format=json auth/kubernetes/role/pomerium
REMOTE
)
role_matches
vault_exec <<'REMOTE' | jq -e '
  .data.data | keys | sort == ["cookie_secret","idp_client_secret","shared_secret","signing_key"]
' >/dev/null
vault kv get -format=json kv/pomerium/runtime
REMOTE

date -u +'%Y-%m-%dT%H:%M:%SZ' >"${marker_file}"
chmod 0600 "${marker_file}"
echo "POM-01: Pomerium confidential·Dashy public PKCE 최소 흐름, groups mapper와 Vault 적용 검증 통과"
