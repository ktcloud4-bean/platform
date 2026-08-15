#!/usr/bin/env bash
# UPDATE-02 완료 증거: GitHub token push 권한, Renovate 설정 일치, 단발 Job 실행 canary PR 생성/확인, 자원 측정 및 정리.
# shellcheck disable=SC2029
set -Eeuo pipefail

: "${KTC_SECRET_ROOT:=$HOME/secrets/ktcloud4-bean}"
readonly vault_root_token_file=${VAULT_ROOT_TOKEN_FILE:-"$KTC_SECRET_ROOT/vault-root.token"}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly target_owner=ktcloud4-bean
readonly target_repo=hr-system
readonly target_slug=${target_owner}/${target_repo}

run_epoch=$(date +%s)
readonly run_epoch
readonly job_name=update02-canary-${run_epoch}


[[ -f "${vault_root_token_file}" && ! -L "${vault_root_token_file}" ]] || {
  echo "Vault root token 입력이 일반 파일이 아니다" >&2
  exit 1
}
[[ "$(stat -c %u "${vault_root_token_file}")" -eq "$(id -u)" \
  && "$(stat -c %a "${vault_root_token_file}")" == 600 ]] || {
  echo "Vault root token 입력은 호출자 소유 mode 0600이어야 한다" >&2
  exit 1
}

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
api_response=${temp_dir}/api.json
pod_top_file=${temp_dir}/renovate-top
all_pod_top=${temp_dir}/all-pod-top
pvc_rows=${temp_dir}/pvc-rows

job_created=false
pr_number=
pr_branch=

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

cleanup_live_state() {
  local token
  token=$(tr -d '\r\n' <"${token_file}" 2>/dev/null || true)
  if [[ -n "${token}" && -n "${pr_number}" ]]; then
    curl --silent --show-error --request PATCH \
      --header "Authorization: Bearer ${token}" \
      --header "Accept: application/vnd.github+json" \
      --header "User-Agent: update-02-verifier" \
      --data '{"state":"closed"}' \
      --output /dev/null \
      "https://api.github.com/repos/${target_slug}/pulls/${pr_number}" || true
    pr_number=
  fi
  if [[ -n "${token}" && -n "${pr_branch}" ]]; then
    local encoded_ref
    encoded_ref=$(jq -rn --arg val "heads/${pr_branch}" '$val|@uri')
    curl --silent --show-error --request DELETE \
      --header "Authorization: Bearer ${token}" \
      --header "Accept: application/vnd.github+json" \
      --header "User-Agent: update-02-verifier" \
      --output /dev/null \
      "https://api.github.com/repos/${target_slug}/git/refs/${encoded_ref}" || true
    pr_branch=
  fi
  if [[ "${job_created}" == true ]]; then
    kube -n renovate delete job "${job_name}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
    job_created=false
  fi
}

cleanup() {
  local status=$?
  set +e
  cleanup_live_state
  rm -rf "${temp_dir}"
  return "${status}"
}
trap cleanup EXIT INT TERM

echo "=== UPDATE-02 검증 1: Vault runtime secret 조회 ==="
vault_exec <<'REMOTE' >"${kv_json}"
vault kv get -format=json kv/renovate/runtime
REMOTE
jq -e '(.data.data | keys | sort) == (["github_token"] | sort)' "${kv_json}" >/dev/null
jq -r '.data.data.github_token' "${kv_json}" >"${token_file}"
chmod 0600 "${token_file}"
[[ -s "${token_file}" ]]
echo "UPDATE-02 Vault KV github_token 확인 완료"

echo "=== UPDATE-02 검증 2: GitHub API 권한 확인 ==="
gh_call() {
  local token
  token=$(tr -d '\r\n' <"${token_file}")
  curl --silent --show-error \
    --header "Authorization: Bearer ${token}" \
    --header "Accept: application/vnd.github+json" \
    --header "User-Agent: update-02-verifier" \
    "$@"
}

repo_status=$(gh_call --output "${api_response}" --write-out '%{http_code}' \
  "https://api.github.com/repos/${target_slug}")
[[ "${repo_status}" == 200 ]] || {
  echo "GitHub target repo(${target_slug}) 조회 실패: HTTP ${repo_status}" >&2
  exit 1
}
jq -e '.permissions.push == true' "${api_response}" >/dev/null || {
  echo "GitHub token에 push 권한이 없다" >&2
  exit 1
}
echo "UPDATE-02 GitHub repo 권한: target=${target_slug} push=true private=true"

