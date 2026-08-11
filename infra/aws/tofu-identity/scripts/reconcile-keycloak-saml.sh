#!/usr/bin/env bash
# AWS-ID-01 전용 Keycloak SAML client의 생성·검증·폐기를 소유한다.
# 기존 realm import를 다시 실행하지 않고, 새 client와 그 client role 관계만 다룬다.
set -Eeuo pipefail

readonly issuer=https://sso.imcherry5778.xyz
readonly realm=platform
readonly client_id='https://signin.aws.amazon.com/saml'
readonly legacy_client_id='urn:amazon:webservices'
readonly client_alias=aws-console
readonly console_acs=https://ap-northeast-2.signin.aws.amazon.com/saml
readonly console_audience=https://signin.aws.amazon.com/saml
readonly session_duration=900
readonly script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly repo_root=$(cd -- "${script_dir}/../../../.." && pwd)
readonly browser_login="${repo_root}/gitops/tools/kc-01/browser-login.py"

: "${KC01_SECRET_DIR:?저장소 밖 KC-01 비밀 디렉터리가 필요하다}"
: "${AWS_ID01_SAML_PROVIDER_ARN:?IAM SAML provider ARN이 필요하다}"
: "${AWS_ID01_OBSERVER_ROLE_ARN:?observer role ARN이 필요하다}"
: "${AWS_ID01_IDENTITY_READER_ROLE_ARN:?identity-reader role ARN이 필요하다}"

mode=${1:---check}
if [[ "${mode}" != --check && "${mode}" != --apply && "${mode}" != --repair && "${mode}" != --rollback && "${mode}" != --rollback-legacy ]]; then
  echo "사용법: $0 [--check|--apply|--repair|--rollback|--rollback-legacy]" >&2
  exit 64
fi

for required in local-admin-password local-admin-totp; do
  [[ -s "${KC01_SECRET_DIR}/${required}" ]] || {
    echo "필수 외부 비밀 파일이 없다: ${required}" >&2
    exit 1
  }
done

if [[ ! -x "${browser_login}" ]]; then
  echo "KC-01 browser-login 도구를 찾을 수 없다: ${browser_login}" >&2
  exit 1
fi

