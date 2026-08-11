#!/usr/bin/env bash
# AWS-ID-02: 기존 AWS SAML client를 서비스 전용 읽기 group으로 무중단 이관한다.
set -Eeuo pipefail

readonly issuer=https://sso.imcherry5778.xyz
readonly realm=platform
readonly client_id='https://signin.aws.amazon.com/saml'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly script_dir
repo_root=$(cd -- "${script_dir}/../../../.." && pwd)
readonly repo_root
readonly browser_login="${repo_root}/gitops/tools/kc-01/browser-login.py"

mode=${1:---check}
[[ ${mode} == --check || ${mode} == --apply || ${mode} == --rollback ]] || {
  echo "사용법: $0 [--check|--apply|--rollback]" >&2
  exit 64
}

: "${KC01_SECRET_DIR:?저장소 밖 KC-01 비밀 디렉터리가 필요하다}"
: "${AWS_ID01_SAML_PROVIDER_ARN:?IAM SAML provider ARN이 필요하다}"
: "${AWS_ID01_OBSERVER_ROLE_ARN:?inventory reader role ARN이 필요하다}"
: "${AWS_ID01_IDENTITY_READER_ROLE_ARN:?identity reader role ARN이 필요하다}"
: "${AWS_ID02_OBSERVABILITY_READER_ROLE_ARN:?observability reader role ARN이 필요하다}"
: "${AWS_ID02_SECURITY_READER_ROLE_ARN:?security reader role ARN이 필요하다}"

readonly provider_arn=${AWS_ID01_SAML_PROVIDER_ARN}
readonly inventory_arn=${AWS_ID01_OBSERVER_ROLE_ARN}
readonly observability_arn=${AWS_ID02_OBSERVABILITY_READER_ROLE_ARN}
readonly security_arn=${AWS_ID02_SECURITY_READER_ROLE_ARN}
readonly identity_arn=${AWS_ID01_IDENTITY_READER_ROLE_ARN}

readonly inventory_group=aws-console-inventory-readers
readonly observability_group=aws-console-observability-readers
readonly security_group=aws-console-security-readers
readonly identity_group=aws-console-identity-readers
readonly legacy_inventory_group=platform-users
readonly legacy_identity_group=platform-privileged

readonly inventory_role=aws-console-observer
readonly observability_role=aws-console-observability-reader
readonly security_role=aws-console-security-reader
readonly identity_role=aws-console-identity-reader

for input in local-admin-password local-admin-totp; do
  input_path=${KC01_SECRET_DIR}/${input}
  [[ -f ${input_path} && ! -L ${input_path} && $(stat -c %a "${input_path}") == 600 ]] || {
    echo "AWS-ID-02 Keycloak 복구 입력이 mode 0600 regular file이 아니다: ${input}" >&2
    exit 1
  }
done
[[ -x ${browser_login} ]] || {
  echo 'AWS-ID-02 Keycloak browser-login 도구가 없다.' >&2
  exit 1
}

validate_arn() {
  local arn=$1 expected_name=$2
  [[ ${arn} =~ ^arn:aws:iam::[0-9]{12}:role/${expected_name}$ ]] || {
    echo 'AWS-ID-02 대상 role ARN 형식 또는 고정 이름이 다르다.' >&2
    exit 1
  }
}

