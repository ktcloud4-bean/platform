#!/usr/bin/env bash
# UPDATE-01 완료 증거: PAT allow/deny, Renovate PR/open, Node·Pod·PVC 자원 판정과 임시 상태 정리.
# shellcheck disable=SC2029
set -Eeuo pipefail

: "${KTC_SECRET_ROOT:=$HOME/secrets/ktcloud4-bean}"
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-"$KTC_SECRET_ROOT/vault-root.token"}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly local_port=${UPDATE01_VERIFY_PORT:-33011}
readonly target_owner=scm-recovery
readonly target_repo=platform-smoke
readonly target_slug=${target_owner}/${target_repo}
readonly git_url=ssh://git@git.imcherry5778.xyz:30022/${target_slug}.git
readonly host_key_alias=gitea-internal-update-01
run_epoch=$(date +%s)
readonly run_epoch
readonly job_name=update01-evidence-${run_epoch}
readonly permission_branch=update01-pat-write-${run_epoch}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root

[[ -f "${vault_root_token_file}" && ! -L "${vault_root_token_file}" ]] || {
  echo "Vault root token 입력이 일반 파일이 아니다" >&2
  exit 1
}
[[ "$(stat -c %u "${vault_root_token_file}")" -eq "$(id -u)" \
  && "$(stat -c %a "${vault_root_token_file}")" == 600 ]] || {
  echo "Vault root token 입력은 호출자 소유 mode 0600이어야 한다" >&2
  exit 1
}
case "${vault_root_token_file}" in
  "${repo_root}"|"${repo_root}"/*)
    echo "Vault root token 입력은 저장소 밖이어야 한다" >&2
    exit 1
    ;;
esac

ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
kv_json=${temp_dir}/kv.json
token_file=${temp_dir}/token
private_key=${temp_dir}/id_ed25519
runtime_known_hosts=${temp_dir}/known_hosts
pat_curl=${temp_dir}/pat.curl
api_response=${temp_dir}/api.json
work_repo=${temp_dir}/repo
job_json=${temp_dir}/job.json
job_apply_json=${temp_dir}/job-apply.json
pod_top_file=${temp_dir}/renovate-top
all_pod_top=${temp_dir}/all-pod-top
pvc_rows=${temp_dir}/pvc-rows
port_forward_pid=
permission_branch_created=false
seed_pushed=false
job_created=false
pr_index=
pr_branch=
seed_sha=

kube() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
}

vault_exec() {
  {
    tr -d '\n' <"${vault_root_token_file}"
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

stop_port_forward() {
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" 2>/dev/null || true
    wait "${port_forward_pid}" 2>/dev/null || true
    port_forward_pid=
  fi
}

start_port_forward() {
  local target_ip
  target_ip=$(kube -n gitea get service gitea-http -o "jsonpath='{.spec.clusterIP}'")
  [[ "${target_ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
  ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
    -L "${local_port}:${target_ip}:3000" "${k3s_host}" \
    >"${temp_dir}/port-forward.log" 2>&1 &
  port_forward_pid=$!
  for _ in $(seq 1 45); do
    kill -0 "${port_forward_pid}" 2>/dev/null || break
    if curl --silent --show-error --fail \
      --header 'Host: git.imcherry5778.xyz' --header 'X-Forwarded-Proto: https' \
      "http://127.0.0.1:${local_port}/api/healthz" >/dev/null 2>&1; then
      return
    fi
    sleep 1
  done
  echo "Gitea 내부 API tunnel health timeout" >&2
  exit 1
}

pat_call() {
  curl --config "${pat_curl}" "$@"
}

cleanup_live_state() {
  if [[ -n "${pr_index}" ]]; then
    printf '{"state":"closed"}\n' >"${temp_dir}/close-pr.json"
    pat_call --request PATCH --header 'Content-Type: application/json' \
      --data-binary "@${temp_dir}/close-pr.json" --output /dev/null \
      "http://127.0.0.1:${local_port}/api/v1/repos/${target_slug}/pulls/${pr_index}"
    pr_index=
  fi
  if [[ -n "${pr_branch}" ]]; then
    encoded_branch=$(jq -rn --arg value "${pr_branch}" '$value|@uri')
    pat_call --request DELETE --output /dev/null \
      "http://127.0.0.1:${local_port}/api/v1/repos/${target_slug}/branches/${encoded_branch}"
    pr_branch=
  fi
  if [[ "${seed_pushed}" == true && -d "${work_repo}/.git" ]]; then
    git -C "${work_repo}" revert --no-edit "${seed_sha}" >/dev/null 2>&1
    GIT_SSH_COMMAND="ssh -F /dev/null -i ${private_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${runtime_known_hosts} -o HostKeyAlias=${host_key_alias}" \
      git -C "${work_repo}" push --quiet origin HEAD:refs/heads/main
    seed_pushed=false
  fi
  if [[ "${permission_branch_created}" == true ]]; then
    encoded_permission_branch=$(jq -rn --arg value "${permission_branch}" '$value|@uri')
    pat_call --request DELETE --output /dev/null \
      "http://127.0.0.1:${local_port}/api/v1/repos/${target_slug}/branches/${encoded_permission_branch}"
    permission_branch_created=false
  fi
  if [[ "${job_created}" == true ]]; then
    kube -n renovate delete job "${job_name}" --ignore-not-found --wait=true >/dev/null
    job_created=false
  fi
}

cleanup() {
  local status=$?
  set +e
  cleanup_live_state
  stop_port_forward
  rm -rf "${temp_dir}"
  return "${status}"
}
trap cleanup EXIT INT TERM

vault_exec <<'REMOTE' >"${kv_json}"
vault kv get -format=json kv/renovate/runtime
REMOTE
jq -e '
  (.data.data | keys | sort) ==
  (["gitea_token","ssh_known_hosts","ssh_private_key"] | sort)
' "${kv_json}" >/dev/null
jq -r '.data.data.gitea_token' "${kv_json}" >"${token_file}"
jq -r '.data.data.ssh_private_key' "${kv_json}" >"${private_key}"
jq -r '.data.data.ssh_known_hosts' "${kv_json}" >"${runtime_known_hosts}"
chmod 0600 "${token_file}" "${private_key}" "${runtime_known_hosts}"
[[ -s "${token_file}" && -s "${private_key}" && -s "${runtime_known_hosts}" ]]

printf 'header = "Authorization: token %s"\nheader = "Host: git.imcherry5778.xyz"\nheader = "X-Forwarded-Proto: https"\nsilent\nshow-error\n' \
  "$(tr -d '\n' <"${token_file}")" >"${pat_curl}"
start_port_forward
readonly api_base=http://127.0.0.1:${local_port}/api/v1

# 완료 증거 1a: PAT로 대상 repository에 branch 생성/삭제가 가능하다.
printf '{"new_branch_name":"%s","old_branch_name":"main"}\n' "${permission_branch}" \
  >"${temp_dir}/create-branch.json"
write_status=$(pat_call --request POST --header 'Content-Type: application/json' \
  --data-binary "@${temp_dir}/create-branch.json" --output "${api_response}" --write-out '%{http_code}' \
  "${api_base}/repos/${target_slug}/branches")
[[ "${write_status}" == 201 ]]
jq -e --arg branch "${permission_branch}" '.name == $branch' "${api_response}" >/dev/null
permission_branch_created=true
echo "UPDATE-01 권한 allow: bot PAT target=${target_slug} branch-write HTTP 201"

# 완료 증거 1b: 같은 PAT는 admin API를 사용할 수 없다.
deny_status=$(pat_call --output "${api_response}" --write-out '%{http_code}' \
  "${api_base}/admin/users?limit=1")
[[ "${deny_status}" == 403 ]]
echo "UPDATE-01 권한 deny: bot PAT admin/users HTTP 403"

open_pr_status=$(pat_call --output "${api_response}" --write-out '%{http_code}' \
  "${api_base}/repos/${target_slug}/pulls?state=open&limit=50")
[[ "${open_pr_status}" == 200 ]]
jq -e 'length == 0' "${api_response}" >/dev/null || {
  echo "대상 smoke repo에 기존 open PR이 있어 검증을 시작하지 않는다." >&2
  exit 1
}

GIT_SSH_COMMAND="ssh -F /dev/null -i ${private_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${runtime_known_hosts} -o HostKeyAlias=${host_key_alias}" \
  git clone --quiet "${git_url}" "${work_repo}"
git -C "${work_repo}" checkout -q main
[[ ! -e "${work_repo}/package.json" && ! -e "${work_repo}/renovate.json" ]] || {
  echo "대상 smoke repo에 기존 dependency/config 파일이 있어 덮어쓰지 않는다." >&2
  exit 1
}
git -C "${work_repo}" rev-parse HEAD >/dev/null
git -C "${work_repo}" config user.name 'UPDATE-01 verifier'
git -C "${work_repo}" config user.email 'update-01@imcherry5778.xyz'
printf '%s\n' \
  '{' \
  '  "name": "update-01-renovate-smoke",' \
  '  "version": "1.0.0",' \
  '  "private": true,' \
  '  "dependencies": {' \
  '    "update01-lodash-smoke": "npm:lodash@4.17.20"' \
  '  }' \
  '}' >"${work_repo}/package.json"
git -C "${work_repo}" add package.json
git -C "${work_repo}" commit -q -m 'UPDATE-01 temporary outdated dependency'
seed_sha=$(git -C "${work_repo}" rev-parse HEAD)
GIT_SSH_COMMAND="ssh -F /dev/null -i ${private_key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=${runtime_known_hosts} -o HostKeyAlias=${host_key_alias}" \
  git -C "${work_repo}" push --quiet origin HEAD:refs/heads/main
seed_pushed=true

# CronJob 원본에서 검증 Job을 만들고, 종료 직전 45초 관측 창만 추가한다.
kube -n renovate create job --from=cronjob/renovate "${job_name}" --dry-run=client -o json \
  >"${job_json}"
jq '
  .spec.template.spec.containers[0].command = ["/bin/sh","-ec"] |
  .spec.template.spec.containers[0].args = [
    "set +e\nrenovate\nstatus=$?\nsleep 45\nexit \"$status\""
  ]
' "${job_json}" >"${job_apply_json}"
ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} apply -f -" \
  <"${job_apply_json}" >/dev/null
job_created=true
kube -n renovate wait --for=condition=Ready pod -l "job-name=${job_name}" --timeout=180s >/dev/null
job_pod=$(kube -n renovate get pod -l "job-name=${job_name}" -o "jsonpath='{.items[0].metadata.name}'")
[[ -n "${job_pod}" ]]

for _ in $(seq 1 90); do
  if kube -n renovate top pod "${job_pod}" --no-headers >"${pod_top_file}" 2>/dev/null \
    && [[ -s "${pod_top_file}" ]]; then
    break
  fi
  phase=$(kube -n renovate get pod "${job_pod}" -o "jsonpath='{.status.phase}'")
  [[ "${phase}" == Failed ]] && break
  sleep 2
done
job_result=
for _ in $(seq 1 900); do
  succeeded=$(kube -n renovate get job "${job_name}" -o "jsonpath='{.status.succeeded}'")
  failed=$(kube -n renovate get job "${job_name}" -o "jsonpath='{.status.failed}'")
  if [[ "${succeeded:-0}" -ge 1 ]]; then
    job_result=complete
    break
  fi
  if [[ "${failed:-0}" -ge 1 ]]; then
    job_result=failed
    break
  fi
  sleep 2
done
if [[ "${job_result}" != complete ]]; then
  phase=$(kube -n renovate get pod "${job_pod}" -o "jsonpath='{.status.phase}'")
  reason=$(kube -n renovate get pod "${job_pod}" -o "jsonpath='{.status.containerStatuses[0].state.terminated.reason}'")
  exit_code=$(kube -n renovate get pod "${job_pod}" -o "jsonpath='{.status.containerStatuses[0].state.terminated.exitCode}'")
  echo "Renovate Job 실패: result=${job_result:-timeout} pod_phase=${phase} reason=${reason:-unknown} exit=${exit_code:-unknown}; 로그 원문은 출력하지 않았다." >&2
  exit 1
fi
[[ -s "${pod_top_file}" ]] || {
  echo "Renovate Pod 실행 중 metrics 표본을 얻지 못했다." >&2
  exit 1
}

pr_status=$(pat_call --output "${api_response}" --write-out '%{http_code}' \
  "${api_base}/repos/${target_slug}/pulls?state=open&limit=50")
[[ "${pr_status}" == 200 ]] || {
  echo "Renovate PR 조회 실패: HTTP ${pr_status}" >&2
  exit 1
}
jq -e 'length == 1' "${api_response}" >/dev/null || {
  pr_count=$(jq 'length' "${api_response}")
  echo "Renovate PR 개수가 1이 아니다: count=${pr_count}" >&2
  exit 1
}
pr_index=$(jq -r '.[0].number' "${api_response}")
pr_branch=$(jq -r '.[0].head.label' "${api_response}")
[[ "${pr_index}" =~ ^[0-9]+$ && -n "${pr_branch}" ]]
jq -e '
  .[0].state == "open" and .[0].merged == false and
  .[0].user.login == "renovate" and .[0].base.ref == "main" and
  (.[0].head.label | startswith("renovate/")) and
  (.[0].title | ascii_downcase | contains("update01-lodash-smoke"))
' "${api_response}" >/dev/null || {
  echo "Renovate PR이 open/non-merged/bot/main/renovate-branch/lodash 조건과 다르다." >&2
  exit 1
}
echo "UPDATE-01 PR: repo=${target_slug} count=1 state=open merged=false number=${pr_index}"

# 완료 증거 4: 같은 시점의 Node·Pod·PVC와 guest 여유를 한 번만 측정한다.
kube top pods -A --no-headers >"${all_pod_top}"
read -r running_pods pod_cpu_m pod_memory_mi < <(
  awk '
    function cpu_m(value) {
      if (value ~ /m$/) { sub(/m$/, "", value); return value + 0 }
      return (value + 0) * 1000
    }
    function memory_mi(value) {
      if (value ~ /Ki$/) { sub(/Ki$/, "", value); return (value + 0) / 1024 }
      if (value ~ /Mi$/) { sub(/Mi$/, "", value); return value + 0 }
      if (value ~ /Gi$/) { sub(/Gi$/, "", value); return (value + 0) * 1024 }
      return (value + 0) / 1048576
    }
    { count++; cpu += cpu_m($3); memory += memory_mi($4) }
    END { printf "%d %.0f %.0f\n", count, cpu, memory }
  ' "${all_pod_top}"
)
read -r renovate_pod_name renovate_cpu renovate_memory <"${pod_top_file}"
node_top=$(kube top node --no-headers)
read -r node_name node_cpu node_cpu_percent node_memory node_memory_percent <<<"${node_top}"

kube get pvc -A -o "custom-columns=NS:.metadata.namespace,NAME:.metadata.name,SIZE:.spec.resources.requests.storage" \
  --no-headers >"${pvc_rows}"
read -r pvc_count pvc_total_mi < <(
  awk '
    function storage_mi(value) {
      if (value ~ /Ki$/) { sub(/Ki$/, "", value); return (value + 0) / 1024 }
      if (value ~ /Mi$/) { sub(/Mi$/, "", value); return value + 0 }
      if (value ~ /Gi$/) { sub(/Gi$/, "", value); return (value + 0) * 1024 }
      if (value ~ /Ti$/) { sub(/Ti$/, "", value); return (value + 0) * 1048576 }
      return (value + 0) / 1048576
    }
    NF >= 3 { count++; total += storage_mi($3) }
    END { printf "%d %.0f\n", count, total }
  ' "${pvc_rows}"
)
guest_state=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "free -m | awk '/^Mem:/{print \$2,\$7}'; df -Pk / | awk 'NR==2{print \$2,\$3,\$4,\$5}'")
read -r guest_total_mi guest_available_mi <<<"$(sed -n '1p' <<<"${guest_state}")"
read -r guest_root_kib guest_root_used_kib guest_root_available_kib guest_root_used_percent \
  <<<"$(sed -n '2p' <<<"${guest_state}")"
guest_root_used_number=${guest_root_used_percent%%%}

capacity=GO
capacity_reason=none
if (( guest_available_mi < 8192 || guest_root_used_number > 80 || pvc_total_mi >= 122880 )); then
  capacity=STOP
  capacity_reason="capacity-plan-stop-threshold"
elif (( guest_available_mi < 12288 || guest_root_used_number > 75 || pvc_total_mi >= 98304 )); then
  capacity=STOP
  capacity_reason="capacity-plan-warning-threshold"
fi
[[ "${capacity}" == GO ]] || {
  echo "UPDATE-01 자원 판정 STOP reason=${capacity_reason}" >&2
  exit 1
}

echo "UPDATE-01 자원: node=${node_name} cpu=${node_cpu}/${node_cpu_percent} memory=${node_memory}/${node_memory_percent}"
echo "UPDATE-01 자원: running_pods=${running_pods} aggregate=${pod_cpu_m}m/${pod_memory_mi}Mi renovate_pod=${renovate_pod_name} sample=${renovate_cpu}/${renovate_memory}"
echo "UPDATE-01 자원: pvc=${pvc_count}/${pvc_total_mi}Mi guest_memory=${guest_available_mi}/${guest_total_mi}Mi root=${guest_root_used_kib}/${guest_root_kib}Ki available=${guest_root_available_kib}Ki used=${guest_root_used_percent} 판정=GO"

cleanup_live_state
open_after_cleanup=$(pat_call --output "${api_response}" --write-out '%{http_code}' \
  "${api_base}/repos/${target_slug}/pulls?state=open&limit=50")
[[ "${open_after_cleanup}" == 200 ]]
jq -e 'length == 0' "${api_response}" >/dev/null
package_after_cleanup=$(pat_call --output "${api_response}" --write-out '%{http_code}' \
  "${api_base}/repos/${target_slug}/contents/package.json?ref=main")
[[ "${package_after_cleanup}" == 404 ]]
permission_branch_after=$(pat_call --output "${api_response}" --write-out '%{http_code}' \
  "${api_base}/repos/${target_slug}/branches/$(jq -rn --arg value "${permission_branch}" '$value|@uri')")
[[ "${permission_branch_after}" == 404 ]]
branches_after_cleanup=$(pat_call --output "${api_response}" --write-out '%{http_code}' \
  "${api_base}/repos/${target_slug}/branches?limit=50")
[[ "${branches_after_cleanup}" == 200 ]]
jq -e '[.[] | select(.name | startswith("renovate/"))] | length == 0' "${api_response}" >/dev/null
job_after_cleanup=$(kube -n renovate get job "${job_name}" --ignore-not-found -o name)
[[ -z "${job_after_cleanup}" ]]
echo "UPDATE-01 cleanup: open_PR=0 temporary_branches=0 package.json=absent Job=absent"
echo "UPDATE-01 live evidence PASS; 종료 trap이 로컬 key/PAT 사본을 제거한다."
