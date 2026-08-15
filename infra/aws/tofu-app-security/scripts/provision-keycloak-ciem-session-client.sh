#!/usr/bin/env bash
# AWS-SEC-03 Keycloak session revoke service client를 check-first로 관리한다.
set -Eeuo pipefail

mode=${1:-}
[[ $mode == --check || $mode == --apply ]] || {
  echo "사용법: $0 --check|--apply" >&2
  exit 2
}

readonly repo_root=$(git rev-parse --show-toplevel)
readonly kc_secret_dir=${KC01_SECRET_DIR:-/home/imcherry/secrets/ktcloud4-bean/keycloak}
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly client_id=aws-ciem-session-revoke
readonly aws_secret_id=hr-system-prod-ciem-keycloak-session
readonly declaration=${repo_root}/infra/aws/tofu-app-security/scripts/keycloak-ciem-session-client.json

for required in local-admin-password local-admin-totp; do
  [[ -s $kc_secret_dir/$required ]] || { echo "KC-01 복구 입력이 없다: $required" >&2; exit 1; }
done
jq -e . "$declaration" >/dev/null

umask 077
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT HUP INT TERM
readonly admin_header=$temp_dir/admin.header
readonly clients_json=$temp_dir/clients.json
readonly mappings_json=$temp_dir/mappings.json
readonly scope_mappings_json=$temp_dir/scope-mappings.json
readonly default_scopes_json=$temp_dir/default-client-scopes.json
readonly response_json=$temp_dir/response.json
readonly client_secret_json=$temp_dir/client-secret.json
readonly client_secret_file=$temp_dir/client-secret
readonly aws_secret_file=$temp_dir/aws-secret.json
readonly aws_put_file=$temp_dir/aws-put.json

# 직전 Keycloak 인증과 TOTP window를 재사용하지 않는다.
sleep "$((31 - $(date +%s) % 30))"
python3 "$repo_root/gitops/tools/kc-01/browser-login.py" \
  --issuer "$issuer" --realm master --client-id kc-recovery \
  --redirect-uri "$issuer/realms/master/account/" --username imcherry-kc-recovery \
  --password-file "$kc_secret_dir/local-admin-password" --totp-file "$kc_secret_dir/local-admin-totp" \
  --header-file "$admin_header" --connect-ip "$connect_ip" --capture-callback --expect-realm-role admin >/dev/null

curl_admin() {
  curl --silent --show-error --fail --resolve "$issuer_host:443:$connect_ip" --header "@$admin_header" "$@"
}

load_client() {
  curl_admin "$issuer/admin/realms/platform/clients?clientId=$client_id" >"$clients_json"
  local count
  count=$(jq 'length' "$clients_json")
  [[ $count -le 1 ]] || { echo "clientId=$client_id 객체가 복수다." >&2; exit 1; }
}

client_matches() {
  jq -e '
    length == 1 and
    .[0].clientId == "aws-ciem-session-revoke" and .[0].enabled == true and
    .[0].protocol == "openid-connect" and .[0].publicClient == false and
    .[0].clientAuthenticatorType == "client-secret" and
    .[0].standardFlowEnabled == false and .[0].implicitFlowEnabled == false and
    .[0].directAccessGrantsEnabled == false and .[0].serviceAccountsEnabled == true and
    (.[0].authorizationServicesEnabled != true) and .[0].fullScopeAllowed == false and
    .[0].redirectUris == [] and .[0].webOrigins == []
  ' "$clients_json" >/dev/null
}

load_mapping() {
  local internal_id realm_management_id service_account_id
  internal_id=$(jq -r '.[0].id' "$clients_json")
  realm_management_id=$(curl_admin "$issuer/admin/realms/platform/clients?clientId=realm-management" | jq -er 'if length == 1 then .[0].id else error("realm-management client is not unique") end')
  service_account_id=$(curl_admin "$issuer/admin/realms/platform/clients/$internal_id/service-account-user" | jq -er '.id')
  curl_admin "$issuer/admin/realms/platform/users/$service_account_id/role-mappings/clients/$realm_management_id" >"$mappings_json"
}

load_scope_mapping() {
  local internal_id realm_management_id
  internal_id=$(jq -r '.[0].id' "$clients_json")
  realm_management_id=$(curl_admin "$issuer/admin/realms/platform/clients?clientId=realm-management" | jq -er 'if length == 1 then .[0].id else error("realm-management client is not unique") end')
  curl_admin "$issuer/admin/realms/platform/clients/$internal_id/scope-mappings/clients/$realm_management_id" >"$scope_mappings_json"
}

load_default_scopes() {
  local internal_id
  internal_id=$(jq -r '.[0].id' "$clients_json")
  curl_admin "$issuer/admin/realms/platform/clients/$internal_id/default-client-scopes" >"$default_scopes_json"
}

