#!/usr/bin/env bash
# QUALITY-01 전용 PostgreSQL DB/role, Keycloak SAML client, Vault KV/policy/auth role만 다룬다.
# shellcheck disable=SC2029
set -Eeuo pipefail

mode=${1:-}
if [[ "${mode}" != --check && "${mode}" != --apply ]]; then
  echo "사용법: $0 --check|--apply" >&2
  exit 2
fi

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly env_file=${secret_root}/sonarqube/env
readonly vault_token_file=${secret_root}/vault-root.token
readonly kc_secret_dir=${secret_root}/keycloak
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly postgres_host=${POSTGRES_HOST:-rocky@10.10.50.10}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly client_declaration=${repo_root}/gitops/tools/quality-01/keycloak-client.json
readonly runtime_policy=${repo_root}/infra/vault/scripts/policies/sonarqube.hcl
readonly verifier_policy=${repo_root}/infra/vault/scripts/policies/sonarqube-verifier.hcl
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

for required in "${env_file}" "${vault_token_file}" \
  "${kc_secret_dir}/local-admin-password" "${kc_secret_dir}/local-admin-totp"; do
  [[ -f "${required}" && ! -L "${required}" ]] || {
    echo "필수 저장소 밖 입력이 없다: ${required}" >&2
    exit 1
  }
  [[ "$(stat -c %a "${required}")" == 600 ]] || {
    echo "입력은 mode 0600이어야 한다: ${required}" >&2
    exit 1
  }
done

SONARQUBE_DB_PASSWORD=
while IFS='=' read -r key value; do
  case "${key}" in
    SONARQUBE_DB_PASSWORD) SONARQUBE_DB_PASSWORD=${value} ;;
    SONARQUBE_ADMIN_PASSWORD|'') ;;
    *) echo "지원하지 않는 QUALITY-01 env key: ${key}" >&2; exit 1 ;;
  esac
done <"${env_file}"
readonly SONARQUBE_DB_PASSWORD
[[ "${SONARQUBE_DB_PASSWORD}" =~ ^[A-Za-z0-9]{40}$ ]] || {
  echo "SONARQUBE_DB_PASSWORD 형식이 맞지 않는다." >&2
  exit 1
}
jq -e . "${client_declaration}" >/dev/null

role_state=$(ssh "${ssh_options[@]}" "${postgres_host}" \
  "sudo -u postgres psql -XAt -v ON_ERROR_STOP=1 -d postgres -c \"SELECT rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls FROM pg_roles WHERE rolname='sonarqube_user'\"")
db_state=$(ssh "${ssh_options[@]}" "${postgres_host}" \
  "sudo -u postgres psql -XAt -v ON_ERROR_STOP=1 -d postgres -c \"SELECT r.rolname, NOT EXISTS (SELECT 1 FROM aclexplode(COALESCE(d.datacl, acldefault('d', d.datdba))) a WHERE a.grantee=0 AND a.privilege_type='CONNECT'), has_database_privilege('sonarqube_user', d.datname, 'CONNECT') FROM pg_database d JOIN pg_roles r ON r.oid=d.datdba WHERE d.datname='sonarqube'\"")

[[ -z "${role_state}" || "${role_state}" == 't|f|f|f|f|f' ]] || {
  echo "live sonarqube_user role 속성이 최소권한 선언과 다르다: ${role_state}" >&2
  exit 1
}
[[ -z "${db_state}" || "${db_state}" == 'sonarqube_user|t|t' ]] || {
  echo "live sonarqube DB owner/CONNECT 경계가 선언과 다르다: ${db_state}" >&2
  exit 1
}
printf 'QUALITY-01 PostgreSQL: role=%s database=%s\n' \
  "${role_state:+match}" "${db_state:+match}"

