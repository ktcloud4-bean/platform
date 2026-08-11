#!/usr/bin/env bash
# WAZUH-02-FIX-01 Keycloak OIDC client/role/group mapping을 check-first로 관리한다.
# 사용자, MFA, 기존 group membership은 변경하지 않는다.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법: ./gitops/tools/wazuh-02-fix-01/provision-keycloak.sh --check|--apply|--rollback

--check: 비밀 제외 client/role/group mapping과 저장소 밖 client secret 일치를 확인한다.
--apply: 없는 wazuh confidential client, wazuh-admin client role, /platform-privileged mapping만 만든다.
--rollback: 위 client와 그 전용 저장소 밖 secret만 제거한다. 기존 사용자와 group은 유지한다.
EOF
}

readonly mode=${1:-}
case ${mode} in
  --check|--apply|--rollback) ;;
  *) usage >&2; exit 2 ;;
esac

readonly repo_root=$(git rev-parse --show-toplevel)
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly kc_secret_dir=${KC01_SECRET_DIR:-${secret_root}/keycloak}
readonly wazuh_secret_dir=${WAZUH01_SECRET_DIR:-${secret_root}/wazuh}
readonly client_secret_file=${WAZUH02_OIDC_CLIENT_SECRET_FILE:-${wazuh_secret_dir}/wazuh-oidc-client-secret}
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly client_id_name=wazuh
readonly client_role_name=wazuh-admin
readonly group_name=platform-privileged
readonly client_declaration=${repo_root}/gitops/tools/wazuh-02-fix-01/keycloak-client.json

