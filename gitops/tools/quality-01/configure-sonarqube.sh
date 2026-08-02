#!/usr/bin/env bash
# 배포가 Ready인 SonarQube의 로컬 admin, SAML, 고정 quality gate와 검증 project/token을 선언한다.
# shellcheck disable=SC2029
set -Eeuo pipefail

mode=${1:-}
if [[ "${mode}" != --check && "${mode}" != --apply ]]; then
  echo "사용법: SONAR_URL=http://127.0.0.1:19000 $0 --check|--apply" >&2
  exit 2
fi

readonly sonar_url=${SONAR_URL:-http://127.0.0.1:19000}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly env_file=${secret_root}/sonarqube/env
readonly vault_token_file=${secret_root}/vault-root.token
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
readonly issuer=https://sso.imcherry5778.xyz
readonly gate_name=QUALITY-01
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

[[ -f "${env_file}" && ! -L "${env_file}" && "$(stat -c %a "${env_file}")" == 600 ]] || {
  echo "QUALITY-01 env는 regular mode 0600이어야 한다: ${env_file}" >&2
  exit 1
}
[[ -f "${vault_token_file}" && ! -L "${vault_token_file}" && "$(stat -c %a "${vault_token_file}")" == 600 ]] || {
  echo "Vault root token 입력이 없거나 mode 0600이 아니다." >&2
  exit 1
}

SONARQUBE_ADMIN_PASSWORD=
while IFS='=' read -r key value; do
  case "${key}" in
    SONARQUBE_ADMIN_PASSWORD) SONARQUBE_ADMIN_PASSWORD=${value} ;;
    SONARQUBE_DB_PASSWORD|'') ;;
    *) echo "지원하지 않는 QUALITY-01 env key: ${key}" >&2; exit 1 ;;
  esac
done <"${env_file}"
readonly SONARQUBE_ADMIN_PASSWORD
[[ "${SONARQUBE_ADMIN_PASSWORD}" =~ ^Aa1\![A-Za-z0-9]{36}$ ]] || {
  echo "SONARQUBE_ADMIN_PASSWORD 형식이 제품 정책과 맞지 않는다." >&2
  exit 1
}

curl --silent --show-error --fail "${sonar_url}/api/system/status" | jq -e '.status == "UP"' >/dev/null

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  find "${temp_dir}" -type f -delete 2>/dev/null || true
  rmdir "${temp_dir}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM
readonly netrc_file=${temp_dir}/netrc
readonly descriptor_file=${temp_dir}/keycloak-saml.xml
readonly idp_cert_file=${temp_dir}/keycloak-idp.pem
readonly api_response=${temp_dir}/response.json

write_netrc() {
  local password=$1
  printf 'machine 127.0.0.1 login admin password %s\n' "${password}" >"${netrc_file}"
  chmod 0600 "${netrc_file}"
}
write_netrc "${SONARQUBE_ADMIN_PASSWORD}"

admin_valid=$(curl --silent --show-error --netrc-file "${netrc_file}" \
  "${sonar_url}/api/authentication/validate" | jq -r '.valid')
if [[ "${admin_valid}" != true ]]; then
  write_netrc admin
  default_valid=$(curl --silent --show-error --netrc-file "${netrc_file}" \
    "${sonar_url}/api/authentication/validate" | jq -r '.valid')
  [[ "${default_valid}" == true ]] || {
    echo "선언된 admin과 설치 기본 admin 인증이 모두 실패했다. 변경하지 않는다." >&2
    exit 1
  }
  if [[ "${mode}" == --check ]]; then
    echo "QUALITY-01 SonarQube: 기본 admin 암호 변경이 필요하다."
  else
    status=$(curl --silent --show-error --netrc-file "${netrc_file}" \
      --output "${api_response}" --write-out '%{http_code}' \
      --request POST \
      --data-urlencode login=admin \
      --data-urlencode password="${SONARQUBE_ADMIN_PASSWORD}" \
      --data-urlencode previousPassword=admin \
      "${sonar_url}/api/users/change_password")
    [[ "${status}" == 204 ]] || {
      echo "SonarQube admin 암호 변경 실패: HTTP ${status}" >&2
      exit 1
    }
    write_netrc "${SONARQUBE_ADMIN_PASSWORD}"
  fi