if [[ "${mode}" == --apply ]]; then
  if [[ -z "${role_state}" ]]; then
    printf "CREATE ROLE sonarqube_user LOGIN PASSWORD '%s' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;\n" \
      "${SONARQUBE_DB_PASSWORD}" | ssh "${ssh_options[@]}" "${postgres_host}" \
      "sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d postgres" >/dev/null
  else
    printf "ALTER ROLE sonarqube_user PASSWORD '%s';\n" "${SONARQUBE_DB_PASSWORD}" | \
      ssh "${ssh_options[@]}" "${postgres_host}" \
      "sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d postgres" >/dev/null
  fi
  if [[ -z "${db_state}" ]]; then
    printf 'CREATE DATABASE sonarqube OWNER sonarqube_user;\n' | \
      ssh "${ssh_options[@]}" "${postgres_host}" \
      "sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d postgres" >/dev/null
  fi
  printf '%s\n' \
    'REVOKE CONNECT ON DATABASE sonarqube FROM PUBLIC;' \
    'GRANT CONNECT ON DATABASE sonarqube TO sonarqube_user;' | \
    ssh "${ssh_options[@]}" "${postgres_host}" \
    "sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d postgres" >/dev/null
  printf '%s\n' \
    'REVOKE ALL ON SCHEMA public FROM PUBLIC;' \
    'GRANT USAGE, CREATE ON SCHEMA public TO sonarqube_user;' | \
    ssh "${ssh_options[@]}" "${postgres_host}" \
    "sudo -u postgres psql -X -v ON_ERROR_STOP=1 -d sonarqube" >/dev/null
  echo "QUALITY-01 PostgreSQL DB/role을 선언했다."
fi

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  find "${temp_dir}" -type f -delete 2>/dev/null || true
  rmdir "${temp_dir}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
readonly admin_header=${temp_dir}/admin.header
readonly clients_json=${temp_dir}/clients.json
readonly response_json=${temp_dir}/response.json
readonly runtime_payload=${temp_dir}/runtime.json

wait_seconds=$((31 - $(date +%s) % 30))
sleep "${wait_seconds}"
python3 "${repo_root}/gitops/tools/kc-01/browser-login.py" \
  --issuer "${issuer}" \
  --realm master \
  --client-id kc-recovery \
  --redirect-uri "${issuer}/realms/master/account/" \
  --username imcherry-kc-recovery \
  --password-file "${kc_secret_dir}/local-admin-password" \
  --totp-file "${kc_secret_dir}/local-admin-totp" \
  --header-file "${admin_header}" \
  --connect-ip "${connect_ip}" \
  --expect-realm-role admin >/dev/null

curl_admin() {
  curl --silent --show-error --fail \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --header "@${admin_header}" "$@"
}
curl_admin "${issuer}/admin/realms/platform/clients?clientId=sonarqube" >"${clients_json}"
client_count=$(jq 'length' "${clients_json}")
[[ "${client_count}" -le 1 ]] || {
  echo "동일 clientId=sonarqube의 Keycloak client가 ${client_count}건이다." >&2
  exit 1
}

client_matches() {
  jq -e --slurpfile expected "${client_declaration}" '
    length == 1 and
    .[0].clientId == $expected[0].clientId and
    .[0].protocol == "saml" and
    .[0].enabled == true and
    .[0].fullScopeAllowed == false and
    .[0].baseUrl == $expected[0].baseUrl and
    .[0].redirectUris == $expected[0].redirectUris and
    .[0].attributes["saml.assertion.signature"] == "true" and
    .[0].attributes["saml.server.signature"] == "true" and
    .[0].attributes["saml.client.signature"] == "false" and
    .[0].attributes["saml.encrypt"] == "false" and
    .[0].attributes["saml.force.post.binding"] == "true" and
    .[0].attributes["saml_assertion_consumer_url_post"] == $expected[0].attributes["saml_assertion_consumer_url_post"] and
    ([.[0].protocolMappers[]? | select(.name == "login" and .protocolMapper == "saml-user-property-mapper")] | length == 1) and
    ([.[0].protocolMappers[]? | select(.name == "name" and .protocolMapper == "saml-user-property-mapper")] | length == 1) and
    ([.[0].protocolMappers[]? | select(.name == "email" and .protocolMapper == "saml-user-property-mapper")] | length == 1) and
    ([.[0].protocolMappers[]? | select(.name == "groups" and .protocolMapper == "saml-group-membership-mapper" and .config["full.path"] == "false")] | length == 1)
  ' "${clients_json}" >/dev/null
}

if [[ "${client_count}" -eq 1 ]] && ! client_matches; then
  jq '[.[] | {clientId,protocol,enabled,fullScopeAllowed,baseUrl,redirectUris,attributes,protocolMappers}]' "${clients_json}"
  echo "live SonarQube SAML client가 선언과 다르다. 자동 교정하지 않는다." >&2
  exit 1