[[ ${provider_arn} =~ ^arn:aws:iam::[0-9]{12}:saml-provider/keycloak-platform$ ]] || {
  echo 'AWS-ID-02 SAML provider ARN 형식 또는 이름이 다르다.' >&2
  exit 1
}
account_id=${provider_arn#arn:aws:iam::}
account_id=${account_id%%:*}
readonly account_id
for spec in \
  "${inventory_arn}|platform-saml-observer" \
  "${observability_arn}|platform-saml-observability-reader" \
  "${security_arn}|platform-saml-security-reader" \
  "${identity_arn}|platform-saml-identity-reader"; do
  role_arn=${spec%%|*}
  role_name=${spec#*|}
  validate_arn "${role_arn}" "${role_name}"
  role_account=${role_arn#arn:aws:iam::}
  role_account=${role_account%%:*}
  [[ ${role_account} == "${account_id}" ]] || {
    echo 'AWS-ID-02 provider와 role의 AWS 계정이 다르다.' >&2
    exit 1
  }
done

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
readonly header_file=${temp_dir}/keycloak-admin.header
cleanup() {
  find "${temp_dir}" -type f -delete
  rmdir "${temp_dir}"
}
trap cleanup EXIT INT TERM

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
if [[ -n ${KC01_CONNECT_IP:-} ]]; then
  browser_args+=(--connect-ip "${KC01_CONNECT_IP}")
fi
python3 "${browser_login}" "${browser_args[@]}" >/dev/null

api() {
  local method=$1 path=$2 body_file=${3:-}
  local args=(--silent --show-error --fail --request "${method}" --header "@${header_file}")
  [[ -n ${body_file} ]] && args+=(--header 'Content-Type: application/json' --data-binary "@${body_file}")
  curl "${args[@]}" "${issuer}/admin/realms/${realm}/${path}"
}

write_json() {
  local destination=$1
  shift
  jq -n "$@" >"${destination}"
}

client_uuid() {
  api GET "clients?clientId=${client_id}&exact=true" \
    | jq -er 'if length == 1 and .[0].clientId == "https://signin.aws.amazon.com/saml" and .[0].protocol == "saml" then .[0].id else empty end'
}

top_level_group_matches() {
  local name=$1
  api GET "groups?search=${name}&exact=true&briefRepresentation=false" \
    | jq -ce --arg name "${name}" '
        [.[] | select(.name == $name and .path == ("/" + $name))]
      '
}

top_level_group_uuid() {
  local name=$1 matches
  matches=$(top_level_group_matches "${name}")
  jq -er '
    if length == 1 then .[0].id
    elif length == 0 then error("missing")
    else error("duplicate")
    end
  ' <<<"${matches}"
}

ensure_group() {
  local name group_id group_json matches count
  name=$1
  group_json=${temp_dir}/group-${name}.json
  matches=$(top_level_group_matches "${name}")
  count=$(jq 'length' <<<"${matches}")
  case ${count} in
    1)
      group_id=$(jq -er '.[0].id' <<<"${matches}")
      ;;
    0)
    [[ ${mode} == --apply ]] || {
      echo "AWS-ID-02 check: /${name} group 생성 필요" >&2
      return 1
    }
    write_json "${group_json}" --arg name "${name}" '{name: $name}'
    api POST groups "${group_json}" >/dev/null
    group_id=$(top_level_group_uuid "${name}")
      ;;
    *)
      echo "AWS-ID-02 /${name} group이 중복되어 변경하지 않는다." >&2
      return 1
      ;;
  esac
  printf '%s\n' "${group_id}"
}

client_role_representation() {
  local cid=$1 name=$2
  api GET "clients/${cid}/roles" \
    | jq -er --arg name "${name}" '[.[] | select(.name == $name)] | if length == 1 then .[0] else empty end'
}

ensure_client_role() {
  local cid name role_file
  cid=$1
  name=$2
  role_file=${temp_dir}/role-${name}.json
  if ! client_role_representation "${cid}" "${name}" >"${role_file}"; then
    [[ ${mode} == --apply ]] || {
      echo "AWS-ID-02 check: ${name} client role 생성 필요" >&2
      return 1
    }
    write_json "${role_file}" --arg name "${name}" '{name: $name, description: "AWS-ID-02 SAML client role"}'
    api POST "clients/${cid}/roles" "${role_file}" >/dev/null
    client_role_representation "${cid}" "${name}" >"${role_file}"
  fi
  printf '%s\n' "${role_file}"
}

mapping_contains() {
  local group_id=$1 cid=$2 role_name=$3
  api GET "groups/${group_id}/role-mappings/clients/${cid}" \
    | jq -e --arg name "${role_name}" '[.[].name] | index($name) != null' >/dev/null
}

ensure_group_mapping() {
  local group_id cid role_name role_file mapping_file
  group_id=$1
  cid=$2
  role_name=$3
  role_file=$4
  mapping_file=${temp_dir}/mapping-${group_id}-${role_name}.json
  if ! mapping_contains "${group_id}" "${cid}" "${role_name}"; then
    [[ ${mode} == --apply ]] || {
      echo "AWS-ID-02 check: ${role_name} group mapping 필요" >&2
      return 1
    }
    jq -s '.' "${role_file}" >"${mapping_file}"
    api POST "groups/${group_id}/role-mappings/clients/${cid}" "${mapping_file}" >/dev/null
  fi
  mapping_contains "${group_id}" "${cid}" "${role_name}"
}