default_scopes_match() {
  jq -e '([.[].name] | sort) == ["roles", "service_account"]' "$default_scopes_json" >/dev/null
}

default_scopes_are_safe() {
  jq -e '([.[].name] - ["roles", "service_account"] | length) == 0' "$default_scopes_json" >/dev/null
}

roles_client_scope_id() {
  curl_admin "$issuer/admin/realms/platform/client-scopes" | jq -er '
    [.[] | select(.name == "roles" and .protocol == "openid-connect")]
    | if length == 1 then .[0].id else error("roles client scope is not unique") end
  '
}

mapping_matches() {
  jq -e '([.[].name] | sort) == ["manage-users", "query-users"]' "$mappings_json" >/dev/null
}

mapping_is_safe_to_extend() {
  jq -e '([.[].name] - ["manage-users", "query-users"] | length) == 0' "$mappings_json" >/dev/null
}

scope_mapping_matches() {
  jq -e '([.[].name] | sort) == ["manage-users", "query-users"]' "$scope_mappings_json" >/dev/null
}

scope_mapping_is_safe_to_extend() {
  jq -e '([.[].name] - ["manage-users", "query-users"] | length) == 0' "$scope_mappings_json" >/dev/null
}

required_roles() {
  local realm_management_id
  realm_management_id=$(curl_admin "$issuer/admin/realms/platform/clients?clientId=realm-management" | jq -er 'if length == 1 then .[0].id else error("realm-management client is not unique") end')
  curl_admin "$issuer/admin/realms/platform/clients/$realm_management_id/roles" | jq '[.[] | select(.name == "query-users" or .name == "manage-users")] | if length == 2 then . else error("required realm-management roles missing") end'
}

