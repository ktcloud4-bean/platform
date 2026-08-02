#!/usr/bin/env bash
# shellcheck disable=SC2029
# SIGN-01 완료 증거를 pipeline 정확히 두 번으로 판정한다.
#   pass: 현재 build의 SCAN-01 image/SBOM digest 서명과 active 공개키 검증
#   reject: 별도 현재 build image signature를 고정된 다른 공개키가 거부하고 handoff 없음
set -Eeuo pipefail

readonly secret_root=${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}
readonly jenkins_env=${CI01_ENV_FILE:-${secret_root}/jenkins/env}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly jenkins_port=${SIGN01_JENKINS_PORT:-33223}
readonly job_name=ci01-image-build
readonly resume_pass_build=${SIGN01_RESUME_PASS_BUILD:-}
readonly resume_reject_build=${SIGN01_RESUME_REJECT_BUILD:-}

[[ -f ${jenkins_env} && ! -L ${jenkins_env} && $(stat -c %a "${jenkins_env}") == 600 ]] || {
  echo "credential 입력은 저장소 밖 mode 0600 일반 파일이어야 한다: ${jenkins_env}" >&2
  exit 1
}

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
jenkins_pid=

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)
kube() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }

cleanup() {
  local exit_code=$?
  [[ -n ${jenkins_pid} ]] && kill "${jenkins_pid}" 2>/dev/null || true
  rm -rf -- "${temp_dir}"
  return "${exit_code}"
}
trap cleanup EXIT INT TERM

read_env_value() {
  awk -F= -v key="$2" '$1==key{print substr($0, index($0,"=")+1); exit}' "$1"
}

jenkins_admin_password=$(read_env_value "${jenkins_env}" JENKINS_ADMIN_PASSWORD)
[[ -n ${jenkins_admin_password} ]] || { echo "Jenkins admin 입력을 읽지 못했다" >&2; exit 1; }

jenkins_curl=${temp_dir}/jenkins.curl
cookie_jar=${temp_dir}/cookies
printf 'user = "admin:%s"\ncookie = "%s"\ncookie-jar = "%s"\nsilent\nshow-error\n' \
  "${jenkins_admin_password}" "${cookie_jar}" "${cookie_jar}" >"${jenkins_curl}"
unset jenkins_admin_password

python3 - "${jenkins_port}" <<'PY'
import socket
import sys

sock = socket.socket()
try:
    sock.bind(("127.0.0.1", int(sys.argv[1])))
finally:
    sock.close()
PY