ensure_scope_mapping() {
  local cid role_name role_file mapping_file
  cid=$1
  role_name=$2
  role_file=$3
  mapping_file=${temp_dir}/scope-${role_name}.json
  if ! api GET "clients/${cid}/scope-mappings/clients/${cid}" \
    | jq -e --arg name "${role_name}" '[.[].name] | index($name) != null' >/dev/null; then
    [[ ${mode} == --apply ]] || {
      echo "AWS-ID-02 check: ${role_name} client scope mapping 필요" >&2
      return 1
    }
    jq -s '.' "${role_file}" >"${mapping_file}"
    api POST "clients/${cid}/scope-mappings/clients/${cid}" "${mapping_file}" >/dev/null
  fi
}

ensure_members_copied() {
  local legacy_id target_id legacy_file target_file
  legacy_id=$1
  target_id=$2
  legacy_file=${temp_dir}/legacy-members-${legacy_id}.json
  target_file=${temp_dir}/target-members-${target_id}.json
  api GET "groups/${legacy_id}/members?first=0&max=100" >"${legacy_file}"
  api GET "groups/${target_id}/members?first=0&max=100" >"${target_file}"
  while IFS= read -r user_id; do
    [[ -n ${user_id} ]] || continue
    if ! jq -e --arg id "${user_id}" '[.[].id] | index($id) != null' "${target_file}" >/dev/null; then
      [[ ${mode} == --apply ]] || {
        echo 'AWS-ID-02 check: 기존 SAML group membership 이관 필요' >&2
        return 1
      }
      api PUT "users/${user_id}/groups/${target_id}" >/dev/null
    fi
  done < <(jq -r '.[].id' "${legacy_file}")
  api GET "groups/${target_id}/members?first=0&max=100" >"${target_file}"
  jq -e --slurpfile legacy "${legacy_file}" '
    ([.[] | .id] | unique) as $target |
    ($legacy[0] | map(.id) | unique) as $legacy_ids |
    ($legacy_ids - $target | length) == 0
  ' "${target_file}" >/dev/null
}

ensure_group_empty() {
  local group_id group_name members_file
  group_id=$1
  group_name=$2
  members_file=${temp_dir}/members-${group_id}.json
  api GET "groups/${group_id}/members?first=0&max=1" >"${members_file}"
  jq -e 'length == 0' "${members_file}" >/dev/null || {
    echo "AWS-ID-02 /${group_name} membership은 역할 매트릭스 승인 전에는 비어 있어야 한다." >&2
    return 1
  }
}

remove_legacy_mapping() {
  local legacy_id cid role_name role_file mapping_file
  legacy_id=$1
  cid=$2
  role_name=$3
  role_file=$4
  mapping_file=${temp_dir}/legacy-remove-${legacy_id}-${role_name}.json
  if mapping_contains "${legacy_id}" "${cid}" "${role_name}"; then
    [[ ${mode} == --apply ]] || {
      echo 'AWS-ID-02 check: legacy SAML group mapping 제거 필요' >&2
      return 1
    }
    jq -s '.' "${role_file}" >"${mapping_file}"
    api DELETE "groups/${legacy_id}/role-mappings/clients/${cid}" "${mapping_file}" >/dev/null
  fi
  ! mapping_contains "${legacy_id}" "${cid}" "${role_name}"
}

ensure_role_mapper() {
  local cid mapper_name client_role role_pair mapper_file
  cid=$1
  mapper_name=$2
  client_role=$3
  role_pair=$4
  mapper_file=${temp_dir}/mapper-${mapper_name}.json
  if ! api GET "clients/${cid}/protocol-mappers/models" \
    | jq -e --arg name "${mapper_name}" --arg pair "${role_pair}" --arg role "${client_id}.${client_role}" '
        ([.[] | select(.name == $name)]) as $matches |
        ($matches | length == 1) and
        ($matches[0].protocol == "saml") and
        ($matches[0].protocolMapper == "saml-role-name-mapper") and
        ($matches[0].config.role == $role) and
        ($matches[0].config["new.role.name"] == $pair)
      ' >/dev/null; then
    [[ ${mode} == --apply ]] || {
      echo "AWS-ID-02 check: ${mapper_name} mapper 생성 또는 보정 필요" >&2
      return 1
    }
    existing_count=$(api GET "clients/${cid}/protocol-mappers/models" | jq --arg name "${mapper_name}" '[.[] | select(.name == $name)] | length')
    [[ ${existing_count} == 0 ]] || {
      echo "AWS-ID-02 ${mapper_name} mapper가 선언과 달라 자동 보정하지 않는다." >&2
      return 1
    }
    write_json "${mapper_file}" --arg name "${mapper_name}" --arg role "${client_id}.${client_role}" --arg pair "${role_pair}" \
      '{name:$name, protocol:"saml", protocolMapper:"saml-role-name-mapper", consentRequired:false, config:{role:$role, "new.role.name":$pair}}'
    api POST "clients/${cid}/protocol-mappers/models" "${mapper_file}" >/dev/null
  fi
}