else
  echo "QUALITY-01 SonarQube local admin: match"
fi

curl --silent --show-error --fail \
  --resolve "sso.imcherry5778.xyz:443:${connect_ip}" \
  "${issuer}/realms/platform/protocol/saml/descriptor" >"${descriptor_file}"
python3 - "${descriptor_file}" "${idp_cert_file}" <<'PY'
import sys
import textwrap
import xml.etree.ElementTree as ET

root = ET.parse(sys.argv[1]).getroot()
certificates = []
for node in root.iter():
    if node.tag.endswith("X509Certificate") and node.text:
        value = "".join(node.text.split())
        if value and value not in certificates:
            certificates.append(value)
if len(certificates) != 1:
    raise SystemExit(f"Keycloak signing certificate count is {len(certificates)}, expected 1")
with open(sys.argv[2], "w", encoding="utf-8") as output:
    output.write("-----BEGIN CERTIFICATE-----\n")
    output.write("\n".join(textwrap.wrap(certificates[0], 64)))
    output.write("\n-----END CERTIFICATE-----\n")
PY

sonar_post() {
  curl --silent --show-error --fail --netrc-file "${netrc_file}" --request POST "$@"
}

if [[ "${mode}" == --apply ]]; then
  declare -a settings=(
    'sonar.core.serverBaseURL=https://sonar.imcherry5778.xyz'
    'sonar.forceAuthentication=true'
    'sonar.auth.saml.applicationId=sonarqube'
    'sonar.auth.saml.providerId=https://sso.imcherry5778.xyz/realms/platform'
    'sonar.auth.saml.providerName=Keycloak'
    'sonar.auth.saml.loginUrl=https://sso.imcherry5778.xyz/realms/platform/protocol/saml'
    'sonar.auth.saml.user.login=login'
    'sonar.auth.saml.user.name=name'
    'sonar.auth.saml.user.email=email'
    'sonar.auth.saml.group.name=groups'
    'sonar.auth.saml.signature.enabled=false'
  )
  for setting in "${settings[@]}"; do
    key=${setting%%=*}
    value=${setting#*=}
    sonar_post --data-urlencode "key=${key}" --data-urlencode "value=${value}" \
      "${sonar_url}/api/settings/set" >/dev/null
  done
  sonar_post --data-urlencode key=sonar.auth.saml.certificate.secured \
    --data-urlencode "value@${idp_cert_file}" "${sonar_url}/api/settings/set" >/dev/null
  sonar_post --data-urlencode key=sonar.auth.saml.enabled --data-urlencode value=true \
    "${sonar_url}/api/settings/set" >/dev/null
fi

settings_json=$(curl --silent --show-error --fail --netrc-file "${netrc_file}" \
  --get --data-urlencode 'keys=sonar.core.serverBaseURL,sonar.forceAuthentication,sonar.auth.saml.enabled,sonar.auth.saml.applicationId,sonar.auth.saml.providerId,sonar.auth.saml.providerName,sonar.auth.saml.loginUrl,sonar.auth.saml.user.login,sonar.auth.saml.user.name,sonar.auth.saml.user.email,sonar.auth.saml.group.name,sonar.auth.saml.signature.enabled' \
  "${sonar_url}/api/settings/values")
if ! jq -e '
  def v($key): [.settings[] | select(.key == $key)][0].value;
  v("sonar.core.serverBaseURL") == "https://sonar.imcherry5778.xyz" and
  v("sonar.forceAuthentication") == "true" and
  v("sonar.auth.saml.enabled") == "true" and
  v("sonar.auth.saml.applicationId") == "sonarqube" and
  v("sonar.auth.saml.providerId") == "https://sso.imcherry5778.xyz/realms/platform" and
  v("sonar.auth.saml.providerName") == "Keycloak" and
  v("sonar.auth.saml.loginUrl") == "https://sso.imcherry5778.xyz/realms/platform/protocol/saml" and
  v("sonar.auth.saml.user.login") == "login" and
  v("sonar.auth.saml.user.name") == "name" and
  v("sonar.auth.saml.user.email") == "email" and
  v("sonar.auth.saml.group.name") == "groups" and
  v("sonar.auth.saml.signature.enabled") == "false"
' <<<"${settings_json}" >/dev/null; then
  [[ "${mode}" == --check ]] && {
    echo "QUALITY-01 SonarQube SAML 설정 적용이 필요하다."
    exit 0
  }
  echo "SonarQube SAML 설정이 선언과 다르다." >&2
  exit 1
fi
echo "QUALITY-01 SonarQube SAML 설정: match"

groups_json=$(curl --silent --show-error --fail --netrc-file "${netrc_file}" \
  --get --data-urlencode q=platform-users "${sonar_url}/api/user_groups/search")
group_count=$(jq '[.groups[] | select(.name == "platform-users")] | length' <<<"${groups_json}")
[[ "${group_count}" -le 1 ]] || {
  echo "SonarQube platform-users group이 중복이다." >&2
  exit 1
}
if [[ "${mode}" == --apply && "${group_count}" -eq 0 ]]; then
  sonar_post --data-urlencode name=platform-users "${sonar_url}/api/user_groups/create" >/dev/null
  group_count=1
fi
echo "QUALITY-01 SonarQube group platform-users: $([[ "${group_count}" -eq 1 ]] && echo match || echo absent)"

gate_count=$(curl --silent --show-error --fail --netrc-file "${netrc_file}" \
  "${sonar_url}/api/qualitygates/list" | jq --arg name "${gate_name}" '[.qualitygates[] | select(.name == $name)] | length')
[[ "${gate_count}" -le 1 ]] || {
  echo "QUALITY-01 quality gate가 중복이다." >&2
  exit 1
}
if [[ "${mode}" == --apply && "${gate_count}" -eq 0 ]]; then
  sonar_post --data-urlencode name="${gate_name}" "${sonar_url}/api/qualitygates/create" >/dev/null
  gate_count=1
fi
if [[ "${gate_count}" -eq 1 ]]; then
  gate_json=$(curl --silent --show-error --fail --netrc-file "${netrc_file}" \
    --get --data-urlencode name="${gate_name}" "${sonar_url}/api/qualitygates/show")
  if ! jq -e '
    .name == "QUALITY-01" and
    ([.conditions[] | {metric,op,error}]) ==
      [{metric:"coverage",op:"LT",error:"80"}]
  ' <<<"${gate_json}" >/dev/null; then
    if [[ "${mode}" == --check ]]; then
      echo "QUALITY-01 quality gate 단일 coverage 조건 적용이 필요하다."
      exit 0
    fi
    while IFS= read -r condition_id; do
      sonar_post --data-urlencode "id=${condition_id}" \
        "${sonar_url}/api/qualitygates/delete_condition" >/dev/null
    done < <(jq -r '.conditions[].id' <<<"${gate_json}")
    sonar_post --data-urlencode gateName="${gate_name}" \
      --data-urlencode metric=coverage --data-urlencode op=LT \
      --data-urlencode error=80 \
      "${sonar_url}/api/qualitygates/create_condition" >/dev/null
    gate_json=$(curl --silent --show-error --fail --netrc-file "${netrc_file}" \
      --get --data-urlencode name="${gate_name}" "${sonar_url}/api/qualitygates/show")
    jq -e '
      .name == "QUALITY-01" and
      ([.conditions[] | {metric,op,error}]) ==
        [{metric:"coverage",op:"LT",error:"80"}]
    ' <<<"${gate_json}" >/dev/null || {
      echo "QUALITY-01 gate를 단일 coverage 조건으로 수렴하지 못했다." >&2
      exit 1
    }
  fi