write_aws_secret() {
  local current=$temp_dir/current-secret.json error_file=$temp_dir/aws-get.err http_status response_summary
  curl_admin "$issuer/admin/realms/platform/clients/$(jq -r '.[0].id' "$clients_json")/client-secret" >"$client_secret_json"
  if ! jq -e '.value | type == "string" and length > 0' "$client_secret_json" >/dev/null; then
    http_status=$(curl --silent --show-error --resolve "$issuer_host:443:$connect_ip" --output "$client_secret_json" --write-out '%{http_code}' \
      --request POST --header "@$admin_header" --header 'Content-Type: application/json' --data '{}' \
      "$issuer/admin/realms/platform/clients/$(jq -r '.[0].id' "$clients_json")/client-secret")
    [[ $http_status == 200 ]] || { echo "Keycloak client secret 생성 실패: HTTP $http_status" >&2; return 1; }
  fi
  if ! jq -e '.value | type == "string" and length > 0' "$client_secret_json" >/dev/null; then
    response_summary=$(jq -c '
      if type == "object" then
        {keys: (keys | sort), value_type: (.value | type), value_length: (.value | if type == "string" then length else 0 end)}
      else {type: type} end
    ' "$client_secret_json" 2>/dev/null || printf '%s' '{"type":"non-json"}')
    echo "Keycloak client secret 응답이 비어 있다: $response_summary" >&2
    return 1
  fi
  jq -r '.value' "$client_secret_json" >"$client_secret_file"
  [[ -s $client_secret_file ]] || { echo 'Keycloak client secret이 비어 있다.' >&2; return 1; }
  jq -n --arg client_id "$client_id" --rawfile client_secret "$client_secret_file" \
    '{client_id:$client_id,client_secret:($client_secret|rtrimstr("\n"))}' >"$aws_secret_file"
  jq -e --arg client_id "$client_id" '
    .client_id == $client_id and (.client_secret | type == "string" and length > 0)
  ' "$aws_secret_file" >/dev/null || { echo 'AWS Keycloak session secret payload가 비어 있다.' >&2; return 1; }
  if aws secretsmanager get-secret-value --secret-id "$aws_secret_id" --query SecretString --output text >"$current" 2>"$error_file"; then
    jq -e --slurpfile expected "$aws_secret_file" '. == $expected[0]' "$current" >/dev/null || {
      echo 'AWS Keycloak session secret이 live client와 달라 보정하지 않는다.' >&2
      return 1
    }
  elif grep -q 'ResourceNotFoundException' "$error_file"; then
    jq -n --arg secret_id "$aws_secret_id" --slurpfile payload "$aws_secret_file" \
      '{SecretId:$secret_id,SecretString:($payload[0]|tojson)}' >"$aws_put_file"
    jq -e '.SecretId != "" and (.SecretString | type == "string" and length > 0)' "$aws_put_file" >/dev/null || {
      echo 'AWS Secrets Manager 요청 payload가 비어 있다.' >&2
      return 1
    }
    aws secretsmanager put-secret-value --cli-input-json "file://$aws_put_file" >/dev/null
  else
    echo 'AWS Keycloak session secret 조회 실패' >&2
    return 1
  fi
}

load_client
if [[ $(jq 'length' "$clients_json") -eq 0 ]]; then
  if [[ $mode == --check ]]; then
    echo 'AWS-SEC-03 Keycloak client=absent create=required user_change=0 group_change=0'
    exit 0
  fi
  http_status=$(curl --silent --show-error --resolve "$issuer_host:443:$connect_ip" --output "$response_json" --write-out '%{http_code}' \
    --request POST --header "@$admin_header" --header 'Content-Type: application/json' --data-binary "@$declaration" \
    "$issuer/admin/realms/platform/clients")
  [[ $http_status == 201 ]] || { echo "Keycloak service client 생성 실패: HTTP $http_status" >&2; exit 1; }
  load_client
fi
client_matches || { echo 'live Keycloak service client가 선언과 다르다. 자동 보정하지 않는다.' >&2; exit 1; }
load_default_scopes
if ! default_scopes_match; then
  default_scopes_are_safe || { echo 'service client에 예상 밖 default client scope이 있어 보정하지 않는다.' >&2; exit 1; }
  if [[ $mode == --check ]]; then
    echo 'AWS-SEC-03 Keycloak client=present default-scope=not-ready user_change=0 group_change=0'
    exit 1
  fi
  internal_id=$(jq -r '.[0].id' "$clients_json")
  http_status=$(curl --silent --show-error --resolve "$issuer_host:443:$connect_ip" --output "$response_json" --write-out '%{http_code}' \
    --request PUT --header "@$admin_header" \
    "$issuer/admin/realms/platform/clients/$internal_id/default-client-scopes/$(roles_client_scope_id)")
  [[ $http_status == 204 ]] || { echo "Keycloak roles default client scope 연결 실패: HTTP $http_status" >&2; exit 1; }
  load_default_scopes
fi
default_scopes_match || { echo 'Keycloak default client scope가 정확하지 않다.' >&2; exit 1; }
load_mapping
load_scope_mapping
if ! mapping_matches; then
  mapping_is_safe_to_extend || { echo 'service account에 예상 밖 realm-management role이 있어 보정하지 않는다.' >&2; exit 1; }
  if [[ $mode == --check ]]; then
    echo 'AWS-SEC-03 Keycloak client=present realm-management-roles=not-ready user_change=0 group_change=0'
    exit 1
  fi
  internal_id=$(jq -r '.[0].id' "$clients_json")
  realm_management_id=$(curl_admin "$issuer/admin/realms/platform/clients?clientId=realm-management" | jq -er 'if length == 1 then .[0].id else error("realm-management client is not unique") end')
  service_account_id=$(curl_admin "$issuer/admin/realms/platform/clients/$internal_id/service-account-user" | jq -er '.id')
  roles=$(required_roles)
  http_status=$(curl --silent --show-error --resolve "$issuer_host:443:$connect_ip" --output "$response_json" --write-out '%{http_code}' \
    --request POST --header "@$admin_header" --header 'Content-Type: application/json' --data-binary "$roles" \
    "$issuer/admin/realms/platform/users/$service_account_id/role-mappings/clients/$realm_management_id")
  [[ $http_status == 204 ]] || { echo "Keycloak service account role mapping 실패: HTTP $http_status" >&2; exit 1; }
  load_mapping
fi
mapping_matches || { echo 'Keycloak service account role mapping이 정확하지 않다.' >&2; exit 1; }
if ! scope_mapping_matches; then
  scope_mapping_is_safe_to_extend || { echo 'service client scope에 예상 밖 realm-management role이 있어 보정하지 않는다.' >&2; exit 1; }
  if [[ $mode == --check ]]; then
    echo 'AWS-SEC-03 Keycloak client=present token-scope=not-ready user_change=0 group_change=0'
    exit 1
  fi
  internal_id=$(jq -r '.[0].id' "$clients_json")
  realm_management_id=$(curl_admin "$issuer/admin/realms/platform/clients?clientId=realm-management" | jq -er 'if length == 1 then .[0].id else error("realm-management client is not unique") end')
  roles=$(required_roles)
  http_status=$(curl --silent --show-error --resolve "$issuer_host:443:$connect_ip" --output "$response_json" --write-out '%{http_code}' \
    --request POST --header "@$admin_header" --header 'Content-Type: application/json' --data-binary "$roles" \
    "$issuer/admin/realms/platform/clients/$internal_id/scope-mappings/clients/$realm_management_id")
  [[ $http_status == 204 ]] || { echo "Keycloak service client scope mapping 실패: HTTP $http_status" >&2; exit 1; }
  load_scope_mapping
fi
scope_mapping_matches || { echo 'Keycloak service client token scope가 정확하지 않다.' >&2; exit 1; }
case "$mode" in
  --apply) write_aws_secret ;;
esac
echo "AWS-SEC-03 Keycloak=PASS client=$client_id roles=query-users,manage-users user_change=0 group_change=0"
