#!/usr/bin/env bash
# AWS-SEC-02 Amazon Managed Grafana 전용 Keycloak SAML client를 check-first로 관리한다.
# 기존 사용자, 기존 group membership, 기존 client는 자동 보정하거나 삭제하지 않는다.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법:
  ./scripts/provision-keycloak-grafana-saml.sh --check|--apply --workspace-endpoint <endpoint>

--check: Grafana 전용 SAML client, 네 assertion mapper, 빈 grafana-amg-editors group을 확인한다.
--apply: 없는 Grafana SAML client/mapper와 빈 grafana-amg-editors group만 추가한다.
EOF
}

readonly mode=${1:-}
shift || true
[[ ${mode} == --check || ${mode} == --apply ]] || { usage >&2; exit 2; }

workspace_endpoint=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --workspace-endpoint) workspace_endpoint=${2:-}; shift 2 ;;
    *) usage >&2; exit 2 ;;
  esac
done
[[ ${workspace_endpoint} =~ ^g-[a-z0-9]+\.grafana-workspace\.ap-northeast-2\.amazonaws\.com$ ]] || {
  echo 'workspace endpoint 형식이 Amazon Managed Grafana ap-northeast-2 endpoint와 다르다.' >&2
  exit 1
}

readonly repo_root=$(git rev-parse --show-toplevel)
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly kc_secret_dir=${KC01_SECRET_DIR:-${secret_root}/keycloak}
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly entity_id="https://${workspace_endpoint}/saml/metadata"
readonly acs_url="https://${workspace_endpoint}/saml/acs"
readonly browser_origin="https://${workspace_endpoint}"
readonly editor_group_name=grafana-amg-editors

