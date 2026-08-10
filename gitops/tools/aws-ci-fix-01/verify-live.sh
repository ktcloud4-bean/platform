#!/usr/bin/env bash
# AWS-CI-FIX-01의 완료 증거만 판정한다.
# - immutable SHA의 platform-root/Jenkins Synced·Healthy
# - 허용 root 두 개의 Jenkins OpenTofu plan build SUCCESS
# - console에 plan 결과만 있고 Vault runtime의 이 pipeline 입력 원문이 0건
set -Eeuo pipefail

readonly expected_root_revision=${AWS_CI_FIX_01_EXPECTED_ROOT_REVISION:?root pointer SHA가 필요하다}
readonly expected_config_revision=${AWS_CI_FIX_01_EXPECTED_CONFIG_REVISION:?Jenkins 설정 SHA가 필요하다}
readonly secret_root=${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}
readonly jenkins_env=${CI01_ENV_FILE:-${secret_root}/jenkins/env}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly jenkins_port=${AWS_CI_FIX_01_JENKINS_PORT:-33029}
readonly job_name=aws-opentofu-pipeline
readonly allowed_roots=(tofu-app-network tofu-app-ecr)

[[ ${expected_root_revision} =~ ^[0-9a-f]{40}$ &&
   ${expected_config_revision} =~ ^[0-9a-f]{40}$ ]] || {
  echo 'AWS-CI-FIX-01 검증 실패 단계=argo 원인=immutable SHA 형식이 아니다.' >&2
  exit 1
}
for private_input in "${jenkins_env}" "${vault_root_token_file}"; do
  [[ -f ${private_input} && ! -L ${private_input} && $(stat -c %a "${private_input}") == 600 ]] || {
    echo "AWS-CI-FIX-01 검증 실패 단계=preflight 원인=credential 입력이 mode 0600 일반 파일이 아니다." >&2
    exit 1
  }
done
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'AWS-CI-FIX-01 검증 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

if [[ ${AWS_CI_FIX_01_ARGO_LOCK_HELD:-false} != true ]]; then
  exec 9>/tmp/ktcloud4-bean-argo-root.lock
  flock -n 9 || {
    echo 'AWS-CI-FIX-01 검증 실패 단계=lock 원인=다른 ARGO-ROOT 작업이 실행 중이다.' >&2
    exit 1
  }
fi

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)
kube() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
jenkins_pid=
cleanup() {
  local status=$?
  [[ -n ${jenkins_pid} ]] && kill "${jenkins_pid}" 2>/dev/null || true
  rm -rf -- "${temp_dir}"
  return "${status}"
}
trap cleanup EXIT INT TERM

read_env_value() {
  awk -F= -v key="$2" '$1==key{print substr($0, index($0,"=")+1); exit}' "$1"
}

jenkins_admin_password=$(read_env_value "${jenkins_env}" JENKINS_ADMIN_PASSWORD)
[[ -n ${jenkins_admin_password} ]] || {
  echo 'AWS-CI-FIX-01 검증 실패 단계=jenkins-auth 원인=admin 입력을 읽지 못했다.' >&2
  exit 1
}
readonly jenkins_curl=${temp_dir}/jenkins.curl
readonly cookie_jar=${temp_dir}/cookies
printf 'user = "admin:%s"\ncookie = "%s"\ncookie-jar = "%s"\nsilent\nshow-error\n' \
  "${jenkins_admin_password}" "${cookie_jar}" "${cookie_jar}" >"${jenkins_curl}"
unset jenkins_admin_password
jcurl() { curl --config "${jenkins_curl}" "$@"; }

# Jenkins에 전달되는 세 입력의 원문은 Vault에서만 읽어 console 검사에 사용하고 출력하지 않는다.
{
  tr -d '\n' <"${vault_root_token_file}"
  printf '\n'
  printf 'vault kv get -format=json kv/jenkins/runtime\n'
} | ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n vault exec -i vault-0 -- sh -c '
    set -eu
    read -r VAULT_TOKEN
    export VAULT_TOKEN
    exec sh -eu
  '" >"${temp_dir}/runtime.json"
