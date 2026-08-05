#!/usr/bin/env bash
# OBS-03 Grafana client와 /grafana-editors group만 check-first로 선언한다.
# 기존 realm 객체는 보정하지 않고, 두 daily ID에 신규 group membership만 추가한다.
set -Eeuo pipefail

usage() {
  cat <<'EOF'
사용법:
  ./gitops/tools/obs-03/provision-keycloak.sh --check|--apply

--check는 비밀 제외 client 필드, group과 membership을 비교한다.
--apply는 없는 grafana client/group과 두 membership만 추가한다.
기존 객체가 선언과 다르거나 group에 다른 회원이 있으면 변경하지 않고 실패한다.
EOF
}

readonly mode=${1:-}
if [[ ${mode} != --check && ${mode} != --apply ]]; then
  usage >&2
  exit 2
fi

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly kc_secret_dir=${KC01_SECRET_DIR:-${secret_root}/keycloak}
readonly obs_secret_dir=${OBS03_SECRET_DIR:-${secret_root}/obs}
readonly client_secret_file=${OBS03_CLIENT_SECRET_FILE:-${obs_secret_dir}/grafana-oidc-client-secret}
readonly issuer=https://sso.imcherry5778.xyz
readonly issuer_host=sso.imcherry5778.xyz
readonly connect_ip=${KC01_CONNECT_IP:-10.10.20.10}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly client_declaration=${repo_root}/gitops/tools/obs-03/keycloak-client.json
readonly desired_members=(imcherry5778 cerberos2022)
readonly privileged_username=imcherry5778-admin

