#!/usr/bin/env bash
# shellcheck disable=SC2029
# SCAN-01 완료 증거를 pipeline 정확히 두 번으로 판정한다.
#   pass: config/image gate + CycloneDX OCI artifact
#   fail: fix가 있는 HIGH/CRITICAL에서 FAILURE, push/handoff 없음
set -Eeuo pipefail

readonly secret_root=${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}
readonly jenkins_env=${CI01_ENV_FILE:-${secret_root}/jenkins/env}
readonly harbor_env=${REG01_ENV_FILE:-${secret_root}/harbor/env}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly jenkins_port=${SCAN01_JENKINS_PORT:-33123}
readonly harbor_port=${SCAN01_HARBOR_PORT:-33122}
readonly job_name=ci01-image-build
readonly evidence_project=ci01-evidence
readonly evidence_repository=ci01-app
readonly db_bootstrap_job=trivy-db-bootstrap
readonly sbom_artifact_type=application/vnd.cyclonedx+json
readonly resume_pass_build=${SCAN01_RESUME_PASS_BUILD:-}
readonly resume_runtime_available=${SCAN01_RESUME_RUNTIME_AVAILABLE_MIB:-}

for private_input in "${jenkins_env}" "${harbor_env}"; do
  [[ -f ${private_input} && ! -L ${private_input} && $(stat -c %a "${private_input}") == 600 ]] || {
    echo "credential 입력은 저장소 밖 mode 0600 일반 파일이어야 한다: ${private_input}" >&2
    exit 1
  }
done

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
jenkins_pid=
harbor_pid=

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)
kube() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }

cleanup() {
  local status=$?
  [[ -n ${jenkins_pid} ]] && kill "${jenkins_pid}" 2>/dev/null || true
  [[ -n ${harbor_pid} ]] && kill "${harbor_pid}" 2>/dev/null || true
  rm -rf -- "${temp_dir}"
  return "${status}"
}
trap cleanup EXIT INT TERM

read_env_value() {
  awk -F= -v key="$2" '$1==key{print substr($0, index($0,"=")+1); exit}' "$1"
}

jenkins_admin_password=$(read_env_value "${jenkins_env}" JENKINS_ADMIN_PASSWORD)
harbor_admin_password=$(read_env_value "${harbor_env}" HARBOR_ADMIN_PASSWORD)
[[ -n ${jenkins_admin_password} && -n ${harbor_admin_password} ]] || {
  echo "admin 입력을 읽지 못했다" >&2
  exit 1
}

jenkins_curl=${temp_dir}/jenkins.curl
harbor_curl=${temp_dir}/harbor.curl
cookie_jar=${temp_dir}/cookies
printf 'user = "admin:%s"\ncookie = "%s"\ncookie-jar = "%s"\nsilent\nshow-error\n' \
  "${jenkins_admin_password}" "${cookie_jar}" "${cookie_jar}" >"${jenkins_curl}"
printf 'user = "admin:%s"\nsilent\nshow-error\n' "${harbor_admin_password}" >"${harbor_curl}"
unset jenkins_admin_password harbor_admin_password