jq -e '.data.data.aws_access_key_id | strings | length > 0' "${temp_dir}/runtime.json" >/dev/null
jq -e '.data.data.aws_secret_access_key | strings | length > 0' "${temp_dir}/runtime.json" >/dev/null
jq -e '.data.data.github_platform_ssh_private_key | strings | length > 0' "${temp_dir}/runtime.json" >/dev/null

argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(kube -n argocd get applications.argoproj.io platform-root jenkins -o json 2>/dev/null || true)
  if jq -e --arg root "${expected_root_revision}" --arg jenkins "${expected_config_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "jenkins")][0] // {}) as $jenkins_app |
    $root_app.spec.source.targetRevision == $root and
    $root_app.status.sync.revision == $root and
    $root_app.status.sync.status == "Synced" and
    $root_app.status.health.status == "Healthy" and
    $jenkins_app.spec.source.targetRevision == $jenkins and
    $jenkins_app.status.sync.revision == $jenkins and
    $jenkins_app.status.sync.status == "Synced" and
    $jenkins_app.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e --arg root "${expected_root_revision}" --arg jenkins "${expected_config_revision}" '
  ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
  ([.items[] | select(.metadata.name == "jenkins")][0] // {}) as $jenkins_app |
  $root_app.spec.source.targetRevision == $root and
  $root_app.status.sync.revision == $root and
  $root_app.status.sync.status == "Synced" and
  $root_app.status.health.status == "Healthy" and
  $jenkins_app.spec.source.targetRevision == $jenkins and
  $jenkins_app.status.sync.revision == $jenkins and
  $jenkins_app.status.sync.status == "Synced" and
  $jenkins_app.status.health.status == "Healthy"
' <<<"${argo_state}" >/dev/null || {
  echo 'AWS-CI-FIX-01 검증 실패 단계=argo 원인=platform-root/Jenkins가 immutable SHA에서 Synced/Healthy가 아니다.' >&2
  exit 1
}
echo 'AWS-CI-FIX-01 Argo=PASS platform-root=Synced/Healthy jenkins=Synced/Healthy'

if ss -ltn "sport = :${jenkins_port}" | grep -q LISTEN; then
  echo "AWS-CI-FIX-01 검증 실패 단계=tunnel 원인=local port ${jenkins_port}가 사용 중이다." >&2
  exit 1