fi
echo "QUALITY-01 quality gate: $([[ "${gate_count}" -eq 1 ]] && echo match || echo absent)"

for project in quality01-pass quality01-fail; do
  count=$(curl --silent --show-error --fail --netrc-file "${netrc_file}" \
    --get --data-urlencode "projects=${project}" "${sonar_url}/api/projects/search" | \
    jq --arg key "${project}" '[.components[] | select(.key == $key)] | length')
  [[ "${count}" -le 1 ]] || {
    echo "SonarQube project ${project}가 중복이다." >&2
    exit 1
  }
  if [[ "${mode}" == --apply && "${count}" -eq 0 ]]; then
    sonar_post --data-urlencode "project=${project}" --data-urlencode "name=${project}" \
      "${sonar_url}/api/projects/create" >/dev/null
    count=1
  fi
  if [[ "${mode}" == --apply && "${count}" -eq 1 ]]; then
    sonar_post --data-urlencode gateName="${gate_name}" --data-urlencode projectKey="${project}" \
      "${sonar_url}/api/qualitygates/select" >/dev/null
  fi
  echo "QUALITY-01 project ${project}: $([[ "${count}" -eq 1 ]] && echo match || echo absent)"
done

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

if vault_exec <<'REMOTE' >/dev/null 2>&1
vault kv metadata get kv/sonarqube/verification
REMOTE
then
  echo "QUALITY-01 scanner project tokens: Vault KV present"