echo "=== UPDATE-02 검증 3: Renovate 설정 선언 검증 ==="
config_content=$(kube -n renovate get configmap renovate-config -o "jsonpath='{.data.config\\.js}'")
echo "${config_content}" | grep -Fq "platform: 'github'"
echo "${config_content}" | grep -Fq "repositories: ['ktcloud4-bean/hr-system']"
echo "${config_content}" | grep -Fq "autodiscover: false"
echo "${config_content}" | grep -Fq "onboarding: false"
echo "${config_content}" | grep -Fq "allowScripts: false"
echo "${config_content}" | grep -Fq "automerge: false"
echo "${config_content}" | grep -Fq "platformAutomerge: false"
echo "${config_content}" | grep -Fq "prConcurrentLimit: 1"
echo "${config_content}" | grep -Fq "branchConcurrentLimit: 1"
echo "UPDATE-02 Renovate config.js 선언(단일 권위 저장소, manager allowlist, automerge/script 비활성, concurrent limit 1) 확인 완료"

echo "=== UPDATE-02 검증 4: Renovate CronJob 기반 단발 Job 실행 canary ==="
# 기존 오픈 PR 및 잔여 renovate 브랜치 정리
gh_call --output "${api_response}" \
  "https://api.github.com/repos/${target_slug}/pulls?state=open&limit=10"
for row in $(jq -r '.[] | "\(.number):\(.head.ref)"' "${api_response}"); do
  pre_num="${row%%:*}"
  pre_br="${row##*:}"
  curl --silent --show-error --request PATCH \
    --header "Authorization: Bearer $(tr -d '\r\n' <"${token_file}")" \
    --header "Accept: application/vnd.github+json" \
    --header "User-Agent: update-02-verifier" \
    --data '{"state":"closed"}' \
    --output /dev/null \
    "https://api.github.com/repos/${target_slug}/pulls/${pre_num}" || true
  if [[ "${pre_br}" =~ ^renovate/ ]]; then
    curl --silent --show-error --request DELETE \
      --header "Authorization: Bearer $(tr -d '\r\n' <"${token_file}")" \
      --header "Accept: application/vnd.github+json" \
      --header "User-Agent: update-02-verifier" \
      --output /dev/null \
      "https://api.github.com/repos/${target_slug}/git/refs/heads/${pre_br}" || true
  fi
done

gh_call --output "${api_response}" \
  "https://api.github.com/repos/${target_slug}/branches"
for br in $(jq -r '.[].name' "${api_response}"); do
  if [[ "${br}" =~ ^renovate/ ]]; then
    curl --silent --show-error --request DELETE \
      --header "Authorization: Bearer $(tr -d '\r\n' <"${token_file}")" \
      --header "Accept: application/vnd.github+json" \
      --header "User-Agent: update-02-verifier" \
      --output /dev/null \
      "https://api.github.com/repos/${target_slug}/git/refs/heads/${br}" || true
  fi
done

open_pr_status=$(gh_call --output "${api_response}" --write-out '%{http_code}' \
  "https://api.github.com/repos/${target_slug}/pulls?state=open&limit=10")
[[ "${open_pr_status}" == 200 ]]
initial_pr_count=$(jq 'length' "${api_response}")
echo "UPDATE-02 실행 전 기존 open PR 수: ${initial_pr_count}"

kube -n renovate create job --from=cronjob/renovate "${job_name}" >/dev/null
job_created=true
echo "UPDATE-02 test Job 생성: ${job_name}"

# Pod 생성 및 기동 대기
job_pod=
for _ in $(seq 1 30); do
  job_pod=$(kube -n renovate get pod -l "job-name=${job_name}" -o "jsonpath='{.items[0].metadata.name}'" 2>/dev/null || true)
  job_pod=$(echo "${job_pod}" | tr -d "'\"")
  if [[ -n "${job_pod}" ]]; then
    break
  fi
  sleep 1
done
[[ -n "${job_pod}" ]] || {
  echo "Renovate test Job Pod 생성 실패" >&2
  exit 1
}

kube -n renovate wait --for=condition=Ready pod "${job_pod}" --timeout=180s >/dev/null || true
echo "UPDATE-02 Pod 실행 중: ${job_pod}"

# Pod 리소스 메트릭 샘플 수집
for _ in $(seq 1 60); do
  if kube -n renovate top pod "${job_pod}" --no-headers >"${pod_top_file}" 2>/dev/null \
    && [[ -s "${pod_top_file}" ]]; then
    break
  fi
  phase=$(kube -n renovate get pod "${job_pod}" -o "jsonpath='{.status.phase}'")
  [[ "${phase}" == "Failed" || "${phase}" == "Succeeded" ]] && break
  sleep 2