for directory in "${kc_secret_dir}" "${wazuh_secret_dir}"; do
  case ${directory} in
    /|/home|/home/*/projects|/home/*/projects/*|"${repo_root}"|"${repo_root}"/*)
      echo "secret directory가 너무 넓거나 저장소 경로다: ${directory}" >&2
      exit 1
      ;;
  esac
done
for required in local-admin-password local-admin-totp; do
  path=${kc_secret_dir}/${required}
  [[ -f ${path} && ! -L ${path} && -s ${path} && $(stat -c %a "${path}") == 600 ]] || {
    echo "KC-01 복구 입력이 mode 0600 regular file이 아니다: ${required}" >&2
    exit 1
  }
done
python3 - "${connect_ip}" <<'PY'
import ipaddress, sys
assert ipaddress.ip_address(sys.argv[1]).version == 4
PY
jq -e . "${client_declaration}" >/dev/null

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  find "${temp_dir}" -type f -delete 2>/dev/null || true
  rmdir "${temp_dir}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

readonly admin_header=${temp_dir}/keycloak-admin.header
readonly clients_json=${temp_dir}/clients.json
readonly group_json=${temp_dir}/group.json
readonly role_json=${temp_dir}/role.json
readonly mappings_json=${temp_dir}/mappings.json
readonly response_json=${temp_dir}/response.json
readonly payload_json=${temp_dir}/payload.json
readonly client_secret_json=${temp_dir}/client-secret.json

# 같은 TOTP window를 직전 검증과 재사용하지 않는다.
sleep "$((31 - $(date +%s) % 30))"
python3 "${repo_root}/gitops/tools/kc-01/browser-login.py" \
  --issuer "${issuer}" --realm master --client-id kc-recovery \
  --redirect-uri "${issuer}/realms/master/account/" \
  --username imcherry-kc-recovery \
  --password-file "${kc_secret_dir}/local-admin-password" \
  --totp-file "${kc_secret_dir}/local-admin-totp" \
  --header-file "${admin_header}" --connect-ip "${connect_ip}" \
  --capture-callback --expect-realm-role admin >/dev/null

curl_admin() {
  curl --silent --show-error --fail \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --header "@${admin_header}" "$@"
}

client_secret_state() {
  [[ -f ${client_secret_file} && ! -L ${client_secret_file} ]] || { echo missing; return; }
  [[ $(stat -c %a "${client_secret_file}") == 600 ]] || { echo invalid; return; }
  local bytes lines last_byte
  bytes=$(wc -c <"${client_secret_file}")
  lines=$(wc -l <"${client_secret_file}")
  last_byte=$(tail -c 1 "${client_secret_file}" | od -An -tu1 | tr -d ' ')
  if [[ ${bytes} -eq 49 && ${lines} -eq 1 && ${last_byte} == 10 ]] &&
     head -n 1 "${client_secret_file}" | LC_ALL=C grep -Eq '^[A-Za-z0-9]{48}$'; then
    echo canonical
  else
    echo invalid
  fi
}

load_client() {
  curl_admin "${issuer}/admin/realms/platform/clients?clientId=${client_id_name}" >"${clients_json}"
}

load_group() {
  curl_admin "${issuer}/admin/realms/platform/groups?search=${group_name}&exact=true&briefRepresentation=false" \
    | jq --arg name "${group_name}" '[.[] | select(.name == $name and .path == ("/" + $name))]' >"${group_json}"
}

client_matches() {
  jq -e '
    length == 1 and
    .[0].clientId == "wazuh" and .[0].enabled == true and
    .[0].protocol == "openid-connect" and .[0].publicClient == false and
    .[0].clientAuthenticatorType == "client-secret" and
    .[0].standardFlowEnabled == true and .[0].implicitFlowEnabled == false and
    .[0].directAccessGrantsEnabled == false and .[0].serviceAccountsEnabled == false and
    (.[0].authorizationServicesEnabled != true) and .[0].fullScopeAllowed == false and
    .[0].rootUrl == "https://wazuh.imcherry5778.xyz" and
    .[0].baseUrl == "https://wazuh.imcherry5778.xyz/" and
    .[0].redirectUris == ["https://wazuh.imcherry5778.xyz/auth/openid/login"] and
    .[0].webOrigins == ["https://wazuh.imcherry5778.xyz"] and
    .[0].attributes["post.logout.redirect.uris"] == "https://wazuh.imcherry5778.xyz" and
    ([.[0].protocolMappers[]? | select(
      .name == "wazuh-client-roles" and .protocol == "openid-connect" and
      .protocolMapper == "oidc-usermodel-client-role-mapper" and
      .config["usermodel.clientRoleMapping.clientId"] == "wazuh" and
      (.config["usermodel.clientRoleMapping.rolePrefix"] // "") == "" and
      .config["claim.name"] == "wazuh_roles" and .config["jsonType.label"] == "String" and
      .config.multivalued == "true" and .config["id.token.claim"] == "true" and
      .config["access.token.claim"] == "true" and .config["userinfo.token.claim"] == "true"
    )] | length == 1)
  ' "${clients_json}" >/dev/null
}

safe_client_summary() {
  jq '[.[] | {
    clientId, enabled, protocol, publicClient, clientAuthenticatorType,
    standardFlowEnabled, implicitFlowEnabled, directAccessGrantsEnabled,
    serviceAccountsEnabled, authorizationServicesEnabled, fullScopeAllowed,
    consentRequired, frontchannelLogout, rootUrl, baseUrl, redirectUris, webOrigins,
    defaultClientScopes, optionalClientScopes,
    attributes:{post_logout_redirect_uris:.attributes["post.logout.redirect.uris"]},
    protocolMappers:[.protocolMappers[]? | select(.name == "wazuh-client-roles") |
      {name, protocol, protocolMapper, config}]
  }]' "${clients_json}"
}

load_role() {
  local internal_id=$1
  if ! curl_admin "${issuer}/admin/realms/platform/clients/${internal_id}/roles/${client_role_name}" >"${role_json}" 2>/dev/null; then
    printf '{}' >"${role_json}"
  fi
}

role_matches() {
  jq -e --arg name "${client_role_name}" '
    .name == $name and .composite == false and .clientRole == true
  ' "${role_json}" >/dev/null
}

load_group_mappings() {
  local group_id=$1 internal_id=$2
  curl_admin "${issuer}/admin/realms/platform/groups/${group_id}/role-mappings/clients/${internal_id}" >"${mappings_json}"
}

mapping_is_safe() {
  jq -e --arg role "${client_role_name}" '
    ([.[].name] - [$role] | length) == 0
  ' "${mappings_json}" >/dev/null
}

mapping_present() {
  jq -e --arg role "${client_role_name}" '[.[].name] | index($role) != null' "${mappings_json}" >/dev/null
}

load_client
client_count=$(jq 'length' "${clients_json}")
load_group
group_count=$(jq 'length' "${group_json}")
[[ ${group_count} -eq 1 ]] || {
  echo "path=/${group_name} live 객체가 ${group_count}건이다. 변경하지 않는다." >&2
  exit 1
}
group_id=$(jq -r '.[0].id' "${group_json}")

if [[ ${mode} == --rollback ]]; then
  case ${client_count} in
    0)
      [[ $(client_secret_state) == missing ]] || {
        echo 'wazuh client는 없는데 저장소 밖 OIDC secret이 남아 있다. 자동 삭제하지 않는다.' >&2
        exit 1
      }
      echo 'WAZUH-02-FIX-01 Keycloak rollback=already-absent'
      exit 0
      ;;
    1) ;;
    *) echo "clientId=wazuh live 객체가 ${client_count}건이다. 변경하지 않는다." >&2; exit 1 ;;
  esac
  client_matches || { echo 'wazuh client 선언이 다르다. 삭제하지 않는다.' >&2; exit 1; }
  internal_id=$(jq -r '.[0].id' "${clients_json}")
  load_role "${internal_id}"
  role_matches || { echo 'wazuh-admin client role이 다르다. 삭제하지 않는다.' >&2; exit 1; }
  load_group_mappings "${group_id}" "${internal_id}"
  mapping_is_safe && mapping_present || {
    echo '/platform-privileged의 Wazuh client role mapping이 선언과 다르다. 삭제하지 않는다.' >&2
    exit 1
  }
  curl_admin --request DELETE "${issuer}/admin/realms/platform/clients/${internal_id}" >/dev/null
  find "${wazuh_secret_dir}" -maxdepth 1 -type f -name "$(basename "${client_secret_file}")" -delete
  echo 'WAZUH-02-FIX-01 Keycloak rollback=PASS client=wazuh client-role=wazuh-admin removed'
  exit 0
fi

case ${client_count} in
  0)
    echo 'WAZUH-02-FIX-01 Keycloak diff: client=wazuh -> create'
    ;;
  1)
    client_matches || { safe_client_summary; echo 'wazuh client 선언이 다르다. 변경하지 않는다.' >&2; exit 1; }
    internal_id=$(jq -r '.[0].id' "${clients_json}")
    load_role "${internal_id}"
    if role_matches; then
      load_group_mappings "${group_id}" "${internal_id}"
      mapping_is_safe || { echo '/platform-privileged에 범위 밖 Wazuh role이 있다. 변경하지 않는다.' >&2; exit 1; }
      if mapping_present; then
        [[ ${mode} == --check ]] || echo 'WAZUH-02-FIX-01 Keycloak diff: client/role/group mapping -> declared'
      else
        echo 'WAZUH-02-FIX-01 Keycloak diff: /platform-privileged -> wazuh-admin mapping create'
      fi
      state=$(client_secret_state)
      [[ ${state} == canonical ]] || { echo 'Wazuh OIDC client secret input이 mode 0600 canonical file이 아니다.' >&2; exit 1; }
      curl_admin "${issuer}/admin/realms/platform/clients/${internal_id}/client-secret" >"${client_secret_json}"
      jq -e --rawfile expected "${client_secret_file}" '.value == ($expected | rtrimstr("\n"))' "${client_secret_json}" >/dev/null || {
        echo 'live wazuh client secret과 저장소 밖 입력이 다르다. 변경하지 않는다.' >&2
        exit 1
      }
    else
      echo 'WAZUH-02-FIX-01 Keycloak diff: client role=wazuh-admin -> create'
    fi
    ;;
  *) echo "clientId=wazuh live 객체가 ${client_count}건이다. 변경하지 않는다." >&2; exit 1 ;;
esac

if [[ ${mode} == --check ]]; then
  if mapping_present; then
    echo 'WAZUH-02-FIX-01 Keycloak=PASS client=wazuh role=wazuh-admin group=/platform-privileged user-change=0'
  fi
  exit 0
fi

install -d -m 0700 "${wazuh_secret_dir}"
if [[ ${client_count} -eq 0 ]]; then
  [[ ! -e ${client_secret_file} ]] || { echo 'wazuh client secret file이 이미 있어 생성하지 않는다.' >&2; exit 1; }
  openssl rand -hex 24 >"${client_secret_file}"
  chmod 0600 "${client_secret_file}"
  [[ $(client_secret_state) == canonical ]] || { echo 'wazuh client secret 생성 형식이 잘못됐다.' >&2; exit 1; }
  jq --rawfile secret "${client_secret_file}" '. + {secret: ($secret | rtrimstr("\n"))}' \
    "${client_declaration}" >"${payload_json}"
  http_status=$(curl --silent --show-error --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${response_json}" --write-out '%{http_code}' --request POST \
    --header "@${admin_header}" --header 'Content-Type: application/json' \
    --data-binary "@${payload_json}" "${issuer}/admin/realms/platform/clients")
  [[ ${http_status} == 201 ]] || { echo "wazuh client 생성 실패: HTTP ${http_status}" >&2; exit 1; }
  load_client
    client_matches || { safe_client_summary; echo '생성 후 wazuh client 선언 일치 검증에 실패했다.' >&2; exit 1; }
fi

internal_id=$(jq -r '.[0].id' "${clients_json}")
load_role "${internal_id}"
if ! role_matches; then
  jq -n --arg name "${client_role_name}" --arg description 'WAZUH-02-FIX-01 privileged Wazuh Dashboard administrator role' \
    '{name:$name, description:$description}' >"${payload_json}"
  http_status=$(curl --silent --show-error --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${response_json}" --write-out '%{http_code}' --request POST \
    --header "@${admin_header}" --header 'Content-Type: application/json' \
    --data-binary "@${payload_json}" "${issuer}/admin/realms/platform/clients/${internal_id}/roles")
  [[ ${http_status} == 201 ]] || { echo "wazuh-admin client role 생성 실패: HTTP ${http_status}" >&2; exit 1; }
  load_role "${internal_id}"
  role_matches || { echo '생성 후 wazuh-admin client role 선언 일치 검증에 실패했다.' >&2; exit 1; }
fi

load_group_mappings "${group_id}" "${internal_id}"
mapping_is_safe || { echo '/platform-privileged에 범위 밖 Wazuh role이 있다. 변경하지 않는다.' >&2; exit 1; }
if ! mapping_present; then
  jq -s '.' "${role_json}" >"${payload_json}"
  http_status=$(curl --silent --show-error --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${response_json}" --write-out '%{http_code}' --request POST \
    --header "@${admin_header}" --header 'Content-Type: application/json' \
    --data-binary "@${payload_json}" \
    "${issuer}/admin/realms/platform/groups/${group_id}/role-mappings/clients/${internal_id}")
  [[ ${http_status} == 204 ]] || { echo "platform-privileged role mapping 생성 실패: HTTP ${http_status}" >&2; exit 1; }
fi

load_group_mappings "${group_id}" "${internal_id}"
mapping_is_safe && mapping_present || { echo '적용 후 Wazuh group role mapping 검증에 실패했다.' >&2; exit 1; }
[[ $(client_secret_state) == canonical ]] || { echo 'Wazuh OIDC client secret input이 mode 0600 canonical file이 아니다.' >&2; exit 1; }
curl_admin "${issuer}/admin/realms/platform/clients/${internal_id}/client-secret" >"${client_secret_json}"
jq -e --rawfile expected "${client_secret_file}" '.value == ($expected | rtrimstr("\n"))' "${client_secret_json}" >/dev/null || {
  echo '적용 후 live wazuh client secret 일치 검증에 실패했다.' >&2
  exit 1
}
echo 'WAZUH-02-FIX-01 Keycloak=PASS client=wazuh role=wazuh-admin group=/platform-privileged user-change=0'
