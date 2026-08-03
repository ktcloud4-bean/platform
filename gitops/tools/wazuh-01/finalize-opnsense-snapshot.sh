#!/usr/bin/env bash
# WAZUH-01-FIX-01: apply-opnsense.sh apply 성공과 verify-live.sh의 다섯 완료 증거를
# 모두 통과한 뒤에만 수동으로 실행하는 snapshot finalize 단계.
#
# apply-opnsense.sh apply는 이 스크립트를 호출하지 않는다. 전체 검증 전에
# check-drift.sh --update를 부르면 실패한 상태나 동시 foreign drift를
# 정상 상태로 흡수할 수 있기 때문이다. exact-diff gate를 통과한 diff만
# check-drift.sh --update로 승인하고, 그 밖의 어떤 차이라도 있으면 라이브를
# 건드리지 않고 중단한다.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
readonly script_dir
repo_root="$(cd "$script_dir/../../.." && pwd)"
readonly repo_root
readonly opn_dir="$repo_root/infra/opnsense"
readonly committed="$opn_dir/config.xml"
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly env_file=${OPN_ENV_FILE:-${secret_root}/opnsense/env}
readonly agent_name=${WAZUH01_AGENT_NAME:-opnsense-01}
readonly manager_address=${WAZUH01_MANAGER_ADDRESS:-10.10.20.10}
readonly manager_events_port=${WAZUH01_MANAGER_EVENTS_PORT:-31514}
readonly manager_auth_port=${WAZUH01_MANAGER_AUTH_PORT:-31515}

fail() {
  echo "WAZUH-01-FIX-01 finalize 실패: $*" >&2
  exit 1
}

[[ -f ${committed} ]] || fail "커밋된 snapshot이 없다: ${committed}"
[[ ! -L ${env_file} && -f ${env_file} && -r ${env_file} ]] \
  || fail "OPNsense env 파일을 안전하게 읽을 수 없다: ${env_file}"
mode=$(stat -c '%a' "${env_file}")
owner_id=$(stat -c '%u' "${env_file}")
[[ ${owner_id} == "$(id -u)" && $((10#${mode} % 100)) -eq 0 ]] \
  || fail 'OPNsense env 파일의 소유자 또는 권한이 안전하지 않다.'

tmp=$(mktemp -d /tmp/wazuh-01-fix-01-finalize.XXXXXX)
chmod 700 "${tmp}"
trap 'rm -rf "${tmp}"' EXIT HUP INT TERM

OPN_KEY=''; OPN_SECRET=''; OPN_URL=''
while IFS= read -r line || [[ -n ${line} ]]; do
  line=${line%$'\r'}
  [[ ${line} == OPN_* && ${line} == *=* ]] || continue
  key=${line%%=*}
  value=${line#*=}
  value=${value%\"}; value=${value#\"}
  value=${value%\'}; value=${value#\'}
  case ${key} in
    OPN_KEY|OPN_SECRET|OPN_URL) printf -v "${key}" '%s' "${value}" ;;
  esac
done <"${env_file}"
OPN_URL=${OPN_URL:-https://opnsense.imcherry5778.xyz}
[[ -n ${OPN_KEY} && -n ${OPN_SECRET} ]] || fail 'OPN_KEY와 OPN_SECRET이 필요하다.'

umask 077
printf 'user = "%s:%s"\n' "${OPN_KEY//\"/\\\"}" "${OPN_SECRET//\"/\\\"}" >"${tmp}/auth.conf"
chmod 600 "${tmp}/auth.conf"

curl -q --silent --show-error --fail -K "${tmp}/auth.conf" \
  -o "${tmp}/live-raw.xml" "${OPN_URL}/api/core/backup/download/this" \
  || fail 'live config 다운로드 실패.'
grep -q '<opnsense>' "${tmp}/live-raw.xml" || fail 'live 응답이 OPNsense config XML이 아니다.'

python3 "${opn_dir}/scripts/normalize.py" "${tmp}/live-raw.xml" -o "${tmp}/live.xml"
rm -f "${tmp}/live-raw.xml" "${tmp}/auth.conf"
unset OPN_KEY OPN_SECRET

if diff -q "${committed}" "${tmp}/live.xml" >/dev/null; then
  echo 'FinalizeGate=NO-DRIFT snapshot이 이미 최신이다. --update를 생략한다.'
  exit 0
fi

diff -u0 "${committed}" "${tmp}/live.xml" >"${tmp}/hunks.diff" || true

if ! python3 "${script_dir}/classify_opnsense_drift.py" "${tmp}/hunks.diff" \
      "${agent_name}" "${manager_address}" "${manager_events_port}" "${manager_auth_port}"; then
  fail 'ExactDiffGate=FAIL. 승인 범위 밖 drift가 있어 --update를 호출하지 않고 중단한다.'
fi

echo 'ExactDiffGate=PASS → check-drift.sh --update 호출'
"${opn_dir}/scripts/check-drift.sh" --update

echo '갱신 뒤 일반 drift 재확인'
"${opn_dir}/scripts/check-drift.sh"

echo 'Finalize=PASS'