target_ip=$(kube -n jenkins get service jenkins -o "jsonpath='{.spec.clusterIP}'")
[[ ${target_ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
  echo "Jenkins Service ClusterIP를 판정하지 못했다" >&2
  exit 1
}
ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
  -L "${jenkins_port}:${target_ip}:8080" "${k3s_host}" \
  >"${temp_dir}/jenkins-tunnel.log" 2>&1 &
jenkins_pid=$!

tunnel_ready=false
for _ in $(seq 1 60); do
  kill -0 "${jenkins_pid}" 2>/dev/null || break
  code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
    "http://127.0.0.1:${jenkins_port}/login" || true)
  if [[ ${code} == 200 ]]; then
    tunnel_ready=true
    break
  fi
  sleep 2
done
[[ ${tunnel_ready} == true ]] || {
  echo "Jenkins tunnel health timeout" >&2
  sed -n '1,40p' "${temp_dir}/jenkins-tunnel.log" >&2
  exit 1
}

readonly jenkins_api=http://127.0.0.1:${jenkins_port}
jcurl() { curl --config "${jenkins_curl}" "$@"; }
jcurl --fail --output "${temp_dir}/crumb.json" "${jenkins_api}/crumbIssuer/api/json"
crumb_field=$(jq -r '.crumbRequestField' "${temp_dir}/crumb.json")
crumb_value=$(jq -r '.crumb' "${temp_dir}/crumb.json")
echo "SIGN-01 검증: jenkins-auth=ok"

existing=$(kube -n jenkins get pods -l jenkins=slave -o "jsonpath='{.items[*].metadata.name}'")
[[ -z ${existing} ]] || { echo "이전 agent Pod가 남아 있다: ${existing}" >&2; exit 1; }

trigger_build() {
  local sign_case=$1 queue_location
  expected_build=$(jcurl --fail \
    "${jenkins_api}/job/${job_name}/api/json?tree=nextBuildNumber" | jq -r '.nextBuildNumber')
  queue_location=$(jcurl --fail --request POST --dump-header - --output /dev/null \
    --header "${crumb_field}: ${crumb_value}" \
    "${jenkins_api}/job/${job_name}/buildWithParameters?SCAN01_CASE=pass&SIGN01_CASE=${sign_case}" \
    | awk 'tolower($1) == "location:" {gsub(/\r/, "", $2); print $2}')
  [[ -n ${queue_location} ]] || { echo "${sign_case} build 요청이 queue item을 반환하지 않았다" >&2; exit 1; }
  queue_item=${queue_location%/}
  queue_item=${queue_item##*/}
  echo "SIGN-01 검증: case=${sign_case} queue=${queue_item} expected-build=${expected_build}"
}

wait_build() {
  local label=$1 resumed_build=${2:-} build_state
  build_number=${resumed_build}
  build_result=
  if [[ -z ${resumed_build} ]]; then
    for _ in $(seq 1 120); do
      jcurl --output "${temp_dir}/${label}-queue.json" \
        "${jenkins_api}/queue/item/${queue_item}/api/json" || true
      build_number=$(jq -r '.executable.number // empty' \
        "${temp_dir}/${label}-queue.json" 2>/dev/null || true)
      [[ -n ${build_number} ]] && break
      sleep 2
    done
    [[ -n ${build_number} ]] || { echo "${label} queue item이 build로 승격되지 않았다" >&2; exit 1; }
    [[ ${build_number} == "${expected_build}" ]] || {
      echo "${label} build 번호가 예상과 다르다: expected=${expected_build} actual=${build_number}" >&2
      exit 1
    }
  fi

  for _ in $(seq 1 300); do
    jcurl --output "${temp_dir}/${label}-build.json" \
      "${jenkins_api}/job/${job_name}/${build_number}/api/json?tree=building,result" || true
    build_state=$(jq -r 'if .building == false then "finished" else "running" end' \
      "${temp_dir}/${label}-build.json" 2>/dev/null || true)
    if [[ ${build_state} == finished ]]; then
      build_result=$(jq -r '.result // empty' "${temp_dir}/${label}-build.json")
      break
    fi
    sleep 2
  done
  jcurl --fail --output "${temp_dir}/${label}-console.txt" \
    "${jenkins_api}/job/${job_name}/${build_number}/consoleText"
  [[ -n ${build_result} ]] || { echo "${label} build 완료를 감지하지 못했다" >&2; exit 1; }
}

wait_for_no_agent() {
  local remaining
  for _ in $(seq 1 60); do
    remaining=$(kube -n jenkins get pods -l jenkins=slave -o "jsonpath='{.items[*].metadata.name}'")
    [[ -z ${remaining} ]] && return 0
    sleep 2
  done
  echo "agent Pod 정리 timeout: ${remaining}" >&2
  exit 1
}

if [[ -n ${resume_pass_build} ]]; then
  [[ ${resume_pass_build} =~ ^[1-9][0-9]*$ ]] || {
    echo "SIGN01_RESUME_PASS_BUILD는 양의 build 번호여야 한다" >&2
    exit 2
  }
  echo "SIGN-01 검증: case=pass resume-build=${resume_pass_build}"
  wait_build pass "${resume_pass_build}"
else
  trigger_build pass
  wait_build pass
fi
pass_build=${build_number}
[[ ${build_result} == SUCCESS ]] || {
  echo "pass build ${pass_build} 결과가 ${build_result}다. 실패 지점:" >&2
  tail -n 80 "${temp_dir}/pass-console.txt" >&2
  exit 1
}
image_ref=$(awk -F= '/^sign01-image-subject=harbor\.imcherry5778\.xyz\/ci01-evidence\/ci01-app@sha256:/ {print $2}' \
  "${temp_dir}/pass-console.txt" | tail -1)
sbom_ref=$(awk -F= '/^sign01-sbom-subject=harbor\.imcherry5778\.xyz\/ci01-evidence\/ci01-app@sha256:/ {print $2}' \
  "${temp_dir}/pass-console.txt" | tail -1)
[[ ${image_ref} =~ ^harbor\.imcherry5778\.xyz/ci01-evidence/ci01-app@sha256:[0-9a-f]{64}$ ]] || {
  echo "pass build의 동적 image subject가 없다" >&2
  exit 1
}
[[ ${sbom_ref} =~ ^harbor\.imcherry5778\.xyz/ci01-evidence/ci01-app@sha256:[0-9a-f]{64}$ ]] || {
  echo "pass build의 동적 SBOM subject가 없다" >&2
  exit 1
}
image_digest=${image_ref##*@}
sbom_digest=${sbom_ref##*@}
for marker in \
  "sign01-image-verification=pass subject=${image_ref}" \
  "sign01-sbom-verification=pass subject=${sbom_ref}" \
  'sign01-release-handoff=ready case=pass'; do
  grep -Fq "${marker}" "${temp_dir}/pass-console.txt" || {
    echo "pass build marker가 없다: ${marker}" >&2
    exit 1
  }
done
image_signature_state=$(awk -v subject="${image_ref}" '
  $0 == "sign01-image-signature=attached subject=" subject {state="attached"}
  $0 == "sign01-image-signature=existing subject=" subject {state="existing"}
  END {print state}
' "${temp_dir}/pass-console.txt")
sbom_signature_state=$(awk -v subject="${sbom_ref}" '
  $0 == "sign01-sbom-signature=attached subject=" subject {state="attached"}
  $0 == "sign01-sbom-signature=existing subject=" subject {state="existing"}
  END {print state}
' "${temp_dir}/pass-console.txt")
[[ ${image_signature_state} =~ ^(attached|existing)$ && \
   ${sbom_signature_state} =~ ^(attached|existing)$ ]] || {
  echo "pass build의 signature 상태 marker가 없다" >&2
  exit 1
}
key_id=$(awk -F= '/^sign01-key-id=sha256:[0-9a-f]{64}$/ {print $2}' \
  "${temp_dir}/pass-console.txt" | tail -1)
[[ ${key_id} =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "SIGN-01 key id가 없다" >&2; exit 1; }
wait_for_no_agent

if [[ -n ${resume_reject_build} ]]; then
  [[ ${resume_reject_build} =~ ^[1-9][0-9]*$ ]] || {
    echo "SIGN01_RESUME_REJECT_BUILD는 양의 build 번호여야 한다" >&2
    exit 2
  }
  echo "SIGN-01 검증: case=reject resume-build=${resume_reject_build}"
  wait_build reject "${resume_reject_build}"
else
  trigger_build reject
  wait_build reject
fi
reject_build=${build_number}
[[ ${build_result} == FAILURE ]] || {
  echo "reject build ${reject_build} 결과가 FAILURE가 아니다: ${build_result}" >&2
  tail -n 80 "${temp_dir}/reject-console.txt" >&2
  exit 1
}
reject_ref=$(sed -n 's|^sign01-verification=reject subject=\(harbor\.imcherry5778\.xyz/ci01-evidence/ci01-app@sha256:[0-9a-f]\{64\}\) reason=untrusted-key$|\1|p' \
  "${temp_dir}/reject-console.txt" | tail -1)
if [[ ${reject_ref} =~ ^harbor\.imcherry5778\.xyz/ci01-evidence/ci01-app@sha256:[0-9a-f]{64}$ ]] &&
   grep -Fq "sign01-verification=reject subject=${reject_ref} reason=untrusted-key" \
     "${temp_dir}/reject-console.txt"; then
  rejection_evidence=marker
elif grep -Fq 'no matching attestations: failed to verify signature: could not verify envelope: accepted signatures do not match threshold, Found: 0, Expected 1' \
  "${temp_dir}/reject-console.txt"; then
  rejection_evidence=cosign-response
else
  echo "reject build가 다른 공개키에서 거부되지 않았다" >&2
  tail -n 80 "${temp_dir}/reject-console.txt" >&2
  exit 1
fi
for forbidden in 'sign01-release-handoff=ready' 'e2e01-release-handoff=ready'; do
  if grep -Fq "${forbidden}" "${temp_dir}/reject-console.txt"; then
    echo "reject build가 금지된 단계에 진입했다: ${forbidden}" >&2
    exit 1
  fi
done
wait_for_no_agent

echo "evidence_sign_verify=pass build=${pass_build} image-digest=${image_digest} image-signature=${image_signature_state} sbom-digest=${sbom_digest} sbom-signature=${sbom_signature_state} key-id=${key_id}"
echo "evidence_reject=pass build=${reject_build} reason=untrusted-key source=${rejection_evidence} release-handoff=absent"
echo "SIGN-01 완료 증거 2/2 통과 (pipeline 2회)"