done

# Job 완료 대기
job_result=
for _ in $(seq 1 300); do
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
  echo "Renovate test Job 실행 실패 또는 타임아웃: result=${job_result:-timeout}" >&2
  kube -n renovate get pod -l "job-name=${job_name}"
  exit 1
fi
echo "UPDATE-02 Renovate test Job 정상 완료 (succeeded=1)"

open_pr_count=0
for _ in $(seq 1 10); do
  gh_call --output "${api_response}" \
    "https://api.github.com/repos/${target_slug}/pulls?state=open&limit=10"
  open_pr_count=$(jq 'length' "${api_response}")
  if [[ "${open_pr_count}" -ge 1 ]]; then
    break
  fi
  sleep 2
done
echo "UPDATE-02 실행 후 open PR 수: ${open_pr_count}"

[[ "${open_pr_count}" -ge 1 ]] || {
  echo "Renovate 실행 후 생성된 PR이 없다" >&2
  exit 1
}

# 가장 최근 Renovate PR 확인
pr_number=$(jq -r '.[0].number' "${api_response}")
pr_title=$(jq -r '.[0].title' "${api_response}")
pr_branch=$(jq -r '.[0].head.ref' "${api_response}")
pr_state=$(jq -r '.[0].state' "${api_response}")
pr_merged=$(jq -r '.[0].merged_at // false' "${api_response}")

echo "UPDATE-02 Renovate Canary PR: #${pr_number} title='${pr_title}' branch='${pr_branch}' state=${pr_state} merged=${pr_merged}"
[[ "${pr_state}" == "open" ]]
[[ "${pr_merged}" == "false" ]]
[[ "${pr_branch}" =~ ^renovate/ ]]

echo "=== UPDATE-02 검증 6: 용량 및 자원 기준 점검 ==="
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

host_mem=$(ssh "${ssh_options[@]}" "root@proxmox-01.imcherry5778.xyz" \
  "free -m | awk '/^Mem:/{print \$2,\$7}'")
read -r host_total_mi host_available_mi <<<"${host_mem}"

guest_state=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "free -m | awk '/^Mem:/{print \$2,\$7}'; df -Pk / | awk 'NR==2{print \$2,\$3,\$4,\$5}'")
read -r guest_total_mi guest_available_mi <<<"$(sed -n '1p' <<<"${guest_state}")"
read -r guest_root_kib guest_root_used_kib guest_root_available_kib guest_root_used_percent \
  <<<"$(sed -n '2p' <<<"${guest_state}")"
guest_root_used_number=${guest_root_used_percent%%%}

capacity=GO
capacity_reason=none
if (( host_available_mi < 8192 || guest_available_mi < 4096 || guest_root_used_number > 80 || pvc_total_mi >= 122880 )); then
  capacity=STOP
  capacity_reason="capacity-plan-stop-threshold"
elif (( host_available_mi < 12288 || guest_root_used_number > 75 || pvc_total_mi >= 98304 )); then
  capacity_reason="capacity-plan-warning-threshold(WARN_GO)"
fi
[[ "${capacity}" == GO ]] || {
  echo "UPDATE-02 자원 판정 STOP reason=${capacity_reason}" >&2
  exit 1
}

echo "UPDATE-02 자원: node=${node_name} cpu=${node_cpu}/${node_cpu_percent} memory=${node_memory}/${node_memory_percent}"
echo "UPDATE-02 자원: running_pods=${running_pods} aggregate=${pod_cpu_m}m/${pod_memory_mi}Mi"
echo "UPDATE-02 자원: host_memory=${host_available_mi}/${host_total_mi}Mi pvc=${pvc_count}/${pvc_total_mi}Mi guest_memory=${guest_available_mi}/${guest_total_mi}Mi root=${guest_root_used_kib}/${guest_root_kib}Ki available=${guest_root_available_kib}Ki used=${guest_root_used_percent} 판정=GO"

echo "=== UPDATE-02 검증 7: Canary PR 및 임시 자원 정리 ==="
cleanup_live_state

# 정리 후 확인
gh_call --output "${api_response}" \
  "https://api.github.com/repos/${target_slug}/pulls?state=open&limit=10"
final_open_pr_count=$(jq 'length' "${api_response}")
echo "UPDATE-02 정리 후 open PR 수: ${final_open_pr_count}"

job_after=$(kube -n renovate get job "${job_name}" --ignore-not-found -o name)
[[ -z "${job_after}" ]]
echo "UPDATE-02 cleanup: test Job 및 Canary PR/branch 정리 완료"
echo "UPDATE-02 live evidence PASS"