case ${kc_secret_dir} in
  /|/home|/home/*/projects|/home/*/projects/*|"${repo_root}"|"${repo_root}"/*)
    echo "Keycloak secret directory가 너무 넓거나 저장소 경로다: ${kc_secret_dir}" >&2
    exit 1
    ;;
esac
[[ ${kc_secret_dir} = /* ]] || { echo 'Keycloak secret directory는 절대 경로여야 한다.' >&2; exit 1; }
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

umask 077
temp_dir=$(mktemp -d)
cleanup() {
  find "${temp_dir}" -type f -delete 2>/dev/null || true
  rmdir "${temp_dir}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

readonly admin_header=${temp_dir}/keycloak-admin.header
readonly clients_json=${temp_dir}/clients.json
readonly mappers_json=${temp_dir}/mappers.json
readonly groups_json=${temp_dir}/groups.json
readonly members_json=${temp_dir}/members.json
readonly payload_json=${temp_dir}/payload.json
readonly response_body=${temp_dir}/response.json

# 직전 Keycloak 검증과 같은 TOTP 값을 재사용하지 않는다.
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

post_json() {
  local url=$1 status
  status=$(curl --silent --show-error \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --header "@${admin_header}" --header 'Content-Type: application/json' \
    --output "${response_body}" --write-out '%{http_code}' \
    --request POST --data-binary "@${payload_json}" "${url}")
  [[ ${status} == 201 || ${status} == 204 ]] || {
    echo "Keycloak object create HTTP ${status}" >&2
    exit 1
  }
}

load_client() {
  curl_admin --get --data-urlencode "clientId=${entity_id}" \
    --data-urlencode 'briefRepresentation=false' \
    "${issuer}/admin/realms/platform/clients" >"${clients_json}"
}

client_matches() {
  jq -e --arg entity "${entity_id}" --arg acs "${acs_url}" --arg origin "${browser_origin}" '
    length == 1 and .[0].clientId == $entity and .[0].enabled == true and .[0].protocol == "saml" and
    (.[0].redirectUris | sort) == ([$acs, ($origin + "/*")] | sort) and
    .[0].attributes["saml_assertion_consumer_url_post"] == $acs and
    .[0].attributes["saml_name_id_format"] == "email" and
    .[0].attributes["saml_force_name_id_format"] == "true" and
    .[0].attributes["saml.server.signature"] == "true" and
    .[0].attributes["saml.assertion.signature"] == "true" and
    .[0].attributes["saml.authnstatement"] == "true" and
    .[0].attributes["saml_force_post_binding"] == "true" and
    .[0].attributes["saml.client.signature"] == "false"
  ' "${clients_json}" >/dev/null
}

safe_client_summary() {
  jq '[.[] | {enabled, protocol, redirectUris, attributes:{
    saml_assertion_consumer_url_post:.attributes["saml_assertion_consumer_url_post"],
    saml_name_id_format:.attributes["saml_name_id_format"],
    saml_force_name_id_format:.attributes["saml_force_name_id_format"],
    saml_server_signature:.attributes["saml.server.signature"],
    saml_assertion_signature:.attributes["saml.assertion.signature"],
    saml_authnstatement:.attributes["saml.authnstatement"],
    saml_force_post_binding:.attributes["saml_force_post_binding"],
    saml_client_signature:.attributes["saml.client.signature"]
  }}]' "${clients_json}"
}

load_mappers() {
  curl_admin "${issuer}/admin/realms/platform/clients/$1/protocol-mappers/models" >"${mappers_json}"
}

mappers_match() {
  jq -e '
    def count($name; $mapper; $config):
      [.[] | select(.name == $name and .protocol == "saml" and .protocolMapper == $mapper and .config == $config)] | length;
    count("grafana-role"; "saml-group-membership-mapper"; {"attribute.name":"role", "attribute.nameformat":"Basic", "full.path":"false", "single":"false"}) == 1 and
    count("grafana-email"; "saml-user-property-mapper"; {"attribute.name":"email", "attribute.nameformat":"Basic", "user.attribute":"email"}) == 1 and
    count("grafana-login"; "saml-user-property-mapper"; {"attribute.name":"login", "attribute.nameformat":"Basic", "user.attribute":"username"}) == 1 and
    count("grafana-name"; "saml-user-property-mapper"; {"attribute.name":"name", "attribute.nameformat":"Basic", "user.attribute":"username"}) == 1
  ' "${mappers_json}" >/dev/null
}

known_mappers_are_correct() {
  jq -e '
    all(.[];
      if .name == "grafana-role" then .protocol == "saml" and .protocolMapper == "saml-group-membership-mapper" and .config == {"attribute.name":"role", "attribute.nameformat":"Basic", "full.path":"false", "single":"false"}
      elif .name == "grafana-email" then .protocol == "saml" and .protocolMapper == "saml-user-property-mapper" and .config == {"attribute.name":"email", "attribute.nameformat":"Basic", "user.attribute":"email"}
      elif .name == "grafana-login" then .protocol == "saml" and .protocolMapper == "saml-user-property-mapper" and .config == {"attribute.name":"login", "attribute.nameformat":"Basic", "user.attribute":"username"}
      elif .name == "grafana-name" then .protocol == "saml" and .protocolMapper == "saml-user-property-mapper" and .config == {"attribute.name":"name", "attribute.nameformat":"Basic", "user.attribute":"username"}
      else true end
    ) and ([.[] | select(.name == "grafana-role" or .name == "grafana-email" or .name == "grafana-login" or .name == "grafana-name") | .name] | unique | length) == ([.[] | select(.name == "grafana-role" or .name == "grafana-email" or .name == "grafana-login" or .name == "grafana-name")] | length)
  ' "${mappers_json}" >/dev/null
}

load_group() {
  curl_admin --get --data-urlencode "search=${editor_group_name}" \
    --data-urlencode 'exact=true' --data-urlencode 'briefRepresentation=false' \
    "${issuer}/admin/realms/platform/groups" \
    | jq --arg name "${editor_group_name}" '[.[] | select(.name == $name and .path == ("/" + $name))]' >"${groups_json}"
}

group_is_empty() {
  curl_admin --get --data-urlencode 'max=1' \
    "${issuer}/admin/realms/platform/groups/$1/members" >"${members_json}"
  [[ $(jq length "${members_json}") -eq 0 ]]
}

load_client
client_count=$(jq length "${clients_json}")
case ${client_count} in
  0) echo 'AWS-SEC-02 Keycloak diff: Grafana SAML client -> create' ;;
  1) client_matches || { safe_client_summary; echo 'Grafana SAML client 선언이 다르다. 자동 보정하지 않는다.' >&2; exit 1; } ;;
  *) echo "Grafana SAML client live 객체가 ${client_count}건이다. 변경하지 않는다." >&2; exit 1 ;;
esac

load_group
group_count=$(jq length "${groups_json}")
case ${group_count} in
  0) echo 'AWS-SEC-02 Keycloak diff: /grafana-amg-editors (empty) -> create' ;;
  1) group_is_empty "$(jq -r '.[0].id' "${groups_json}")" || {
    echo '/grafana-amg-editors에 사용자가 있어 Editor 권한을 넓히지 않는다.' >&2; exit 1
  } ;;
  *) echo "/grafana-amg-editors live 객체가 ${group_count}건이다. 변경하지 않는다." >&2; exit 1 ;;
esac

if [[ ${client_count} -eq 1 ]]; then
  internal_id=$(jq -r '.[0].id' "${clients_json}")
  load_mappers "${internal_id}"
  known_mappers_are_correct || { echo 'Grafana SAML assertion mapper 선언이 다르다. 자동 보정하지 않는다.' >&2; exit 1; }
fi

if [[ ${mode} == --check ]]; then
  [[ ${client_count} -eq 1 && ${group_count} -eq 1 ]] || { echo 'AWS-SEC-02 Keycloak 선언이 아직 적용되지 않았다.' >&2; exit 1; }
  mappers_match || { echo 'Grafana SAML assertion mapper가 완전하지 않다.' >&2; exit 1; }
  echo 'AWS-SEC-02 Keycloak=PASS client=grafana-saml assertion=role,email,login,name editor-group-empty=true user-change=0'
  exit 0
fi

if [[ ${group_count} -eq 0 ]]; then
  jq -n --arg name "${editor_group_name}" '{name:$name}' >"${payload_json}"
  post_json "${issuer}/admin/realms/platform/groups"
fi
if [[ ${client_count} -eq 0 ]]; then
  jq -n --arg entity "${entity_id}" --arg acs "${acs_url}" --arg origin "${browser_origin}" '{
    clientId:$entity, enabled:true, protocol:"saml", redirectUris:[$acs, ($origin + "/*")],
    attributes:{saml_assertion_consumer_url_post:$acs, saml_name_id_format:"email", saml_force_name_id_format:"true", "saml.server.signature":"true", "saml.assertion.signature":"true", "saml.authnstatement":"true", saml_force_post_binding:"true", "saml.client.signature":"false"}
  }' >"${payload_json}"
  post_json "${issuer}/admin/realms/platform/clients"
fi

load_client
client_matches || { echo '생성 후 Grafana SAML client 선언 검증에 실패했다.' >&2; exit 1; }
internal_id=$(jq -r '.[0].id' "${clients_json}")
load_mappers "${internal_id}"
for mapper in grafana-role grafana-email grafana-login grafana-name; do
  count=$(jq --arg mapper "${mapper}" '[.[] | select(.name == $mapper)] | length' "${mappers_json}")
  case ${count} in
    0)
      case ${mapper} in
        grafana-role) jq -n '{name:"grafana-role", protocol:"saml", protocolMapper:"saml-group-membership-mapper", config:{"attribute.name":"role", "attribute.nameformat":"Basic", "full.path":"false", "single":"false"}}' >"${payload_json}" ;;
        grafana-email) jq -n '{name:"grafana-email", protocol:"saml", protocolMapper:"saml-user-property-mapper", config:{"attribute.name":"email", "attribute.nameformat":"Basic", "user.attribute":"email"}}' >"${payload_json}" ;;
        grafana-login) jq -n '{name:"grafana-login", protocol:"saml", protocolMapper:"saml-user-property-mapper", config:{"attribute.name":"login", "attribute.nameformat":"Basic", "user.attribute":"username"}}' >"${payload_json}" ;;
        grafana-name) jq -n '{name:"grafana-name", protocol:"saml", protocolMapper:"saml-user-property-mapper", config:{"attribute.name":"name", "attribute.nameformat":"Basic", "user.attribute":"username"}}' >"${payload_json}" ;;
      esac
      post_json "${issuer}/admin/realms/platform/clients/${internal_id}/protocol-mappers/models"
      ;;
    1) ;;
    *) echo "${mapper} mapper가 ${count}건이다. 변경하지 않는다." >&2; exit 1 ;;
  esac
done

load_group
[[ $(jq length "${groups_json}") -eq 1 ]] || { echo '/grafana-amg-editors 생성 후 검증에 실패했다.' >&2; exit 1; }
group_is_empty "$(jq -r '.[0].id' "${groups_json}")" || { echo '/grafana-amg-editors가 비어 있지 않다.' >&2; exit 1; }
load_mappers "${internal_id}"
mappers_match || { echo '생성 후 Grafana SAML mapper 선언 검증에 실패했다.' >&2; exit 1; }
echo 'AWS-SEC-02 Keycloak=PASS client=grafana-saml assertion=role,email,login,name editor-group-empty=true user-change=0'