fi
jenkins_ip=$(kube -n jenkins get service jenkins -o "jsonpath='{.spec.clusterIP}'")
[[ ${jenkins_ip} =~ ^10\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo 'AWS-CI-FIX-01 검증 실패 단계=tunnel 원인=Jenkins Service ClusterIP를 읽지 못했다.' >&2
  exit 1
}
ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
  -L "${jenkins_port}:${jenkins_ip}:8080" "${k3s_host}" >"${temp_dir}/jenkins-tunnel.log" 2>&1 &
jenkins_pid=$!
for _ in $(seq 1 60); do
  kill -0 "${jenkins_pid}" 2>/dev/null || break
  if curl --silent --output /dev/null --max-time 5 "http://127.0.0.1:${jenkins_port}/login"; then
    break
  fi
  sleep 2
done
kill -0 "${jenkins_pid}" 2>/dev/null || {
  echo 'AWS-CI-FIX-01 검증 실패 단계=tunnel 원인=Jenkins SSH tunnel이 종료됐다.' >&2
  exit 1
}
readonly jenkins_api=http://127.0.0.1:${jenkins_port}
jcurl --fail --output "${temp_dir}/crumb.json" "${jenkins_api}/crumbIssuer/api/json" || {
  echo 'AWS-CI-FIX-01 검증 실패 단계=jenkins-auth 원인=crumb 발급이 실패했다.' >&2
  exit 1
}
crumb_field=$(jq -r '.crumbRequestField' "${temp_dir}/crumb.json")
crumb_value=$(jq -r '.crumb' "${temp_dir}/crumb.json")

existing=$(kube -n jenkins get pods -l jenkins=slave -o "jsonpath='{.items[*].metadata.name}'")
[[ -z ${existing} ]] || {
  echo 'AWS-CI-FIX-01 검증 실패 단계=agent 원인=이전 Jenkins agent Pod가 남아 있다.' >&2
  exit 1
}

trigger_and_assert() {
  local root=$1 queue_location queue_item build_number='' build_result='' build_state
  queue_location=$(jcurl --fail --request POST --dump-header - --output /dev/null \
    --header "${crumb_field}: ${crumb_value}" \
    --data-urlencode "TARGET_ROOT=${root}" \
    --data-urlencode "GIT_REVISION=${expected_config_revision}" \
    "${jenkins_api}/job/${job_name}/buildWithParameters" \
    | awk 'tolower($1) == "location:" {gsub(/\r/, "", $2); print $2}')
  [[ -n ${queue_location} ]] || {
    echo "AWS-CI-FIX-01 검증 실패 단계=trigger root=${root} 원인=queue item이 없다." >&2
    return 1
  }
  queue_item=${queue_location%/}
  queue_item=${queue_item##*/}
  for _ in $(seq 1 180); do
    jcurl --output "${temp_dir}/queue-${root}.json" \
      "${jenkins_api}/queue/item/${queue_item}/api/json" || true
    build_number=$(jq -r '.executable.number // empty' "${temp_dir}/queue-${root}.json" 2>/dev/null || true)
    [[ -n ${build_number} ]] && break
    sleep 2
  done
  [[ -n ${build_number} ]] || {
    echo "AWS-CI-FIX-01 검증 실패 단계=queue root=${root} 원인=build로 승격되지 않았다." >&2
    return 1
  }
  for _ in $(seq 1 450); do
    jcurl --output "${temp_dir}/build-${root}.json" \
      "${jenkins_api}/job/${job_name}/${build_number}/api/json?tree=building,result" || true
    build_state=$(jq -r 'if .building == false then "finished" else "running" end' \
      "${temp_dir}/build-${root}.json" 2>/dev/null || true)
    if [[ ${build_state} == finished ]]; then
      build_result=$(jq -r '.result // empty' "${temp_dir}/build-${root}.json")
      break
    fi
    sleep 2
  done
  jcurl --fail --output "${temp_dir}/console-${root}.txt" \
    "${jenkins_api}/job/${job_name}/${build_number}/consoleText"
  [[ ${build_result} == SUCCESS ]] || {
    echo "AWS-CI-FIX-01 검증 실패 단계=build root=${root} build=${build_number} result=${build_result:-미완료}" >&2
    return 1
  }
  rg -F "AWS-CI-FIX-01 Plan=PASS root=${root}" "${temp_dir}/console-${root}.txt" >/dev/null || {
    echo "AWS-CI-FIX-01 검증 실패 단계=plan root=${root} build=${build_number} 원인=plan 성공 요약이 없다." >&2
    return 1
  }
  if rg -i '\btofu\s+apply\b|\bterraform\s+apply\b' "${temp_dir}/console-${root}.txt" >/dev/null; then
    echo "AWS-CI-FIX-01 검증 실패 단계=plan root=${root} build=${build_number} 원인=apply 실행 흔적이 있다." >&2
    return 1
  fi
  BUILD_CONSOLE="${temp_dir}/console-${root}.txt" RUNTIME_JSON="${temp_dir}/runtime.json" python3 - <<'PY'
import json
import os
import pathlib

console = pathlib.Path(os.environ["BUILD_CONSOLE"]).read_text(encoding="utf-8", errors="replace")
runtime = json.loads(pathlib.Path(os.environ["RUNTIME_JSON"]).read_text(encoding="utf-8"))["data"]["data"]
values = [
    runtime["aws_access_key_id"],
    runtime["aws_secret_access_key"],
    runtime["github_platform_ssh_private_key"],
]
hits = sum(console.count(value) for value in values if value)
if hits:
    raise SystemExit("민감값이 Jenkins console에 남았다")
PY
  echo "AWS-CI-FIX-01 Build=SUCCESS root=${root} build=${build_number} plan-only=true sensitive-hits=0"
}

for root in "${allowed_roots[@]}"; do
  trigger_and_assert "${root}"
done