rollback_mapping() {
  local legacy_id target_id cid role_name role_file mapping_file
  legacy_id=$1
  target_id=$2
  cid=$3
  role_name=$4
  role_file=$5
  mapping_file=${temp_dir}/rollback-${legacy_id}-${role_name}.json
  jq -s '.' "${role_file}" >"${mapping_file}"
  if ! mapping_contains "${legacy_id}" "${cid}" "${role_name}"; then
    api POST "groups/${legacy_id}/role-mappings/clients/${cid}" "${mapping_file}" >/dev/null
  fi
  if mapping_contains "${target_id}" "${cid}" "${role_name}"; then
    api DELETE "groups/${target_id}/role-mappings/clients/${cid}" "${mapping_file}" >/dev/null
  fi
}

cid=$(client_uuid) || {
  echo 'AWS-ID-02 기존 AWS SAML client가 정확히 하나가 아니다.' >&2
  exit 1
}
client_description=$(api GET "clients/${cid}" | jq -r '.description // empty')
[[ ${client_description} == 'AWS-ID-01 전용; group-to-client-role SAML temporary console access' ]] || {
  echo 'AWS-ID-02 소유 표식이 없는 SAML client다. 변경하지 않는다.' >&2
  exit 1
}

legacy_inventory_id=$(top_level_group_uuid "${legacy_inventory_group}")
legacy_identity_id=$(top_level_group_uuid "${legacy_identity_group}")
inventory_id=$(ensure_group "${inventory_group}")
observability_id=$(ensure_group "${observability_group}")
security_id=$(ensure_group "${security_group}")
identity_id=$(ensure_group "${identity_group}")

inventory_role_file=$(ensure_client_role "${cid}" "${inventory_role}")
observability_role_file=$(ensure_client_role "${cid}" "${observability_role}")
security_role_file=$(ensure_client_role "${cid}" "${security_role}")
identity_role_file=$(ensure_client_role "${cid}" "${identity_role}")

if [[ ${mode} == --rollback ]]; then
  rollback_mapping "${legacy_inventory_id}" "${inventory_id}" "${cid}" "${inventory_role}" "${inventory_role_file}"
  rollback_mapping "${legacy_identity_id}" "${identity_id}" "${cid}" "${identity_role}" "${identity_role_file}"
  echo 'AWS-ID-02 Keycloak legacy SAML group mapping을 복구했다; 새 group과 membership은 보존했다'
  exit 0
fi

ensure_members_copied "${legacy_inventory_id}" "${inventory_id}"
ensure_members_copied "${legacy_identity_id}" "${identity_id}"
ensure_group_empty "${observability_id}" "${observability_group}"
ensure_group_empty "${security_id}" "${security_group}"
ensure_group_mapping "${inventory_id}" "${cid}" "${inventory_role}" "${inventory_role_file}"
ensure_group_mapping "${observability_id}" "${cid}" "${observability_role}" "${observability_role_file}"
ensure_group_mapping "${security_id}" "${cid}" "${security_role}" "${security_role_file}"
ensure_group_mapping "${identity_id}" "${cid}" "${identity_role}" "${identity_role_file}"
ensure_scope_mapping "${cid}" "${inventory_role}" "${inventory_role_file}"
ensure_scope_mapping "${cid}" "${observability_role}" "${observability_role_file}"
ensure_scope_mapping "${cid}" "${security_role}" "${security_role_file}"
ensure_scope_mapping "${cid}" "${identity_role}" "${identity_role_file}"
ensure_role_mapper "${cid}" aws-observability-reader-role-name "${observability_role}" "${observability_arn},${provider_arn}"
ensure_role_mapper "${cid}" aws-security-reader-role-name "${security_role}" "${security_arn},${provider_arn}"
remove_legacy_mapping "${legacy_inventory_id}" "${cid}" "${inventory_role}" "${inventory_role_file}"
remove_legacy_mapping "${legacy_identity_id}" "${cid}" "${identity_role}" "${identity_role_file}"

echo 'AWS-ID-02 Keycloak=PASS groups=4 roles=4 special-members=0 legacy-mapping=0'
