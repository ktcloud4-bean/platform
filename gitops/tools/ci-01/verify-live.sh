#!/usr/bin/env bash
# shellcheck disable=SC2029
# CI-01 완료 증거를 pipeline 한 번의 실행으로 판정한다.
#   1) 비밀 마스킹   콘솔 로그와 controller/agent Pod 로그의 credential 원문 0건
#   2) 비특권 agent  라이브 agent Pod spec 한 번 조회
#   3) build/push    Gitea clone -> buildah build -> 지정 project push 성공 / 미지정 거부
# 완료 증거 표에 없는 항목은 판정하지 않는다.
set -Eeuo pipefail

readonly secret_root=${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}
readonly jenkins_env=${CI01_ENV_FILE:-${secret_root}/jenkins/env}
readonly harbor_env=${REG01_ENV_FILE:-${secret_root}/harbor/env}
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-${secret_root}/vault-root.token}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly jenkins_port=${CI01_JENKINS_PORT:-33023}
readonly harbor_port=${CI01_HARBOR_PORT:-33022}
readonly job_name=ci01-image-build
readonly evidence_project=ci01-evidence
readonly denied_project=ci01-denied

for private_input in "${jenkins_env}" "${harbor_env}" "${vault_root_token_file}"; do
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
log_pids=()

cleanup() {
  local status=$?
  local pid
  for pid in "${log_pids[@]+"${log_pids[@]}"}"; do kill "${pid}" 2>/dev/null || true; done
  [[ -n ${jenkins_pid} ]] && kill "${jenkins_pid}" 2>/dev/null
  [[ -n ${harbor_pid} ]] && kill "${harbor_pid}" 2>/dev/null
  rm -rf -- "${temp_dir}"
  return "${status}"
}
trap cleanup EXIT INT TERM

readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)
kube() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }

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

# 마스킹 판정 대상 원문은 Vault에서만 읽고 출력하지 않는다.
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
jq -r '.data.data.harbor_robot_secret' "${temp_dir}/runtime.json" >"${temp_dir}/robot-secret"
jq -r '.data.data.gitea_ssh_private_key' "${temp_dir}/runtime.json" >"${temp_dir}/ssh-key"
jq -r '.data.data.admin_password' "${temp_dir}/runtime.json" >"${temp_dir}/admin-password"
[[ -s ${temp_dir}/robot-secret && -s ${temp_dir}/ssh-key && -s ${temp_dir}/admin-password ]] || {
  echo "Vault runtime bundle을 읽지 못했다" >&2
  exit 1
}

