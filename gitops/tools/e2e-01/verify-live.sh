#!/usr/bin/env bash
# E2E-01 완료 증거 두 항목만 판정한다.
#   pipeline: pass build 한 번에서 signed/unsigned digest handoff를 얻는다.
#   admission: Argo가 만든 signed Pod Running과 unsigned Pod admission 거부·부재를 확인한다.
# shellcheck disable=SC2029,SC2329
set -Eeuo pipefail

mode=${1:-}
if [[ ${mode} != pipeline && ${mode} != admission ]]; then
  echo "사용법: $0 pipeline | admission <signed-digest> <unsigned-digest>" >&2
  exit 2
fi

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly repository=harbor.imcherry5778.xyz/ci01-evidence/ci01-app
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)
kube() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }

if [[ ${mode} == admission ]]; then
  readonly signed_digest=${2:-}
  readonly unsigned_digest=${3:-}
  [[ ${signed_digest} =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "signed digest 형식 오류" >&2; exit 2; }
  [[ ${unsigned_digest} =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "unsigned digest 형식 오류" >&2; exit 2; }
  [[ ${signed_digest} != "${unsigned_digest}" ]] || { echo "signed/unsigned digest가 같다" >&2; exit 1; }

  kube -n e2e-01 wait --for=condition=Ready pod/e2e-01-release --timeout=300s >/dev/null
  signed_state=$(kube -n e2e-01 get pod e2e-01-release -o json)
  jq -e --arg image "${repository}@${signed_digest}" '
    .status.phase == "Running" and
    ([.spec.containers[] | {name, image, imagePullPolicy, resources, securityContext}]) == [{
      name: "app",
      image: $image,
      imagePullPolicy: "IfNotPresent",
      resources: {
        limits: {cpu: "100m", memory: "32Mi"},
        requests: {cpu: "5m", memory: "8Mi"}
      },
      securityContext: {
        allowPrivilegeEscalation: false,
        capabilities: {drop: ["ALL"]},
        readOnlyRootFilesystem: true,
        runAsNonRoot: true,
        runAsUser: 65532
      }
    }] and
    ([.status.conditions[] | select(.type == "Ready" and .status == "True")] | length) == 1
  ' <<<"${signed_state}" >/dev/null
  echo "evidence_normal_artifact=pass image=${repository}@${signed_digest} pod=e2e-01-release phase=Running ready=True via=ArgoCD"

  if kube -n e2e-01 get pod e2e-01-unsigned >/dev/null 2>&1; then
    echo "negative test Pod가 admission 전에 이미 존재한다" >&2
    exit 1
  fi
  umask 077
  temp_dir=$(mktemp -d)
  readonly temp_dir
  cleanup() {
    local status=$?
    find "${temp_dir}" -type f -delete 2>/dev/null || true
    rmdir "${temp_dir}" 2>/dev/null || true
    return "${status}"
  }
  trap cleanup EXIT INT TERM
  negative_manifest=$(jq -n --arg image "${repository}@${unsigned_digest}" '{
    apiVersion: "v1",
    kind: "Pod",
    metadata: {
      name: "e2e-01-unsigned",
      namespace: "e2e-01",
      labels: {
        "app.kubernetes.io/name": "e2e-01",
        "app.kubernetes.io/component": "negative-evidence"
      }
    },
    spec: {
      automountServiceAccountToken: false,
      restartPolicy: "Never",
      imagePullSecrets: [{name: "e2e-01-registry"}],
      securityContext: {
        runAsNonRoot: true,
        runAsUser: 65532,
        runAsGroup: 65532,
        seccompProfile: {type: "RuntimeDefault"}
      },
      containers: [{
        name: "app",
        image: $image,
        imagePullPolicy: "IfNotPresent",
        securityContext: {
          runAsNonRoot: true,
          runAsUser: 65532,
          allowPrivilegeEscalation: false,
          readOnlyRootFilesystem: true,
          capabilities: {drop: ["ALL"]}
        },
        resources: {
          requests: {cpu: "5m", memory: "8Mi"},
          limits: {cpu: "100m", memory: "32Mi"}
        }
      }]
    }
  }')
  if printf '%s\n' "${negative_manifest}" | \
    ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} create -f -" \
      >"${temp_dir}/admission.out" 2>&1
  then
    echo "미서명 artifact Pod가 admission을 통과했다" >&2
    exit 1
  fi
  grep -Eq 'e2e-01-verify-release-image|verify-current-or-previous-cosign-key' \
    "${temp_dir}/admission.out" || {
    echo "거부 응답이 E2E-01 verifyImages policy를 가리키지 않는다" >&2
    sed -n '1,20p' "${temp_dir}/admission.out" >&2
    exit 1
  }
  grep -Eiq 'signature|signed|attestor|verify image|image verification' \
    "${temp_dir}/admission.out" || {
    echo "거부 응답이 signature 검증 실패를 가리키지 않는다" >&2
    sed -n '1,20p' "${temp_dir}/admission.out" >&2
    exit 1
  }
  if kube -n e2e-01 get pod e2e-01-unsigned >/dev/null 2>&1; then
    echo "거부된 Pod가 생성됐다" >&2
    exit 1
  fi
  echo "evidence_unsigned_artifact=pass image=${repository}@${unsigned_digest} admission=denied pod=absent policy=e2e-01-verify-release-image"
  echo "E2E-01 완료 증거 2/2 통과"
  exit 0
fi

readonly secret_root=${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}
readonly jenkins_env=${CI01_ENV_FILE:-${secret_root}/jenkins/env}
readonly jenkins_port=${E2E01_JENKINS_PORT:-33224}
readonly job_name=ci01-image-build
[[ -f ${jenkins_env} && ! -L ${jenkins_env} && $(stat -c %a "${jenkins_env}") == 600 ]] || {
  echo "credential 입력은 저장소 밖 mode 0600 일반 파일이어야 한다: ${jenkins_env}" >&2
  exit 1
}

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
jenkins_pid=
cleanup() {
  local status=$?
  [[ -n ${jenkins_pid} ]] && kill "${jenkins_pid}" 2>/dev/null || true
  find "${temp_dir}" -type f -delete 2>/dev/null || true
  rmdir "${temp_dir}" 2>/dev/null || true
  return "${status}"
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
  if [[ ${code} == 200 ]]; then tunnel_ready=true; break; fi
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

existing=$(kube -n jenkins get pods -l jenkins=slave -o "jsonpath='{.items[*].metadata.name}'")
[[ -z ${existing} ]] || { echo "이전 agent Pod가 남아 있다: ${existing}" >&2; exit 1; }
expected_build=$(jcurl --fail "${jenkins_api}/job/${job_name}/api/json?tree=nextBuildNumber" | jq -r '.nextBuildNumber')
queue_location=$(jcurl --fail --request POST --dump-header - --output /dev/null \
  --header "${crumb_field}: ${crumb_value}" \
  "${jenkins_api}/job/${job_name}/buildWithParameters?SCAN01_CASE=pass&SIGN01_CASE=pass" \
  | awk 'tolower($1) == "location:" {gsub(/\r/, "", $2); print $2}')
[[ -n ${queue_location} ]] || { echo "pass build 요청이 queue item을 반환하지 않았다" >&2; exit 1; }
queue_item=${queue_location%/}
queue_item=${queue_item##*/}
echo "E2E-01 pipeline: queue=${queue_item} expected-build=${expected_build}"

build_number=
for _ in $(seq 1 120); do
  jcurl --output "${temp_dir}/queue.json" "${jenkins_api}/queue/item/${queue_item}/api/json" || true
  build_number=$(jq -r '.executable.number // empty' "${temp_dir}/queue.json" 2>/dev/null || true)
  [[ -n ${build_number} ]] && break
  sleep 2
done
[[ ${build_number} == "${expected_build}" ]] || {
  echo "queue가 예상 build로 승격되지 않았다: expected=${expected_build} actual=${build_number:-none}" >&2
  exit 1
}

build_result=
for _ in $(seq 1 900); do
  jcurl --output "${temp_dir}/build.json" \
    "${jenkins_api}/job/${job_name}/${build_number}/api/json?tree=building,result" || true
  if [[ $(jq -r 'if .building == false then "finished" else "running" end' \
      "${temp_dir}/build.json" 2>/dev/null || true) == finished ]]; then
    build_result=$(jq -r '.result // empty' "${temp_dir}/build.json")
    break
  fi
  sleep 2
done
jcurl --fail --output "${temp_dir}/console.txt" \
  "${jenkins_api}/job/${job_name}/${build_number}/consoleText"
[[ ${build_result} == SUCCESS ]] || {
  echo "pass build ${build_number} 결과가 ${build_result:-unknown}다. 실패 지점:" >&2
  tail -n 100 "${temp_dir}/console.txt" >&2
  exit 1
}

for marker in \
  'e2e01-sonar-quality-gate=pass project=quality01-pass' \
  'scan01-config-gate=pass severity=HIGH,CRITICAL' \
  'scan01-vulnerability-gate=pass severity=HIGH,CRITICAL fixable-only=true' \
  'sign01-image-verification=pass subject=' \
  'sign01-sbom-verification=pass subject=' \
  'e2e01-release-handoff=ready signed-digest='; do
  grep -Fq "${marker}" "${temp_dir}/console.txt" || {
    echo "pipeline marker가 없다: ${marker}" >&2
    exit 1
  }
done

signed_digest=$(awk -F= '/^scan01-pushed-digest=sha256:/ {print $2}' "${temp_dir}/console.txt" | tail -1)
unsigned_digest=$(awk -F= '/^e2e01-unsigned-digest=sha256:/ {print $2}' "${temp_dir}/console.txt" | tail -1)
sbom_digest=$(awk -F= '/^scan01-sbom-artifact-digest=sha256:/ {print $2}' "${temp_dir}/console.txt" | tail -1)
for digest in "${signed_digest}" "${unsigned_digest}" "${sbom_digest}"; do
  [[ ${digest} =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "pipeline digest marker 형식 오류" >&2; exit 1; }
done
[[ ${signed_digest} != "${unsigned_digest}" ]] || { echo "변조 digest가 signed digest와 같다" >&2; exit 1; }

for _ in $(seq 1 60); do
  remaining=$(kube -n jenkins get pods -l jenkins=slave -o "jsonpath='{.items[*].metadata.name}'")
  [[ -z ${remaining} ]] && break
  sleep 2
done
[[ -z ${remaining} ]] || { echo "agent Pod 정리 timeout: ${remaining}" >&2; exit 1; }

echo "E2E01_PIPELINE_RESULT build=${build_number} signed-digest=${signed_digest} unsigned-digest=${unsigned_digest} sbom-digest=${sbom_digest}"
