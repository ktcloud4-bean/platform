#!/usr/bin/env bash
# BOARD-DEMO-01 Jenkins source build 1회의 완료 증거만 판정한다.
# shellcheck disable=SC2029
set -Eeuo pipefail

readonly expected_source_sha=${BOARD_DEMO_EXPECTED_SOURCE_SHA:?GitHub/Gitea main SHA가 필요하다}
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly jenkins_env=${CI01_ENV_FILE:-$secret_root/jenkins/env}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-$secret_root/vault-root.token}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly jenkins_port=${BOARD_DEMO_JENKINS_PORT:-33127}
readonly job_name=board-demo-image-build

[[ $expected_source_sha =~ ^[0-9a-f]{40}$ ]] || {
  echo "BOARD-DEMO-01 pipeline: expected source SHA 형식이 올바르지 않다." >&2
  exit 1
}
for input in "$jenkins_env" "$vault_root_token_file"; do
  [[ -f $input && ! -L $input && $(stat -c %a "$input") == 600 ]] || {
    echo "BOARD-DEMO-01 pipeline: credential 입력은 mode 0600 일반 파일이어야 한다." >&2
    exit 1
  }
done

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$known_hosts"
  -o PasswordAuthentication=no
)

kube() {
  ssh "${ssh_options[@]}" "$k3s_host" "$kubectl_command $*"
}

vault_exec() {
  {
    tr -d '\n' <"$vault_root_token_file"
    printf '\n'
    cat
  } | ssh "${ssh_options[@]}" "$k3s_host" \
    "$kubectl_command -n vault exec -i vault-0 -- sh -c '
      set -eu
      read -r VAULT_TOKEN
      export VAULT_TOKEN
      exec sh -eu
    '"
}

read_env_value() {
  awk -F= -v key="$2" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$1"
}

jenkins_admin_password=$(read_env_value "$jenkins_env" JENKINS_ADMIN_PASSWORD)
[[ -n $jenkins_admin_password ]] || {
  echo "BOARD-DEMO-01 pipeline: Jenkins admin 입력을 읽지 못했다." >&2
  exit 1
}

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
jenkins_pid=
cleanup() {
  local status=$?
  [[ -n $jenkins_pid ]] && kill "$jenkins_pid" 2>/dev/null || true
  find "$temp_dir" -type f -delete 2>/dev/null || true
  rmdir "$temp_dir" 2>/dev/null || true
  unset jenkins_admin_password
  return "$status"
}
trap cleanup EXIT INT TERM

jenkins_curl=$temp_dir/jenkins.curl
cookie_jar=$temp_dir/cookies
printf 'user = "admin:%s"\ncookie = "%s"\ncookie-jar = "%s"\nsilent\nshow-error\n' \
  "$jenkins_admin_password" "$cookie_jar" "$cookie_jar" >"$jenkins_curl"
unset jenkins_admin_password
jcurl() { curl --config "$jenkins_curl" "$@"; }