start_tunnel() {
  local name=$1 namespace=$2 service=$3 remote_port=$4 local_port=$5 probe=$6 expect=$7
  local target_ip
  # 다른 실행이 같은 port를 잡고 있으면 그 tunnel을 조용히 재사용하게 되어
  # 판정이 실행마다 달라진다. 재사용 대신 즉시 실패한다.
  if curl --silent --output /dev/null --max-time 2 "http://127.0.0.1:${local_port}/"; then
    echo "local port ${local_port}이 이미 사용 중이다. 다른 CI-01 검증이 실행 중인지 확인한다." >&2
    exit 1
  fi
  target_ip=$(kube -n "${namespace}" get service "${service}" -o "jsonpath='{.spec.clusterIP}'")
  [[ ${target_ip} =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || {
    echo "${name} Service ClusterIP를 판정하지 못했다" >&2
    exit 1
  }
  ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
    -L "${local_port}:${target_ip}:${remote_port}" "${k3s_host}" \
    >"${temp_dir}/${name}-tunnel.log" 2>&1 &
  local pid=$! code
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

# 인증과 CSRF crumb를 같은 session에서 확보한다.
jcurl --fail --output "${temp_dir}/crumb.json" "${jenkins_api}/crumbIssuer/api/json" || {
  echo "Jenkins crumb 발급 실패. local admin 인증 경계를 먼저 확인한다." >&2
  exit 1
}
crumb_field=$(jq -r '.crumbRequestField' "${temp_dir}/crumb.json")
crumb_value=$(jq -r '.crumb' "${temp_dir}/crumb.json")
echo "CI-01 검증: jenkins-auth=ok"

# 이전 실행의 잔여 agent Pod가 없어야 이번 실행의 spec을 정확히 집는다.
existing=$(kube -n jenkins get pods -l jenkins=slave -o "jsonpath='{.items[*].metadata.name}'")
[[ -z ${existing} ]] || { echo "이전 agent Pod가 남아 있다: ${existing}" >&2; exit 1; }

build_before=$(jcurl --fail "${jenkins_api}/job/${job_name}/api/json?tree=nextBuildNumber" | jq -r '.nextBuildNumber')
queue_location=$(jcurl --fail --request POST --dump-header - --output /dev/null \
  --header "${crumb_field}: ${crumb_value}" "${jenkins_api}/job/${job_name}/build" \
  | awk 'tolower($1) == "location:" {gsub(/\r/, "", $2); print $2}')
[[ -n ${queue_location} ]] || { echo "build 요청이 queue item을 반환하지 않았다" >&2; exit 1; }
queue_item=${queue_location%/}
queue_item=${queue_item##*/}
echo "CI-01 검증: build-triggered queue=${queue_item} expected-build=${build_before}"

# ---------------------------------------------------------------- 증거 2 수집
# 라이브 agent Pod spec은 이번 실행 중 한 번만 조회한다.
agent_spec=${temp_dir}/agent-pod.json
agent_name=
for _ in $(seq 1 180); do
  kube -n jenkins get pods -l jenkins=slave -o json >"${temp_dir}/agents.json" 2>/dev/null || true
  agent_name=$(jq -r '.items[0].metadata.name // empty' "${temp_dir}/agents.json")
  if [[ -n ${agent_name} ]]; then
    phase=$(jq -r '.items[0].status.phase // empty' "${temp_dir}/agents.json")
    if [[ ${phase} == Running ]]; then
      jq '.items[0]' "${temp_dir}/agents.json" >"${agent_spec}"
      break
    fi
  fi
  sleep 2
done
[[ -s ${agent_spec} ]] || { echo "실행 중인 agent Pod를 잡지 못했다" >&2; exit 1; }
agent_name=$(jq -r '.metadata.name' "${agent_spec}")
echo "CI-01 검증: agent-pod=${agent_name}"

for container in $(jq -r '.spec.containers[].name' "${agent_spec}"); do
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n jenkins logs ${agent_name} -c ${container} --follow --tail=-1" \
    >"${temp_dir}/agent-${container}.log" 2>&1 &
  log_pids+=($!)
done

# ---------------------------------------------------------------- build 완료 대기
build_number=
for _ in $(seq 1 120); do
  jcurl --output "${temp_dir}/queue.json" "${jenkins_api}/queue/item/${queue_item}/api/json" || true
  build_number=$(jq -r '.executable.number // empty' "${temp_dir}/queue.json" 2>/dev/null || true)
  [[ -n ${build_number} ]] && break
  sleep 2
done
[[ -n ${build_number} ]] || { echo "queue item이 build로 승격되지 않았다" >&2; exit 1; }

build_result=
for _ in $(seq 1 300); do
  jcurl --output "${temp_dir}/build.json" \
    "${jenkins_api}/job/${job_name}/${build_number}/api/json?tree=building,result" || true
  # jq의 `//`는 false도 대체 대상으로 보므로 `.building // true`를 쓰지 않는다.
  build_state=$(jq -r 'if .building == false then "finished" else "running" end' \
    "${temp_dir}/build.json" 2>/dev/null || true)
  if [[ ${build_state} == finished ]]; then
    build_result=$(jq -r '.result // empty' "${temp_dir}/build.json")
    break
  fi
  sleep 2
done
jcurl --fail --output "${temp_dir}/console.txt" "${jenkins_api}/job/${job_name}/${build_number}/consoleText"
if [[ ${build_result} != SUCCESS ]]; then
  echo "build ${build_number} 결과가 ${build_result:-미완료}다. 실패 지점을 콘솔에서 특정한다." >&2
  tail -n 60 "${temp_dir}/console.txt" >&2
  exit 1
fi
echo "CI-01 검증: build=${build_number} result=SUCCESS"

# 이미 끝난 log follower의 kill 실패로 set -e가 중단되지 않게 한다.
for pid in "${log_pids[@]+"${log_pids[@]}"}"; do kill "${pid}" 2>/dev/null || true; done
log_pids=()
sleep 2
kube -n jenkins logs deployment/jenkins -c jenkins --tail=-1 >"${temp_dir}/controller.log" 2>&1

# ---------------------------------------------------------------- 증거 1 마스킹
python3 - "${temp_dir}" <<'PY'
import pathlib
import sys

base = pathlib.Path(sys.argv[1])
secret = (base / "robot-secret").read_text(encoding="utf-8").strip()
ssh_key = (base / "ssh-key").read_text(encoding="utf-8").strip()
admin = (base / "admin-password").read_text(encoding="utf-8").strip()
key_body = "".join(
    line for line in ssh_key.splitlines() if line and not line.startswith("-----")
)
needles = {"harbor_robot_secret": secret, "jenkins_admin_password": admin}
if len(key_body) >= 40:
    needles["gitea_ssh_private_key"] = key_body[:40]

targets = sorted(
    p for p in base.iterdir() if p.suffix in {".txt", ".log"} and p.name != "console-probe.txt"
)
console = (base / "console.txt").read_text(encoding="utf-8", errors="replace")
if "ci01-mask-probe" not in console:
    raise SystemExit("마스킹 판정용 probe 줄이 콘솔에 없다")
if "****" not in console:
    raise SystemExit("콘솔에 마스킹 표기가 없다")

total = 0
for path in targets:
    text = path.read_text(encoding="utf-8", errors="replace")
    for name, needle in needles.items():
        hits = text.count(needle)
        total += hits
        if hits:
            print(f"평문 노출: {path.name} <- {name} x{hits}", file=sys.stderr)
print("checked_files=" + ",".join(p.name for p in targets))
if total:
    raise SystemExit(f"credential 원문 {total}건이 로그에 남았다")
print("evidence_1_secret_masking=pass plaintext_hits=0")
PY

# ---------------------------------------------------------------- 증거 2 비특권
python3 - "${agent_spec}" <<'PY'
import json
import sys

pod = json.load(open(sys.argv[1], encoding="utf-8"))
spec = pod["spec"]
pod_security = spec.get("securityContext", {})
problems = []

if pod_security.get("runAsNonRoot") is not True:
    problems.append("pod securityContext.runAsNonRoot != true")
if pod_security.get("runAsUser") in (None, 0):
    problems.append(f"pod runAsUser={pod_security.get('runAsUser')}")
if spec.get("hostNetwork") or spec.get("hostPID") or spec.get("hostIPC"):
    problems.append("host namespace를 공유한다")
if spec.get("automountServiceAccountToken") is not False:
    problems.append("agent Pod가 ServiceAccount token을 마운트한다")

volume_kinds = {}
for volume in spec.get("volumes", []):
    kind = next((k for k in volume if k != "name"), "unknown")
    volume_kinds[volume["name"]] = kind
    if kind == "hostPath":
        problems.append(f"hostPath volume: {volume['name']}")

containers = spec.get("containers", []) + spec.get("initContainers", [])
for container in containers:
    security = container.get("securityContext", {})
    name = container["name"]
    if security.get("privileged") is True:
        problems.append(f"{name}: privileged")
    if security.get("allowPrivilegeEscalation") is not False:
        problems.append(f"{name}: allowPrivilegeEscalation != false")
    effective_user = security.get("runAsUser", pod_security.get("runAsUser"))
    if effective_user in (None, 0):
        problems.append(f"{name}: runAsUser={effective_user}")
    if security.get("runAsNonRoot") is False:
        problems.append(f"{name}: runAsNonRoot=false")
    capabilities = security.get("capabilities", {})
    if [c.upper() for c in capabilities.get("drop", [])] != ["ALL"]:
        problems.append(f"{name}: capabilities.drop != [ALL]")
    added = [c.upper() for c in capabilities.get("add", [])]
    if not set(added) <= {"SYS_CHROOT"}:
        problems.append(f"{name}: 허용 밖 capability {added}")
    seccomp = security.get("seccompProfile", pod_security.get("seccompProfile", {})).get("type")
    # rootless builder만 user namespace를 위해 seccomp를 완화한다. 그 대가로
    # capability·root·권한상승은 어느 container에서도 열지 않는다.
    allowed_seccomp = {"Unconfined", "RuntimeDefault"} if name == "buildah" else {"RuntimeDefault"}
    if seccomp not in allowed_seccomp:
        problems.append(f"{name}: seccompProfile={seccomp}")
    for mount in container.get("volumeMounts", []):
        if "docker.sock" in mount.get("mountPath", ""):
            problems.append(f"{name}: docker socket mount")
        if volume_kinds.get(mount["name"]) == "hostPath":
            problems.append(f"{name}: hostPath mount {mount['mountPath']}")

if problems:
    raise SystemExit("비특권 판정 실패: " + "; ".join(problems))

print("pod=" + pod["metadata"]["name"])
print("pod_runAsNonRoot=%s runAsUser=%s" % (pod_security.get("runAsNonRoot"), pod_security.get("runAsUser")))
print("volumes=" + ",".join(f"{n}:{k}" for n, k in sorted(volume_kinds.items())))
for container in containers:
    security = container.get("securityContext", {})
    print(
        "container=%s allowPrivilegeEscalation=%s privileged=%s drop=%s add=%s seccomp=%s"
        % (
            container["name"],
            security.get("allowPrivilegeEscalation"),
            bool(security.get("privileged")),
            security.get("capabilities", {}).get("drop"),
            security.get("capabilities", {}).get("add", []),
            security.get("seccompProfile", pod_security.get("seccompProfile", {})).get("type"),
        )
    )
print("evidence_2_unprivileged_agent=pass")
PY

# ---------------------------------------------------------------- 증거 3 build/push
pushed_image=$(awk -F= '/^ci01-pushed-image=/{print $2}' "${temp_dir}/console.txt" | tail -1)
pushed_digest=$(awk -F= '/^ci01-pushed-digest=/{print $2}' "${temp_dir}/console.txt" | tail -1)
denied_state=$(awk -F= '/^ci01-denied-push=/{print $2}' "${temp_dir}/console.txt" | tail -1)
build_uid=$(awk -F'[= ]' '/^ci01-build-uid=/{print $2}' "${temp_dir}/console.txt" | tail -1)
[[ ${pushed_digest} =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "push digest를 얻지 못했다" >&2; exit 1; }
[[ ${denied_state} == rejected ]] || { echo "미지정 project push가 거부되지 않았다" >&2; exit 1; }
[[ ${build_uid} != 0 ]] || { echo "build 셸이 root로 실행됐다" >&2; exit 1; }

tag=${pushed_image##*:}
artifact_status=$(curl --config "${harbor_curl}" --output "${temp_dir}/artifact.json" --write-out '%{http_code}' \
  "${harbor_api}/projects/${evidence_project}/repositories/ci01-app/artifacts/${tag}")
[[ ${artifact_status} == 200 ]] || { echo "Harbor에서 push된 artifact를 찾지 못했다 (HTTP ${artifact_status})" >&2; exit 1; }
harbor_digest=$(jq -r '.digest' "${temp_dir}/artifact.json")
[[ ${harbor_digest} == "${pushed_digest}" ]] || {
  echo "Harbor artifact digest가 pipeline 출력과 다르다" >&2
  exit 1
}
curl --config "${harbor_curl}" --output "${temp_dir}/denied.json" \
  "${harbor_api}/projects/${denied_project}" >/dev/null
denied_repos=$(jq -r '.repo_count // 0' "${temp_dir}/denied.json")
[[ ${denied_repos} == 0 ]] || { echo "미지정 project에 repository가 생겼다" >&2; exit 1; }

echo "pushed_image=${pushed_image}"
echo "pushed_digest=${pushed_digest}"
echo "harbor_artifact_digest=${harbor_digest}"
echo "denied_project_repo_count=${denied_repos}"
echo "build_shell_uid=${build_uid}"
echo "evidence_3_build_push=pass"

# agent Pod는 podRetention=never로 build 종료와 함께 사라진다.
remaining=$(kube -n jenkins get pods -l jenkins=slave -o "jsonpath='{.items[*].metadata.name}'")
echo "agent_pods_after_build=${remaining:-none}"
echo "CI-01 완료 증거 3/3 통과 (build ${build_number})"