provider_name=${AWS_ID01_SAML_PROVIDER_ARN##*/}
observer_name=${AWS_ID01_OBSERVER_ROLE_ARN##*/}
identity_reader_name=${AWS_ID01_IDENTITY_READER_ROLE_ARN##*/}
provider_account=${AWS_ID01_SAML_PROVIDER_ARN#arn:aws:iam::}
provider_account=${provider_account%%:*}
observer_account=${AWS_ID01_OBSERVER_ROLE_ARN#arn:aws:iam::}
observer_account=${observer_account%%:*}
identity_reader_account=${AWS_ID01_IDENTITY_READER_ROLE_ARN#arn:aws:iam::}
identity_reader_account=${identity_reader_account%%:*}
if [[ "${AWS_ID01_SAML_PROVIDER_ARN}" != arn:aws:iam::????????????:saml-provider/keycloak-platform ]] \
  || [[ "${provider_name}" != keycloak-platform ]] \
  || [[ "${AWS_ID01_OBSERVER_ROLE_ARN}" != arn:aws:iam::????????????:role/platform-saml-observer ]] \
  || [[ "${AWS_ID01_IDENTITY_READER_ROLE_ARN}" != arn:aws:iam::????????????:role/platform-saml-identity-reader ]] \
  || [[ "${observer_name}" != platform-saml-observer ]] \
  || [[ "${identity_reader_name}" != platform-saml-identity-reader ]]; then
  echo "AWS-ID-01 대상 ARN 형식 또는 고정 이름이 기대와 다르다. 적용하지 않는다." >&2
  exit 1
fi

if [[ "${AWS_ID01_SAML_PROVIDER_ARN#arn:aws:iam::????????????:}" == "${AWS_ID01_SAML_PROVIDER_ARN}" ]] \
  || [[ "${AWS_ID01_OBSERVER_ROLE_ARN#arn:aws:iam::????????????:}" == "${AWS_ID01_OBSERVER_ROLE_ARN}" ]] \
  || [[ "${AWS_ID01_IDENTITY_READER_ROLE_ARN#arn:aws:iam::????????????:}" == "${AWS_ID01_IDENTITY_READER_ROLE_ARN}" ]]; then
  echo "AWS ARN의 계정 부분 형식이 올바르지 않다. 적용하지 않는다." >&2
  exit 1
fi
if [[ "${provider_account}" != "${observer_account}" || "${provider_account}" != "${identity_reader_account}" ]]; then
  echo "SAML provider와 두 role의 AWS 계정이 다르다. 적용하지 않는다." >&2
  exit 1
fi

readonly observer_role=aws-console-observer
readonly identity_reader_role=aws-console-identity-reader
readonly observer_pair="${AWS_ID01_OBSERVER_ROLE_ARN},${AWS_ID01_SAML_PROVIDER_ARN}"
readonly identity_reader_pair="${AWS_ID01_IDENTITY_READER_ROLE_ARN},${AWS_ID01_SAML_PROVIDER_ARN}"
readonly temp_dir=$(mktemp -d)
readonly header_file=${temp_dir}/admin.header
readonly connect_ip=${KC01_CONNECT_IP:-}

cleanup() {
  rm -rf -- "${temp_dir}"
}
trap cleanup EXIT

browser_args=(
  --issuer "${issuer}"
  --realm master
  --client-id kc-recovery
  --redirect-uri "${issuer}/realms/master/account/"
  --username imcherry-kc-recovery
  --password-file "${KC01_SECRET_DIR}/local-admin-password"
  --totp-file "${KC01_SECRET_DIR}/local-admin-totp"
  --header-file "${header_file}"
  --expect-realm-role admin
)
if [[ -n "${connect_ip}" ]]; then
  browser_args+=(--connect-ip "${connect_ip}")
fi
python3 "${browser_login}" "${browser_args[@]}" >/dev/null

api() {
  local method=$1
  local path=$2
  local body_file=${3:-}
  local args=(--silent --show-error --fail --request "${method}" --header "@${header_file}")
  if [[ -n "${body_file}" ]]; then
    args+=(--header 'Content-Type: application/json' --data-binary "@${body_file}")
  fi
  curl "${args[@]}" "${issuer}/admin/realms/${realm}/${path}"
}

client_matches() {
  api GET "clients?clientId=${client_id}&exact=true" | jq -e '
    length == 1
    and .[0].clientId == "https://signin.aws.amazon.com/saml"
    and .[0].protocol == "saml"
  ' >/dev/null
}

client_uuid() {
  api GET "clients?clientId=${client_id}&exact=true" | jq -er 'if length == 1 then .[0].id else empty end'
}

legacy_client_uuid() {
  api GET "clients?clientId=${legacy_client_id}&exact=true" | jq -er 'if length == 1 then .[0].id else empty end'
}

group_uuid() {
  local expected_name=$1
  api GET "groups?search=${expected_name}&exact=true&briefRepresentation=true" \
    | jq -er --arg name "${expected_name}" '[.[] | select(.name == $name)] | if length == 1 then .[0].id else empty end'
}

write_json() {
  local destination=$1
  shift
  jq -n "$@" >"${destination}"
}

detach_inherited_role_list_scope() {
  local cid=$1
  local scope_id
  while IFS= read -r scope_id; do
    [[ -n "${scope_id}" ]] || continue
    if api GET "client-scopes/${scope_id}/protocol-mappers/models" \
      | jq -e '[.[] | select(.protocol == "saml" and .protocolMapper == "saml-role-list-mapper")] | length > 0' >/dev/null; then
      # realm의 공용 scope를 수정하지 않고 이 AWS-ID-01 client에서의 연결만 분리한다.
      api DELETE "clients/${cid}/default-client-scopes/${scope_id}" >/dev/null
    fi
  done < <(api GET "clients/${cid}/default-client-scopes" | jq -r '.[].id')
}

verify_client() {
  local cid
  cid=$(client_uuid) || {
    echo "AWS-ID-01 Keycloak SAML client가 정확히 하나가 아니다." >&2
    return 1
  }

  api GET "clients/${cid}" | jq -e --arg acs "${console_acs}" '
    .clientId == "https://signin.aws.amazon.com/saml"
    and .protocol == "saml"
    and .enabled == true
    and .fullScopeAllowed == false
    and .baseUrl == $acs
    and (.redirectUris | index($acs) != null)
    and .attributes["saml_idp_initiated_sso_url_name"] == "aws-console"
    and .attributes["saml.assertion.signature"] == "true"
    and .attributes["saml.server.signature"] == "true"
    and .attributes["saml.force.post.binding"] == "true"
    and .attributes["saml.assertion.audience.restriction"] == "true"
    and .attributes["saml_assertion_consumer_url_post"] == $acs
  ' >/dev/null

  local roles_json=${temp_dir}/roles.json
  api GET "clients/${cid}/roles" >"${roles_json}"
  jq -e --arg observer "${observer_role}" --arg identity "${identity_reader_role}" '
    ([.[].name] | index($observer) != null) and ([.[].name] | index($identity) != null)
  ' "${roles_json}" >/dev/null

  local observer_group identity_group
  # AWS-ID-02부터 일반 platform group은 다른 서비스의 admission만 소유하고,
  # AWS client role은 전용 group으로만 매핑한다.
  observer_group=$(group_uuid aws-console-inventory-readers)
  identity_group=$(group_uuid aws-console-identity-readers)
  api GET "groups/${observer_group}/role-mappings/clients/${cid}" \
    | jq -e --arg role "${observer_role}" '[.[].name] | index($role) != null' >/dev/null
  api GET "groups/${identity_group}/role-mappings/clients/${cid}" \
    | jq -e --arg role "${identity_reader_role}" '[.[].name] | index($role) != null' >/dev/null

  api GET "clients/${cid}/scope-mappings/clients/${cid}" \
    | jq -e --arg observer "${observer_role}" --arg identity "${identity_reader_role}" '
      ([.[].name] | index($observer) != null) and ([.[].name] | index($identity) != null)
    ' >/dev/null

  api GET "clients/${cid}/protocol-mappers/models" \
    | jq -e \
      --arg observer_pair "${observer_pair}" \
      --arg identity_pair "${identity_reader_pair}" \
      --arg audience "${console_audience}" \
      --arg client_id "${client_id}" \
      '
      def mapper($name): [.[] | select(.name == $name)] | if length == 1 then .[0] else empty end;
      (mapper("aws-role-list") | .protocolMapper == "saml-role-list-mapper"
        and .config["attribute.name"] == "https://aws.amazon.com/SAML/Attributes/Role"
        and .config["attribute.nameformat"] == "URI Reference" and .config.single == "true")
      and (mapper("aws-observer-role-name") | .protocolMapper == "saml-role-name-mapper"
        and .config.role == ($client_id + ".aws-console-observer") and .config["new.role.name"] == $observer_pair)
      and (mapper("aws-identity-reader-role-name") | .protocolMapper == "saml-role-name-mapper"
        and .config.role == ($client_id + ".aws-console-identity-reader") and .config["new.role.name"] == $identity_pair)
      and (mapper("aws-role-session-name") | .protocolMapper == "saml-user-property-mapper"
        and .config["user.attribute"] == "username"
        and .config["attribute.name"] == "https://aws.amazon.com/SAML/Attributes/RoleSessionName")
      and (mapper("aws-session-duration") | .protocolMapper == "saml-hardcode-attribute-mapper"
        and .config["attribute.name"] == "https://aws.amazon.com/SAML/Attributes/SessionDuration"
        and .config["attribute.value"] == "900")
      and (mapper("aws-console-audience") | .protocolMapper == "saml-audience-mapper"
        and .config["included.custom.audience"] == $audience)
      ' >/dev/null
}

if [[ "${mode}" == --check ]]; then
  client_matches
  verify_client
  echo "AWS-ID-01 Keycloak SAML client/role/mapper/group 관계 검증 통과"
  exit 0
fi

if [[ "${mode}" == --rollback ]]; then
  client_matches || {
    echo "AWS-ID-01 소유 SAML client가 없거나 충돌한다. 삭제하지 않는다." >&2
    exit 1
  }
  cid=$(client_uuid)
  description=$(api GET "clients/${cid}" | jq -r '.description // empty')
  [[ "${description}" == "AWS-ID-01 전용; group-to-client-role SAML temporary console access" ]] || {
    echo "AWS-ID-01 소유 표식이 없는 client다. 삭제하지 않는다." >&2
    exit 1
  }
  api DELETE "clients/${cid}" >/dev/null
  echo "AWS-ID-01 Keycloak 전용 SAML client와 그 client role 관계를 제거했다"
  exit 0
fi

if [[ "${mode}" == --rollback-legacy ]]; then
  cid=$(legacy_client_uuid) || {
    echo "legacy AWS-ID-01 SAML client가 정확히 하나가 아니다. 삭제하지 않는다." >&2
    exit 1
  }
  description=$(api GET "clients/${cid}" | jq -r '.description // empty')
  [[ "${description}" == "AWS-ID-01 전용; group-to-client-role SAML temporary console access" ]] || {
    echo "AWS-ID-01 소유 표식이 없는 legacy client다. 삭제하지 않는다." >&2
    exit 1
  }
  api DELETE "clients/${cid}" >/dev/null
  echo "AWS-ID-01 legacy SAML client와 그 client role 관계를 제거했다"
  exit 0
fi

if [[ "${mode}" == --repair ]]; then
  client_matches || {
    echo "AWS-ID-01 소유 SAML client가 없거나 충돌한다. 보정하지 않는다." >&2
    exit 1
  }
  cid=$(client_uuid)
  client_json=${temp_dir}/client-repair.json
  api GET "clients/${cid}" >"${client_json}"
  description=$(jq -r '.description // empty' "${client_json}")
  [[ "${description}" == "AWS-ID-01 전용; group-to-client-role SAML temporary console access" ]] || {
    echo "AWS-ID-01 소유 표식이 없는 client다. 보정하지 않는다." >&2
    exit 1
  }
  jq --arg acs "${console_acs}" \
    '.baseUrl = $acs | .attributes["saml_assertion_consumer_url_post"] = $acs' \
    "${client_json}" >"${client_json}.next"
  api PUT "clients/${cid}" "${client_json}.next" >/dev/null
  detach_inherited_role_list_scope "${cid}"
  verify_client
  echo "AWS-ID-01 Keycloak SAML client의 IdP-initiated 기본 redirect를 보정했다"
  exit 0
fi

# apply는 먼저 현재 객체 충돌과 두 대상 그룹을 확인한다. 기존 OIDC client나 기존
# group 속성·사용자 membership은 수정하지 않으며, 아래에서 새 client role 관계만 추가한다.
if api GET "clients?clientId=${client_id}&exact=true" | jq -e 'length == 0' >/dev/null; then
  :
else
  echo "동일 clientId가 이미 존재한다. 기존 객체를 덮어쓰지 않는다." >&2
  exit 1
fi
platform_users_group=$(group_uuid platform-users) || {
  echo "/platform-users 그룹을 정확히 하나 찾지 못했다. 적용하지 않는다." >&2
  exit 1
}
platform_privileged_group=$(group_uuid platform-privileged) || {
  echo "/platform-privileged 그룹을 정확히 하나 찾지 못했다. 적용하지 않는다." >&2
  exit 1
}

client_json=${temp_dir}/client.json
write_json "${client_json}" \
  --arg client_id "${client_id}" \
  --arg acs "${console_acs}" \
  --arg alias "${client_alias}" \
  '{
    clientId: $client_id,
    name: "AWS Console SAML temporary access",
    description: "AWS-ID-01 전용; group-to-client-role SAML temporary console access",
    enabled: true,
    protocol: "saml",
    publicClient: false,
    standardFlowEnabled: true,
    implicitFlowEnabled: false,
    directAccessGrantsEnabled: false,
    serviceAccountsEnabled: false,
    fullScopeAllowed: false,
    baseUrl: $acs,
    redirectUris: [$acs],
    attributes: {
      "saml.assertion.signature": "true",
      "saml.server.signature": "true",
      "saml.server.signature.keyinfo.ext": "false",
      "saml.signature.algorithm": "RSA_SHA256",
      "saml.client.signature": "false",
      "saml.encrypt": "false",
      "saml.force.post.binding": "true",
      "saml_assertion_consumer_url_post": $acs,
      "saml.assertion.audience.restriction": "true",
      "saml.authnstatement": "true",
      "saml_idp_initiated_sso_url_name": $alias
    }
  }'
api POST clients "${client_json}" >/dev/null

cid=$(client_uuid)
for role_name in "${observer_role}" "${identity_reader_role}"; do
  role_json=${temp_dir}/${role_name}.json
  write_json "${role_json}" --arg name "${role_name}" '{name: $name, description: "AWS-ID-01 SAML client role"}'
  api POST "clients/${cid}/roles" "${role_json}" >/dev/null
done

observer_representation=${temp_dir}/observer-role.json
identity_representation=${temp_dir}/identity-role.json
api GET "clients/${cid}/roles/${observer_role}" >"${observer_representation}"
api GET "clients/${cid}/roles/${identity_reader_role}" >"${identity_representation}"
observer_mapping=${temp_dir}/observer-mapping.json
identity_mapping=${temp_dir}/identity-mapping.json
jq -s '.' "${observer_representation}" >"${observer_mapping}"
jq -s '.' "${identity_representation}" >"${identity_mapping}"
api POST "groups/${platform_users_group}/role-mappings/clients/${cid}" "${observer_mapping}" >/dev/null
api POST "groups/${platform_privileged_group}/role-mappings/clients/${cid}" "${identity_mapping}" >/dev/null

scope_roles=${temp_dir}/scope-roles.json
jq -s '.' "${observer_representation}" "${identity_representation}" >"${scope_roles}"
api POST "clients/${cid}/scope-mappings/clients/${cid}" "${scope_roles}" >/dev/null

declare -a mapper_specs=(
  aws-role-list
  aws-observer-role-name
  aws-identity-reader-role-name
  aws-role-session-name
  aws-session-duration
  aws-console-audience
)
for mapper_name in "${mapper_specs[@]}"; do
  mapper_json=${temp_dir}/${mapper_name}.json
  case "${mapper_name}" in
    aws-role-list)
      write_json "${mapper_json}" '{name:"aws-role-list",protocol:"saml",protocolMapper:"saml-role-list-mapper",consentRequired:false,config:{"attribute.name":"https://aws.amazon.com/SAML/Attributes/Role","attribute.nameformat":"URI Reference",single:"true"}}'
      ;;
    aws-observer-role-name)
      write_json "${mapper_json}" --arg pair "${observer_pair}" --arg client_id "${client_id}" '{name:"aws-observer-role-name",protocol:"saml",protocolMapper:"saml-role-name-mapper",consentRequired:false,config:{role:($client_id + ".aws-console-observer"),"new.role.name":$pair}}'
      ;;
    aws-identity-reader-role-name)
      write_json "${mapper_json}" --arg pair "${identity_reader_pair}" --arg client_id "${client_id}" '{name:"aws-identity-reader-role-name",protocol:"saml",protocolMapper:"saml-role-name-mapper",consentRequired:false,config:{role:($client_id + ".aws-console-identity-reader"),"new.role.name":$pair}}'
      ;;
    aws-role-session-name)
      write_json "${mapper_json}" '{name:"aws-role-session-name",protocol:"saml",protocolMapper:"saml-user-property-mapper",consentRequired:false,config:{"user.attribute":"username","attribute.name":"https://aws.amazon.com/SAML/Attributes/RoleSessionName","attribute.nameformat":"URI Reference"}}'
      ;;
    aws-session-duration)
      write_json "${mapper_json}" '{name:"aws-session-duration",protocol:"saml",protocolMapper:"saml-hardcode-attribute-mapper",consentRequired:false,config:{"attribute.name":"https://aws.amazon.com/SAML/Attributes/SessionDuration","attribute.nameformat":"URI Reference","attribute.value":"900"}}'
      ;;
    aws-console-audience)
      write_json "${mapper_json}" --arg audience "${console_audience}" '{name:"aws-console-audience",protocol:"saml",protocolMapper:"saml-audience-mapper",consentRequired:false,config:{"included.custom.audience":$audience}}'
      ;;
  esac
  api POST "clients/${cid}/protocol-mappers/models" "${mapper_json}" >/dev/null
done

detach_inherited_role_list_scope "${cid}"

verify_client
echo "AWS-ID-01 Keycloak SAML client/role/mapper/group 관계 생성 및 검증 통과"
