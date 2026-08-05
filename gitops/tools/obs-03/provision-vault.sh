#!/usr/bin/env bash
# OBS-03은 기존 obs-grafana policy/role을 건드리지 않고 KV 한 key만 CAS patch한다.
set -Eeuo pipefail

readonly mode=${1:-}
if [[ ${mode} != --check && ${mode} != --apply ]]; then
  echo "사용법: $0 --check|--apply" >&2
  exit 2
fi

readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly client_secret_file=${OBS03_CLIENT_SECRET_FILE:-${secret_root}/obs/grafana-oidc-client-secret}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly vault_addr=${OBS03_VAULT_ADDR:-https://vault.imcherry5778.xyz}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root

client_secret_is_canonical() {
  local bytes lines last_byte
  [[ -f ${client_secret_file} && ! -L ${client_secret_file} ]] || return 1
  bytes=$(wc -c <"${client_secret_file}")
  lines=$(wc -l <"${client_secret_file}")
  last_byte=$(tail -c 1 "${client_secret_file}" | od -An -tu1 | tr -d ' ')
  [[ ${bytes} -eq 49 && ${lines} -eq 1 && ${last_byte} == 10 ]] &&
    head -n 1 "${client_secret_file}" | LC_ALL=C grep -Eq '^[A-Za-z0-9]{48}$'
}

for input in "${vault_root_token_file}"; do
  [[ -f ${input} && ! -L ${input} && -s ${input} &&
     $(stat -c %u "${input}") -eq $(id -u) && $(stat -c %a "${input}") == 600 ]] || {
    echo 'Vault root token 입력은 호출자 소유 mode 0600 regular file이어야 한다.' >&2
    exit 1
  }
done
case ${vault_root_token_file} in
  "${repo_root}"|"${repo_root}"/*)
    echo 'Vault root token 입력은 저장소 밖이어야 한다.' >&2
    exit 1
    ;;
esac

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  rm -rf "${temp_dir}"
}
trap cleanup EXIT INT TERM

vault_cli() {
  local root_token
  root_token=$(tr -d '\n' <"${vault_root_token_file}")
  VAULT_ADDR="${vault_addr}" VAULT_TOKEN="${root_token}" vault "$@"
}

snapshot_live() {
  local suffix=$1
  vault_cli policy read -format=json obs-grafana >"${temp_dir}/policy-${suffix}.json"
  vault_cli read -format=json auth/kubernetes/role/obs-grafana >"${temp_dir}/role-${suffix}.json"
  vault_cli kv get -format=json kv/obs/grafana >"${temp_dir}/kv-${suffix}.json"
}

policy_matches() {
  local file=$1
  jq -e '.policy == "path \"kv/data/obs/grafana\" {\n  capabilities = [\"read\"]\n}\n"' \
    "${file}" >/dev/null
}

role_matches() {
  local file=$1
  jq -e '
    .data.bound_service_account_names == ["obs-grafana"] and
    .data.bound_service_account_namespaces == ["obs"] and
    .data.audience == "vault" and
    .data.token_policies == ["obs-grafana"] and
    .data.token_no_default_policy == true and
    .data.token_ttl == 600 and
    .data.token_max_ttl == 1800
  ' "${file}" >/dev/null
}

snapshot_live before
policy_matches "${temp_dir}/policy-before.json" || {
  echo '기존 obs-grafana policy가 OBS-01 선언과 다르다. 변경하지 않는다.' >&2
  exit 1
}
role_matches "${temp_dir}/role-before.json" || {
  echo '기존 obs-grafana role이 OBS-01 선언과 다르다. 변경하지 않는다.' >&2
  exit 1
}

kv_keys=$(jq -c '.data.data | keys | sort' "${temp_dir}/kv-before.json")
case ${kv_keys} in
  '["admin_password"]')
    jq -e '.data.data.admin_password | type == "string" and length > 0' \
      "${temp_dir}/kv-before.json" >/dev/null || {
      echo '기존 admin_password가 비어 있다. 변경하지 않는다.' >&2
      exit 1
    }
    echo 'OBS-03 Vault 차이: kv/obs/grafana keys=admin_password -> oidc_client_secret 추가 대상'
    ;;
  '["admin_password","oidc_client_secret"]')
    jq -e '
      (.data.data.admin_password | type == "string" and length > 0) and
      (.data.data.oidc_client_secret | type == "string" and length > 0)
    ' "${temp_dir}/kv-before.json" >/dev/null || {
      echo '기존 Grafana KV key 값 중 빈 값이 있다. 변경하지 않는다.' >&2
      exit 1
    }
    echo 'OBS-03 Vault 차이: kv/obs/grafana keys=admin_password,oidc_client_secret -> key 선언 일치'
    ;;
  *)
    echo "kv/obs/grafana에 범위 밖 key가 있다: ${kv_keys}" >&2
    exit 1
    ;;
esac

vault_secret_state=absent
if [[ ${kv_keys} == '["admin_password","oidc_client_secret"]' ]]; then
  [[ -f ${client_secret_file} && ! -L ${client_secret_file} && -s ${client_secret_file} &&
     $(stat -c %a "${client_secret_file}") == 600 ]] && client_secret_is_canonical || {
    echo 'Grafana OIDC client secret 입력은 canonical mode 0600 regular file이어야 한다.' >&2
    exit 1
  }
  if jq -e --rawfile expected "${client_secret_file}" \
    '.data.data.oidc_client_secret == ($expected | rtrimstr("\n"))' \
    "${temp_dir}/kv-before.json" >/dev/null; then
    vault_secret_state=canonical
  elif jq -e --rawfile expected "${client_secret_file}" \
    '.data.data.oidc_client_secret == (($expected | rtrimstr("\n")) + "\n")' \
    "${temp_dir}/kv-before.json" >/dev/null; then
    vault_secret_state=legacy-trailing-newline
    echo 'OBS-03 Vault 차이: oidc_client_secret trailing newline 1 byte 교정 대상'
  else
    echo 'Vault oidc_client_secret이 canonical 입력 또는 허용된 newline legacy와 다르다.' >&2
    exit 1
  fi
fi

if [[ ${mode} == --check ]]; then
  if [[ ${kv_keys} == '["admin_password","oidc_client_secret"]' ]]; then
    echo "OBS-03 Vault: oidc_client_secret=${vault_secret_state}, obs-grafana policy/role 선언 일치"
  fi
  exit 0
fi

[[ -f ${client_secret_file} && ! -L ${client_secret_file} && -s ${client_secret_file} &&
   $(stat -c %u "${client_secret_file}") -eq $(id -u) &&
   $(stat -c %a "${client_secret_file}") == 600 ]] && client_secret_is_canonical || {
  echo 'Grafana OIDC client secret 입력은 호출자 소유 mode 0600 regular file이어야 한다.' >&2
  exit 1
}

if [[ ${kv_keys} == '["admin_password"]' || ${vault_secret_state} == legacy-trailing-newline ]]; then
  jq -n --rawfile oidc_client_secret "${client_secret_file}" \
    '{oidc_client_secret: ($oidc_client_secret | rtrimstr("\n"))}' \
    >"${temp_dir}/patch.json"
  current_version=$(jq -r '.data.metadata.version' "${temp_dir}/kv-before.json")
  [[ ${current_version} =~ ^[1-9][0-9]*$ ]] || {
    echo 'Vault KV current version을 읽지 못했다.' >&2
    exit 1
  }
  vault_cli kv patch -cas="${current_version}" kv/obs/grafana \
    "@${temp_dir}/patch.json" >/dev/null
  if [[ ${kv_keys} == '["admin_password"]' ]]; then
    echo 'OBS-03: kv/obs/grafana에 oidc_client_secret key 한 건을 CAS patch했다.'
  else
    echo 'OBS-03: kv/obs/grafana oidc_client_secret의 trailing newline 1 byte를 CAS patch로 교정했다.'
  fi
fi

snapshot_live after
jq -S '.policy' "${temp_dir}/policy-before.json" >"${temp_dir}/policy-before.normalized"
jq -S '.policy' "${temp_dir}/policy-after.json" >"${temp_dir}/policy-after.normalized"
cmp -s "${temp_dir}/policy-before.normalized" "${temp_dir}/policy-after.normalized" || {
  echo 'OBS-03 적용 중 obs-grafana policy가 바뀌었다.' >&2
  exit 1
}
jq -S '.data' "${temp_dir}/role-before.json" >"${temp_dir}/role-before.normalized"
jq -S '.data' "${temp_dir}/role-after.json" >"${temp_dir}/role-after.normalized"
cmp -s "${temp_dir}/role-before.normalized" "${temp_dir}/role-after.normalized" || {
  echo 'OBS-03 적용 중 obs-grafana role이 바뀌었다.' >&2
  exit 1
}
jq -e --rawfile expected "${client_secret_file}" '
  (.data.data | keys | sort) == ["admin_password","oidc_client_secret"] and
  (.data.data.admin_password | type == "string" and length > 0) and
  .data.data.oidc_client_secret == ($expected | rtrimstr("\n"))
' "${temp_dir}/kv-after.json" >/dev/null || {
  echo 'OBS-03 적용 후 Grafana KV key 또는 client secret 일치 검증에 실패했다.' >&2
  exit 1
}
echo 'OBS-03: Vault keys=admin_password,oidc_client_secret policy=unchanged role=unchanged 검증 통과'