case ${kc_secret_dir} in
  /|/home|/home/*/projects|/home/*/projects/*|"${repo_root}"|"${repo_root}"/*)
    echo "KC01_SECRET_DIR가 너무 넓거나 저장소 경로다: ${kc_secret_dir}" >&2
    exit 1
    ;;
esac
case ${obs_secret_dir} in
  /|/home|/home/*/projects|/home/*/projects/*|"${repo_root}"|"${repo_root}"/*)
    echo "OBS03_SECRET_DIR가 너무 넓거나 저장소 경로다: ${obs_secret_dir}" >&2
    exit 1
    ;;
esac
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
  rm -rf "${temp_dir}"
}
trap cleanup EXIT INT TERM

readonly admin_header=${temp_dir}/admin.header
readonly clients_json=${temp_dir}/clients.json
readonly groups_json=${temp_dir}/groups.json
readonly members_json=${temp_dir}/members.json
readonly response_json=${temp_dir}/response.json
readonly client_payload=${temp_dir}/client-payload.json
readonly client_secret_json=${temp_dir}/client-secret.json
readonly canonical_client_secret=${temp_dir}/canonical-client-secret

client_secret_file_state() {
  local bytes lines last_byte
  [[ -f ${client_secret_file} && ! -L ${client_secret_file} ]] || {
    echo missing
    return
  }
  bytes=$(wc -c <"${client_secret_file}")
  lines=$(wc -l <"${client_secret_file}")
  last_byte=$(tail -c 1 "${client_secret_file}" | od -An -tu1 | tr -d ' ')
  if [[ ${bytes} -eq 49 && ${lines} -eq 1 && ${last_byte} == 10 ]] &&
     head -n 1 "${client_secret_file}" | LC_ALL=C grep -Eq '^[A-Za-z0-9]{48}$'; then
    echo canonical
  elif [[ ${bytes} -eq 50 && ${lines} -eq 2 && ${last_byte} == 10 ]] &&
       head -n 1 "${client_secret_file}" | LC_ALL=C grep -Eq '^[A-Za-z0-9]{48}$'; then
    echo legacy-double-newline
  else
    echo invalid
  fi
}

# kc-recovery의 직전 검증과 같은 TOTP 값을 재사용하지 않는다.
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
  --capture-callback \
  --expect-realm-role admin >/dev/null

curl_admin() {
  curl --silent --show-error --fail \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --header "@${admin_header}" \
    "$@"
}

client_matches() {
  jq -e '
    length == 1 and
    .[0].clientId == "grafana" and
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
    .[0].rootUrl == "https://grafana.imcherry5778.xyz" and
    .[0].baseUrl == "https://grafana.imcherry5778.xyz/" and
    .[0].redirectUris == ["https://grafana.imcherry5778.xyz/login/generic_oauth"] and
    .[0].webOrigins == ["https://grafana.imcherry5778.xyz"] and
    .[0].attributes["post.logout.redirect.uris"] == "https://grafana.imcherry5778.xyz/" and
    (.[0].protocolMappers | map(select(
      .name == "groups" and
      .protocol == "openid-connect" and
      .protocolMapper == "oidc-group-membership-mapper" and
      .config["claim.name"] == "groups" and
      .config["full.path"] == "true" and
      .config["id.token.claim"] == "true" and
      .config["access.token.claim"] == "true" and
      .config["userinfo.token.claim"] == "true"
    )) | length == 1)
  ' "${clients_json}" >/dev/null
}

safe_client_summary() {
  jq '[.[] | {
    clientId, enabled, protocol, publicClient, clientAuthenticatorType,
    standardFlowEnabled, implicitFlowEnabled, directAccessGrantsEnabled,
    serviceAccountsEnabled, authorizationServicesEnabled, fullScopeAllowed,
    rootUrl, baseUrl, redirectUris, webOrigins,
    attributes:{post_logout_redirect_uris:.attributes["post.logout.redirect.uris"]},
    protocolMappers:[.protocolMappers[]? | select(.name == "groups") |
      {name, protocol, protocolMapper, config}]
  }]' "${clients_json}"
}

load_client() {
  curl_admin "${issuer}/admin/realms/platform/clients?clientId=grafana" >"${clients_json}"
}

load_group() {
  curl_admin "${issuer}/admin/realms/platform/groups?search=grafana-editors&exact=true&briefRepresentation=false" \
    | jq '[.[] | select(.name == "grafana-editors" and .path == "/grafana-editors")]' \
      >"${groups_json}"
}

declare -A user_ids=()
load_users() {
  local username user_json user_count
  for username in "${desired_members[@]}" "${privileged_username}"; do
    user_json=${temp_dir}/user-${username}.json
    curl_admin "${issuer}/admin/realms/platform/users?username=${username}&exact=true" >"${user_json}"
    user_count=$(jq 'length' "${user_json}")
    [[ ${user_count} -eq 1 ]] || {
      echo "username=${username} live 객체가 ${user_count}건이다. 변경하지 않는다." >&2
      exit 1
    }
    jq -e --arg username "${username}" \
      '.[0].username == $username and .[0].enabled == true' "${user_json}" >/dev/null || {
      echo "username=${username}이 enabled exact 객체가 아니다. 변경하지 않는다." >&2
      exit 1
    }
    user_ids[${username}]=$(jq -r '.[0].id' "${user_json}")
  done
}

load_members() {
  local group_id=$1
  curl_admin "${issuer}/admin/realms/platform/groups/${group_id}/members?first=0&max=100&briefRepresentation=true" \
    >"${members_json}"
}

members_have_no_extras() {
  jq -e --arg first "${desired_members[0]}" --arg second "${desired_members[1]}" '
    [.[].username] - [$first, $second] | length == 0
  ' "${members_json}" >/dev/null
}

members_match() {
  jq -e --arg first "${desired_members[0]}" --arg second "${desired_members[1]}" '
    ([.[].username] | sort) == ([$first, $second] | sort)
  ' "${members_json}" >/dev/null
}

privileged_not_member() {
  local user_id=${user_ids[${privileged_username}]}
  curl_admin "${issuer}/admin/realms/platform/users/${user_id}/groups?briefRepresentation=true" \
    | jq -e '[.[] | select(.path == "/grafana-editors")] | length == 0' >/dev/null
}

load_client
client_count=$(jq 'length' "${clients_json}")
case ${client_count} in
  0)
    echo 'OBS-03 Keycloak 차이: grafana client 0건 -> 신규 confidential client 추가 대상'
    ;;
  1)
    if client_matches; then
      echo 'OBS-03 Keycloak 차이: grafana client 1건 -> 선언 일치'
    else
      safe_client_summary
      echo 'live grafana client가 OBS-03 선언과 다르다. 자동 보정하지 않는다.' >&2
      exit 1
    fi
    ;;
  *)
    echo "clientId=grafana live 객체가 ${client_count}건이다. 변경하지 않는다." >&2
    exit 1
    ;;
esac

load_users
load_group
group_count=$(jq 'length' "${groups_json}")
case ${group_count} in
  0)
    echo 'OBS-03 Keycloak 차이: /grafana-editors group 0건 -> 신규 top-level group 추가 대상'
    ;;
  1)
    group_id=$(jq -r '.[0].id' "${groups_json}")
    load_members "${group_id}"
    members_have_no_extras || {
      jq '[.[].username] | sort' "${members_json}"
      echo 'live /grafana-editors에 OBS-03 범위 밖 회원이 있다. 변경하지 않는다.' >&2
      exit 1
    }
    if members_match; then
      echo 'OBS-03 Keycloak 차이: /grafana-editors membership -> 선언 일치'
    else
      echo 'OBS-03 Keycloak 차이: /grafana-editors -> 두 daily ID membership 추가 대상'
    fi
    privileged_not_member || {
      echo 'imcherry5778-admin이 /grafana-editors에 가입돼 있다. 변경하지 않는다.' >&2
      exit 1
    }
    ;;
  *)
    echo "path=/grafana-editors live 객체가 ${group_count}건이다. 변경하지 않는다." >&2
    exit 1
    ;;
esac

client_secret_state=missing
if [[ ${client_count} -eq 1 ]]; then
  [[ -f ${client_secret_file} && ! -L ${client_secret_file} &&
     $(stat -c %a "${client_secret_file}") == 600 ]] || {
    echo 'Grafana OIDC client secret input이 mode 0600 regular file이 아니다.' >&2
    exit 1
  }
  client_id=$(jq -r '.[0].id' "${clients_json}")
  curl_admin "${issuer}/admin/realms/platform/clients/${client_id}/client-secret" \
    >"${client_secret_json}"
  client_secret_state=$(client_secret_file_state)
  case ${client_secret_state} in
    canonical)
      jq -e --rawfile expected "${client_secret_file}" \
        '.value == ($expected | rtrimstr("\n"))' "${client_secret_json}" >/dev/null || {
        echo 'live grafana client secret과 canonical 저장소 밖 입력이 다르다. 변경하지 않는다.' >&2
        exit 1
      }
      echo 'OBS-03 Keycloak 차이: grafana client secret -> canonical 선언 일치'
      ;;
    legacy-double-newline)
      jq -e --rawfile expected "${client_secret_file}" \
        '.value == ($expected | rtrimstr("\n"))' "${client_secret_json}" >/dev/null || {
        echo 'live grafana client secret이 허용된 double-newline legacy와 다르다. 변경하지 않는다.' >&2
        exit 1
      }
      echo 'OBS-03 Keycloak 차이: grafana client secret -> trailing newline 1 byte 교정 대상'
      ;;
    *)
      echo 'Grafana OIDC client secret input은 영숫자 48자와 종단 newline 1개여야 한다.' >&2
      exit 1
      ;;
  esac
fi

if [[ ${mode} == --check ]]; then
  exit 0
fi

install -d -m 0700 "${obs_secret_dir}"
if [[ ${client_count} -eq 0 ]]; then
  if [[ ! -e ${client_secret_file} ]]; then
    openssl rand -hex 24 >"${client_secret_file}"
  fi
  [[ -f ${client_secret_file} && ! -L ${client_secret_file} ]] || {
    echo 'Grafana OIDC client secret input이 regular file이 아니다.' >&2
    exit 1
  }
  chmod 0600 "${client_secret_file}"
  [[ $(client_secret_file_state) == canonical ]] || {
    echo 'Grafana OIDC client secret input은 영숫자 48자와 종단 newline 1개여야 한다.' >&2
    exit 1
  }
  jq --rawfile client_secret "${client_secret_file}" \
    '. + {secret: ($client_secret | rtrimstr("\n"))}' \
    "${client_declaration}" >"${client_payload}"
  http_status=$(curl --silent --show-error \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${response_json}" --write-out '%{http_code}' \
    --request POST \
    --header "@${admin_header}" \
    --header 'Content-Type: application/json' \
    --data-binary "@${client_payload}" \
    "${issuer}/admin/realms/platform/clients")
  [[ ${http_status} == 201 ]] || {
    echo "OBS-03 Keycloak client 생성 실패: HTTP ${http_status}" >&2
    exit 1
  }
  echo 'OBS-03: 기존 client를 수정하지 않고 grafana confidential client 한 건을 추가했다.'
elif [[ ${client_secret_state} == legacy-double-newline ]]; then
  head -n 1 "${client_secret_file}" >"${canonical_client_secret}"
  chmod 0600 "${canonical_client_secret}"
  client_id=$(jq -r '.[0].id' "${clients_json}")
  jq --arg id "${client_id}" --rawfile client_secret "${canonical_client_secret}" \
    '. + {id: $id, secret: ($client_secret | rtrimstr("\n"))}' \
    "${client_declaration}" >"${client_payload}"
  http_status=$(curl --silent --show-error \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${response_json}" --write-out '%{http_code}' \
    --request PUT \
    --header "@${admin_header}" \
    --header 'Content-Type: application/json' \
    --data-binary "@${client_payload}" \
    "${issuer}/admin/realms/platform/clients/${client_id}")
  [[ ${http_status} == 204 ]] || {
    echo "OBS-03 Keycloak client secret newline 교정 실패: HTTP ${http_status}" >&2
    exit 1
  }
  install -m 0600 "${canonical_client_secret}" "${client_secret_file}"
  echo 'OBS-03: grafana client secret의 잘못 포함된 trailing newline 1 byte를 교정했다.'
fi

load_client
client_matches || {
  echo '생성 후 grafana client 선언 일치 검증에 실패했다.' >&2
  exit 1
}
client_id=$(jq -r '.[0].id' "${clients_json}")
curl_admin "${issuer}/admin/realms/platform/clients/${client_id}/client-secret" >"${client_secret_json}"
if [[ ! -e ${client_secret_file} ]]; then
  jq -er '.value' "${client_secret_json}" >"${client_secret_file}"
  chmod 0600 "${client_secret_file}"
fi
[[ -f ${client_secret_file} && ! -L ${client_secret_file} &&
   $(stat -c %a "${client_secret_file}") == 600 &&
   $(client_secret_file_state) == canonical ]] || {
  echo 'Grafana OIDC client secret input이 mode 0600 regular file이 아니다.' >&2
  exit 1
}
jq -e --rawfile expected "${client_secret_file}" \
  '.value == ($expected | rtrimstr("\n"))' "${client_secret_json}" >/dev/null || {
  echo 'live grafana client secret과 저장소 밖 입력이 다르다. client를 보정하지 않는다.' >&2
  exit 1
}

if [[ ${group_count} -eq 0 ]]; then
  http_status=$(curl --silent --show-error \
    --resolve "${issuer_host}:443:${connect_ip}" \
    --output "${response_json}" --write-out '%{http_code}' \
    --request POST \
    --header "@${admin_header}" \
    --header 'Content-Type: application/json' \
    --data-binary '{"name":"grafana-editors"}' \
    "${issuer}/admin/realms/platform/groups")
  [[ ${http_status} == 201 ]] || {
    echo "OBS-03 Keycloak group 생성 실패: HTTP ${http_status}" >&2
    exit 1
  }
  echo 'OBS-03: 기존 group을 수정하지 않고 /grafana-editors 한 건을 추가했다.'
fi

load_group
[[ $(jq 'length' "${groups_json}") -eq 1 ]] || {
  echo '생성 후 /grafana-editors exact group을 찾지 못했다.' >&2
  exit 1
}
group_id=$(jq -r '.[0].id' "${groups_json}")
load_members "${group_id}"
members_have_no_extras || {
  echo 'membership 적용 전 범위 밖 회원을 발견했다. 변경하지 않는다.' >&2
  exit 1
}
for username in "${desired_members[@]}"; do
  if ! jq -e --arg username "${username}" \
    '[.[] | select(.username == $username)] | length == 1' "${members_json}" >/dev/null; then
    http_status=$(curl --silent --show-error \
      --resolve "${issuer_host}:443:${connect_ip}" \
      --output "${response_json}" --write-out '%{http_code}' \
      --request PUT \
      --header "@${admin_header}" \
      "${issuer}/admin/realms/platform/users/${user_ids[${username}]}/groups/${group_id}")
    [[ ${http_status} == 204 ]] || {
      echo "OBS-03 ${username} group membership 추가 실패: HTTP ${http_status}" >&2
      exit 1
    }
    echo "OBS-03: ${username}에 /grafana-editors membership을 추가했다."
  fi
done

load_members "${group_id}"
members_match || {
  echo '적용 후 /grafana-editors membership 선언 일치 검증에 실패했다.' >&2
  exit 1
}
privileged_not_member || {
  echo '적용 후 imcherry5778-admin group 미가입 검증에 실패했다.' >&2
  exit 1
}
echo 'OBS-03: Keycloak client=grafana group=/grafana-editors members=2 privileged-mapping=none 선언 검증 통과'