fi
if [[ "${mode}" == --apply && "${client_count}" -eq 0 ]]; then
  status=$(curl --silent --show-error \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${response_json}" --write-out '%{http_code}' \
    --request POST --header "@${admin_header}" --header 'Content-Type: application/json' \
    --data-binary "@${client_declaration}" \
    "${issuer}/admin/realms/platform/clients")
  [[ "${status}" == 201 ]] || {
    echo "Keycloak SonarQube client 생성 실패: HTTP ${status}" >&2
    exit 1
  }
  curl_admin "${issuer}/admin/realms/platform/clients?clientId=sonarqube" >"${clients_json}"
  client_count=1
fi

if [[ "${client_count}" -eq 1 ]]; then
  client_uuid=$(jq -r '.[0].id' "${clients_json}")
  while IFS= read -r scope_id; do
    [[ -n "${scope_id}" ]] || continue
    if curl_admin "${issuer}/admin/realms/platform/client-scopes/${scope_id}/protocol-mappers/models" | \
      jq -e '[.[] | select(.protocol == "saml" and .protocolMapper == "saml-role-list-mapper")] | length > 0' >/dev/null; then
      if [[ "${mode}" == --apply ]]; then
        curl_admin --request DELETE \
          "${issuer}/admin/realms/platform/clients/${client_uuid}/default-client-scopes/${scope_id}" >/dev/null
      else
        echo "QUALITY-01 Keycloak: inherited role_list scope 분리가 필요하다."
      fi
    fi
  done < <(curl_admin "${issuer}/admin/realms/platform/clients/${client_uuid}/default-client-scopes" | jq -r '.[].id')
fi
echo "QUALITY-01 Keycloak SAML client: $([[ "${client_count}" -eq 1 ]] && echo match || echo absent)"

vault_exec() {
  {
    tr -d '\n' <"${vault_token_file}"
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

check_policy() {
  local name=$1 expected=$2 live
  if live=$(vault_exec <<REMOTE
vault policy read ${name} 2>/dev/null
REMOTE
  ); then
    [[ "${live}" == "$(<"${expected}")" ]] || {
      echo "live Vault policy ${name}이 선언과 다르다." >&2
      exit 1
    }
    echo "QUALITY-01 Vault policy ${name}: match"
  else
    echo "QUALITY-01 Vault policy ${name}: absent"
  fi
}
check_policy sonarqube "${runtime_policy}"
check_policy sonarqube-verifier "${verifier_policy}"

if [[ "${mode}" == --apply ]]; then
  for policy in "${runtime_policy}" "${verifier_policy}"; do
    name=$(basename "${policy}" .hcl)
    {
      printf "cat > /tmp/%s.hcl <<'HCL'\n" "${name}"
      cat "${policy}"
      printf 'HCL\n'
      printf 'vault policy write %s /tmp/%s.hcl >/dev/null\n' "${name}" "${name}"
      printf 'find /tmp/%s.hcl -delete\n' "${name}"
    } | vault_exec
  done
  vault_exec <<'REMOTE'
vault write auth/kubernetes/role/sonarqube \
  bound_service_account_names=sonarqube \
  bound_service_account_namespaces=sonarqube \
  audience=vault token_policies=sonarqube token_no_default_policy=true \
  token_ttl=15m token_max_ttl=1h >/dev/null
vault write auth/kubernetes/role/sonarqube-verifier \
  bound_service_account_names=sonarqube-verifier \
  bound_service_account_namespaces=sonarqube \
  audience=vault token_policies=sonarqube-verifier token_no_default_policy=true \
  token_ttl=15m token_max_ttl=1h >/dev/null
REMOTE
  jq -n --arg db_password "${SONARQUBE_DB_PASSWORD}" \
    '{db_password: $db_password}' >"${runtime_payload}"
  {
    tr -d '\n' <"${vault_token_file}"
    printf '\n'
    cat "${runtime_payload}"
  } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
      set -eu
      read -r VAULT_TOKEN
      export VAULT_TOKEN
      umask 077
      trap \"find /tmp/quality01-runtime.json -delete\" EXIT
      cat > /tmp/quality01-runtime.json
      vault kv put kv/sonarqube/runtime @/tmp/quality01-runtime.json >/dev/null
    '"
  echo "QUALITY-01 Vault KV/policy/auth roles를 선언했다."
fi