start_tunnel() {
  local name=$1 namespace=$2 service=$3 remote_port=$4 local_port=$5 probe=$6 expect=$7
  local target_ip pid code

  python3 - "${local_port}" <<'PY'
import socket
import sys

sock = socket.socket()
try:
    sock.bind(("127.0.0.1", int(sys.argv[1])))
finally:
    sock.close()
PY

  target_ip=$(kube -n "${namespace}" get service "${service}" -o "jsonpath='{.spec.clusterIP}'")
  [[ ${target_ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    echo "${name} Service ClusterIP를 판정하지 못했다" >&2
    exit 1
  }
  ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
    -L "${local_port}:${target_ip}:${remote_port}" "${k3s_host}" \
    >"${temp_dir}/${name}-tunnel.log" 2>&1 &
  pid=$!
  for _ in $(seq 1 60); do
    kill -0 "${pid}" 2>/dev/null || break
    code=$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 5 \
      "http://127.0.0.1:${local_port}${probe}" || true)
    if [[ ${code} == "${expect}" ]]; then
      printf '%s' "${pid}"
      return 0
    fi
    sleep 2
  done
  echo "${name} tunnel health timeout" >&2
  sed -n '1,40p' "${temp_dir}/${name}-tunnel.log" >&2
  exit 1
}

jenkins_pid=$(start_tunnel jenkins jenkins jenkins 8080 "${jenkins_port}" /login 200)
harbor_pid=$(start_tunnel harbor harbor harbor 80 "${harbor_port}" /api/v2.0/ping 200)
readonly jenkins_api=http://127.0.0.1:${jenkins_port}
readonly harbor_api=http://127.0.0.1:${harbor_port}/api/v2.0
jcurl() { curl --config "${jenkins_curl}" "$@"; }

jcurl --fail --output "${temp_dir}/crumb.json" "${jenkins_api}/crumbIssuer/api/json" || {
  echo "Jenkins crumb 발급 실패" >&2
  exit 1
}
crumb_field=$(jq -r '.crumbRequestField' "${temp_dir}/crumb.json")
crumb_value=$(jq -r '.crumb' "${temp_dir}/crumb.json")
echo "SCAN-01 검증: jenkins-auth=ok"

# 선언형 bootstrap Job이 PVC를 bind하고 DB와 checks bundle을 한 번 준비했는지 확인한다.
db_state=
for _ in $(seq 1 300); do
  kube -n jenkins get job "${db_bootstrap_job}" -o json >"${temp_dir}/db-job.json"
  succeeded=$(jq -r '.status.succeeded // 0' "${temp_dir}/db-job.json")
  failed=$(jq -r '.status.failed // 0' "${temp_dir}/db-job.json")
  active=$(jq -r '.status.active // 0' "${temp_dir}/db-job.json")
  if [[ ${succeeded} -ge 1 ]]; then
    db_state=success
    break
  fi
  if [[ ${failed} -ge 1 && ${active} -eq 0 ]]; then
    db_state=failure
    break
  fi
  sleep 2
done
kube -n jenkins logs "job/${db_bootstrap_job}" >"${temp_dir}/db-update.log" 2>&1 || true
if [[ ${db_state} != success ]] || ! grep -q '^scan01-db-update=pass$' "${temp_dir}/db-update.log"; then
  echo "Trivy DB updater 실패 지점:" >&2
  tail -n 60 "${temp_dir}/db-update.log" >&2
  exit 1
fi
echo "SCAN-01 검증: trivy-db-update=pass"

existing=$(kube -n jenkins get pods -l jenkins=slave -o "jsonpath='{.items[*].metadata.name}'")
[[ -z ${existing} ]] || { echo "이전 agent Pod가 남아 있다: ${existing}" >&2; exit 1; }

trigger_build() {
  local scan_case=$1 queue_location
  expected_build=$(jcurl --fail \
    "${jenkins_api}/job/${job_name}/api/json?tree=nextBuildNumber" | jq -r '.nextBuildNumber')
  queue_location=$(jcurl --fail --request POST --dump-header - --output /dev/null \
    --header "${crumb_field}: ${crumb_value}" \
    "${jenkins_api}/job/${job_name}/buildWithParameters?SCAN01_CASE=${scan_case}" \
    | awk 'tolower($1) == "location:" {gsub(/\r/, "", $2); print $2}')
  [[ -n ${queue_location} ]] || { echo "${scan_case} build 요청이 queue item을 반환하지 않았다" >&2; exit 1; }
  queue_item=${queue_location%/}
  queue_item=${queue_item##*/}
  echo "SCAN-01 검증: case=${scan_case} queue=${queue_item} expected-build=${expected_build}"
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

capture_runtime_capacity() {
  local agent_name phase
  agent_name=
  for _ in $(seq 1 180); do
    kube -n jenkins get pods -l jenkins=slave -o json >"${temp_dir}/agents.json" 2>/dev/null || true
    agent_name=$(jq -r '.items[0].metadata.name // empty' "${temp_dir}/agents.json")
    phase=$(jq -r '.items[0].status.phase // empty' "${temp_dir}/agents.json")
    [[ -n ${agent_name} && ${phase} == Running ]] && break
    sleep 1
  done
  [[ -n ${agent_name} && ${phase} == Running ]] || {
    echo "pass build의 agent Pod를 실행 중에 잡지 못했다" >&2
    exit 1
  }
  runtime_available=$(ssh "${ssh_options[@]}" "${k3s_host}" free -m | awk '/Mem:/ {print $7}')
  echo "scan01-runtime-agent-pod=${agent_name}"
  echo "scan01-runtime-k3s-available-mib=${runtime_available}"
  kube -n jenkins top pod "${agent_name}" --containers >"${temp_dir}/runtime-top.txt" 2>&1 || true
  sed -n '1,20p' "${temp_dir}/runtime-top.txt"
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

# ---------------------------------------------------------------- pass build: 기준 + SBOM 저장
if [[ -n ${resume_pass_build} ]]; then
  [[ ${resume_pass_build} =~ ^[0-9]+$ && ${resume_runtime_available} =~ ^[0-9]+$ ]] || {
    echo "pass 재개 입력은 숫자 build 번호와 runtime available MiB가 모두 필요하다" >&2
    exit 1
  }
  runtime_available=${resume_runtime_available}
  echo "SCAN-01 검증: case=pass resume-build=${resume_pass_build}"
  wait_build pass "${resume_pass_build}"
else
  trigger_build pass
  capture_runtime_capacity
  wait_build pass
fi
if [[ ${build_result} != SUCCESS ]]; then
  echo "pass build ${build_number} 결과가 ${build_result}다. 실패 지점:" >&2
  tail -n 80 "${temp_dir}/pass-console.txt" >&2
  exit 1
fi
for marker in \
  'scan01-config-gate=pass severity=HIGH,CRITICAL' \
  'scan01-vulnerability-gate=pass severity=HIGH,CRITICAL fixable-only=true' \
  'scan01-sbom-format=cyclonedx-json' \
  'scan01-release-handoff=ready case=pass'; do
  grep -Fq "${marker}" "${temp_dir}/pass-console.txt" || {
    echo "pass build marker가 없다: ${marker}" >&2
    exit 1
  }
done
[[ ${runtime_available} =~ ^[0-9]+$ && ${runtime_available} -ge 8192 ]] || {
  echo "SCAN-01 runtime capacity stop: k3s available memory < 8 GiB" >&2
  exit 1
}

pass_image=$(awk -F= '/^scan01-pushed-image=/{print $2}' "${temp_dir}/pass-console.txt" | tail -1)
pass_digest=$(awk -F= '/^scan01-pushed-digest=/{print $2}' "${temp_dir}/pass-console.txt" | tail -1)
sbom_digest=$(awk -F= '/^scan01-sbom-artifact-digest=/{print $2}' "${temp_dir}/pass-console.txt" | tail -1)
[[ ${pass_digest} =~ ^sha256:[0-9a-f]{64}$ && ${sbom_digest} =~ ^sha256:[0-9a-f]{64}$ ]] || {
  echo "pass build의 image/SBOM digest 형식이 잘못됐다" >&2
  exit 1
}
pass_tag=${pass_image##*:}
artifact_status=$(curl --config "${harbor_curl}" --output "${temp_dir}/pass-artifact.json" \
  --write-out '%{http_code}' \
  "${harbor_api}/projects/${evidence_project}/repositories/${evidence_repository}/artifacts/${pass_tag}")
[[ ${artifact_status} == 200 ]] || { echo "pass image를 Harbor에서 찾지 못했다" >&2; exit 1; }
harbor_image_digest=$(jq -r '.digest' "${temp_dir}/pass-artifact.json")
[[ ${harbor_image_digest} == "${pass_digest}" ]] || {
  echo "Harbor image digest와 pipeline 출력이 다르다" >&2
  exit 1
}
curl --config "${harbor_curl}" --fail --output "${temp_dir}/accessories.json" \
  "${harbor_api}/projects/${evidence_project}/repositories/${evidence_repository}/artifacts/${pass_tag}/accessories?page_size=100"
accessory_count=$(jq -r --arg digest "${sbom_digest}" \
  '[.[] | select(.digest == $digest and .type == "subject.accessory")] | length' \
  "${temp_dir}/accessories.json")
[[ ${accessory_count} == 1 ]] || {
  echo "CycloneDX accessory가 image digest에 정확히 하나 연결되지 않았다" >&2
  exit 1
}
sbom_status=$(curl --config "${harbor_curl}" --output "${temp_dir}/sbom-artifact.json" \
  --write-out '%{http_code}' \
  "${harbor_api}/projects/${evidence_project}/repositories/${evidence_repository}/artifacts/${sbom_digest}")
harbor_sbom_digest=$(jq -r '.digest // empty' "${temp_dir}/sbom-artifact.json")
harbor_sbom_type=$(jq -r '.artifact_type // empty' "${temp_dir}/sbom-artifact.json")
[[ ${sbom_status} == 200 && ${harbor_sbom_digest} == "${sbom_digest}" && \
   ${harbor_sbom_type} == "${sbom_artifact_type}" ]] || {
  echo "연결된 SBOM artifact의 digest 또는 artifact_type이 다르다" >&2
  exit 1
}
echo "evidence_vulnerability_policy=pass build=${build_number} severity=HIGH,CRITICAL fixable-only=true"
echo "evidence_sbom_storage=pass image-digest=${pass_digest} sbom-digest=${sbom_digest} type=${sbom_artifact_type}"
wait_for_no_agent

# ---------------------------------------------------------------- fail build: push/handoff 전에 FAILURE
trigger_build fail
wait_build fail
if [[ ${build_result} != FAILURE ]]; then
  echo "fail build ${build_number} 결과가 FAILURE가 아니다: ${build_result}" >&2
  tail -n 80 "${temp_dir}/fail-console.txt" >&2
  exit 1
fi
grep -Fq 'scan01-vulnerability-gate=fail severity=HIGH,CRITICAL fixable-only=true' \
  "${temp_dir}/fail-console.txt" || {
  echo "fail build가 취약점 gate에서 실패하지 않았다" >&2
  exit 1
}
for forbidden in 'scan01-stage=push-start' 'scan01-pushed-image=' 'scan01-release-handoff=ready'; do
  if grep -Fq "${forbidden}" "${temp_dir}/fail-console.txt"; then
    echo "fail build가 금지된 후속 단계에 진입했다: ${forbidden}" >&2
    exit 1
  fi
done
fail_tag=scan-b${build_number}
fail_status=$(curl --config "${harbor_curl}" --output "${temp_dir}/fail-artifact.json" \
  --write-out '%{http_code}' \
  "${harbor_api}/projects/${evidence_project}/repositories/${evidence_repository}/artifacts/${fail_tag}")
[[ ${fail_status} == 404 ]] || {
  echo "fail build tag가 Harbor에 존재한다: HTTP ${fail_status}" >&2
  exit 1
}
echo "evidence_failure_pipeline=pass build=${build_number} result=FAILURE push=absent release-handoff=absent"
wait_for_no_agent

echo "SCAN-01 완료 증거 3/3 통과 (pipeline 2회)"