elif [[ "${mode}" == --apply ]]; then
  tokens_json=${temp_dir}/tokens.json
  curl --silent --show-error --fail --netrc-file "${netrc_file}" \
    "${sonar_url}/api/user_tokens/search" >"${tokens_json}"
  for token_name in quality01-pass quality01-fail; do
    jq -e --arg name "${token_name}" '[.userTokens[] | select(.name == $name)] | length == 0' \
      "${tokens_json}" >/dev/null || {
      echo "Vault 원문 없이 기존 token ${token_name}만 남았다. 자동 회전하지 않는다." >&2
      exit 1
    }
  done
  pass_json=${temp_dir}/pass-token.json
  fail_json=${temp_dir}/fail-token.json
  sonar_post --data-urlencode name=quality01-pass \
    --data-urlencode type=PROJECT_ANALYSIS_TOKEN --data-urlencode projectKey=quality01-pass \
    "${sonar_url}/api/user_tokens/generate" >"${pass_json}"
  sonar_post --data-urlencode name=quality01-fail \
    --data-urlencode type=PROJECT_ANALYSIS_TOKEN --data-urlencode projectKey=quality01-fail \
    "${sonar_url}/api/user_tokens/generate" >"${fail_json}"
  pass_token=$(jq -er '.token' "${pass_json}")
  fail_token=$(jq -er '.token' "${fail_json}")
  verification_payload=${temp_dir}/verification.json
  jq -n --arg pass_token "${pass_token}" --arg fail_token "${fail_token}" \
    '{pass_token: $pass_token, fail_token: $fail_token}' >"${verification_payload}"
  {
    tr -d '\n' <"${vault_token_file}"
    printf '\n'
    cat "${verification_payload}"
  } | ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
      set -eu
      read -r VAULT_TOKEN
      export VAULT_TOKEN
      umask 077
      trap \"find /tmp/quality01-verification.json -delete\" EXIT
      cat > /tmp/quality01-verification.json
      vault kv put kv/sonarqube/verification @/tmp/quality01-verification.json >/dev/null
    '"
  unset pass_token fail_token
  echo "QUALITY-01 scanner project tokens를 Vault에만 저장했다."
else
  echo "QUALITY-01 scanner project tokens: absent"
fi