jenkins_ip=$(kube -n jenkins get service jenkins -o "jsonpath='{.spec.clusterIP}'")
[[ $jenkins_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
  echo "BOARD-DEMO-01 pipeline: Jenkins Service ClusterIP를 판정하지 못했다." >&2
  exit 1
}
ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
  -L "$jenkins_port:$jenkins_ip:8080" "$k3s_host" >"$temp_dir/jenkins-tunnel.log" 2>&1 &
jenkins_pid=$!
for _ in $(seq 1 45); do
  kill -0 "$jenkins_pid" 2>/dev/null || break
  if curl --silent --show-error --fail --max-time 5 \
    "http://127.0.0.1:$jenkins_port/login" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done
kill -0 "$jenkins_pid" 2>/dev/null || {
  echo "BOARD-DEMO-01 pipeline: Jenkins tunnel이 종료됐다." >&2
  exit 1
}
readonly jenkins_api=http://127.0.0.1:$jenkins_port

jcurl --fail --output "$temp_dir/crumb.json" "$jenkins_api/crumbIssuer/api/json" || {
  echo "BOARD-DEMO-01 pipeline: Jenkins crumb 발급 실패" >&2
  exit 1
}
crumb_field=$(jq -er '.crumbRequestField' "$temp_dir/crumb.json")
crumb_value=$(jq -er '.crumb' "$temp_dir/crumb.json")

job_status=
for _ in $(seq 1 60); do
  job_status=$(jcurl --output "$temp_dir/job.json" --write-out '%{http_code}' \
    "$jenkins_api/job/$job_name/api/json?tree=name,nextBuildNumber" || true)
  [[ $job_status == 200 ]] && break
  [[ $job_status == 404 ]] || {
    echo "BOARD-DEMO-01 pipeline: Jenkins job 조회 HTTP $job_status" >&2
    exit 1
  }
  sleep 2
done
[[ $job_status == 200 ]] || {
  echo "BOARD-DEMO-01 pipeline: Jenkins job DSL 등록이 120초 안에 끝나지 않았다." >&2
  exit 1
}
jq -e --arg job "$job_name" '.name == $job' "$temp_dir/job.json" >/dev/null
queue_location=$(jcurl --fail --request POST --dump-header - --output /dev/null \
  --header "$crumb_field: $crumb_value" "$jenkins_api/job/$job_name/build" \
  | awk 'tolower($1) == "location:" {gsub(/\r/, "", $2); print $2}')
[[ -n $queue_location ]] || {
  echo "BOARD-DEMO-01 pipeline: build queue item이 없다." >&2
  exit 1
}
queue_item=${queue_location%/}
queue_item=${queue_item##*/}

build_number=
for _ in $(seq 1 180); do
  jcurl --output "$temp_dir/queue.json" "$jenkins_api/queue/item/$queue_item/api/json" || true
  build_number=$(jq -r '.executable.number // empty' "$temp_dir/queue.json" 2>/dev/null || true)
  [[ -n $build_number ]] && break
  sleep 2
done
[[ -n $build_number ]] || {
  echo "BOARD-DEMO-01 pipeline: queue가 build로 승격되지 않았다." >&2
  exit 1
}

build_result=
for _ in $(seq 1 450); do
  jcurl --output "$temp_dir/build.json" \
    "$jenkins_api/job/$job_name/$build_number/api/json?tree=building,result" || true
  build_state=$(jq -r 'if .building == false then "finished" else "running" end' \
    "$temp_dir/build.json" 2>/dev/null || true)
  if [[ $build_state == finished ]]; then
    build_result=$(jq -r '.result // empty' "$temp_dir/build.json")
    break
  fi
  sleep 2
done
jcurl --fail --output "$temp_dir/console.txt" "$jenkins_api/job/$job_name/$build_number/consoleText"
[[ $build_result == SUCCESS ]] || {
  echo "BOARD-DEMO-01 pipeline: build=$build_number result=${build_result:-미완료}" >&2
  exit 1
}

source_sha=$(awk -F= '/^board-demo-source-sha=/{print $2}' "$temp_dir/console.txt" | tail -1)
image_digest=$(awk -F= '/^board-demo-pushed-digest=/{print $2}' "$temp_dir/console.txt" | tail -1)
unsigned_digest=$(awk -F= '/^board-demo-unsigned-digest=/{print $2}' "$temp_dir/console.txt" | tail -1)
sbom_digest=$(awk -F= '/^board-demo-sbom-artifact-digest=/{print $2}' "$temp_dir/console.txt" | tail -1)
[[ $source_sha == "$expected_source_sha" ]] || {
  echo "BOARD-DEMO-01 pipeline: source SHA가 mirror와 다르다." >&2
  exit 1
}
for digest in "$image_digest" "$unsigned_digest" "$sbom_digest"; do
  [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || {
    echo "BOARD-DEMO-01 pipeline: digest 형식이 올바르지 않다." >&2
    exit 1
  }
done
rg -F 'board-demo-vulnerability-gate=pass severity=HIGH,CRITICAL fixable-only=true' "$temp_dir/console.txt" >/dev/null
rg -F 'board-demo-signature=verified' "$temp_dir/console.txt" >/dev/null
rg -F "board-demo-release-handoff=ready source-sha=$expected_source_sha signed-digest=$image_digest unsigned-digest=$unsigned_digest sbom-digest=$sbom_digest" "$temp_dir/console.txt" >/dev/null

vault_exec <<'REMOTE' >"$temp_dir/harbor-robot-secret"
vault kv get -field=harbor_robot_secret kv/board-demo/jenkins
REMOTE
vault_exec <<'REMOTE' >"$temp_dir/gitea-private-key"
vault kv get -field=gitea_ssh_private_key kv/board-demo/jenkins
REMOTE
printf '\n' >>"$temp_dir/gitea-private-key"
python3 - "$temp_dir" <<'PY'
import pathlib
import sys

base = pathlib.Path(sys.argv[1])
console = (base / "console.txt").read_text(encoding="utf-8", errors="replace")
robot = (base / "harbor-robot-secret").read_text(encoding="utf-8").strip()
key = (base / "gitea-private-key").read_text(encoding="utf-8", errors="replace")
key_body = "".join(line for line in key.splitlines() if line and not line.startswith("-----"))
needles = [robot, key_body[:40] if len(key_body) >= 40 else ""]
if any(needle and needle in console for needle in needles):
    raise SystemExit("BOARD-DEMO-01 pipeline: Jenkins console에 credential 원문이 남았다")
PY

echo "BOARD-DEMO-01 pipeline 검증 통과: build=$build_number source-sha=$source_sha signed-digest=$image_digest unsigned-digest=$unsigned_digest sbom-digest=$sbom_digest sensitive-hits=0"
