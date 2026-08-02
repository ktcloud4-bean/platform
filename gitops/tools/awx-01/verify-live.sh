#!/usr/bin/env bash
# AWX-01 완료 증거 네 항목만 같은 live 시점에 판정한다.
set -Eeuo pipefail

: "${KTC_SECRET_ROOT:?KTC_SECRET_ROOT가 필요하다}"
readonly awx_env=${KTC_SECRET_ROOT}/awx/env
readonly kc_secret_dir=${KTC_SECRET_ROOT}/keycloak
readonly connect_ip=${AWX01_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly proxmox_host=${PROXMOX_HOST:-root@proxmox-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly expected_root_revision=${AWX01_EXPECTED_ROOT_REVISION:?platform-root 검증 commit SHA가 필요하다}
readonly expected_app_revision=${AWX01_EXPECTED_APP_REVISION:?AWX child 검증 commit SHA가 필요하다}
readonly local_port=${AWX01_LOCAL_PORT:-18081}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

for required in "${awx_env}" "${kc_secret_dir}/daily-password" "${kc_secret_dir}/daily-totp" \
  "${kc_secret_dir}/privileged-password" "${kc_secret_dir}/privileged-totp"; do
  [[ -s "${required}" && "$(stat -c %a "${required}")" == 600 ]] || {
    echo "필수 비밀 파일은 mode 0600이어야 한다: ${required}" >&2
    exit 1
  }
done
[[ "${expected_root_revision}" =~ ^[0-9a-f]{40}$ ]]
[[ "${expected_app_revision}" =~ ^[0-9a-f]{40}$ ]]
[[ "${local_port}" =~ ^[0-9]+$ ]]

set -a
# shellcheck disable=SC1090
source "${awx_env}"
set +a
: "${AWX_ADMIN_PASSWORD:?AWX_ADMIN_PASSWORD가 필요하다}"

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
port_forward_pid=
cleanup() {
  if [[ -n "${port_forward_pid}" ]]; then
    kill "${port_forward_pid}" >/dev/null 2>&1 || true
    wait "${port_forward_pid}" >/dev/null 2>&1 || true
  fi
  rm -rf "${temp_dir}"
}
trap cleanup EXIT INT TERM

admin_header=${temp_dir}/admin.header
objects_file=${temp_dir}/objects.json
all_inventories=${temp_dir}/inventories.json
all_templates=${temp_dir}/templates.json
all_credentials=${temp_dir}/credentials.json
all_workflows=${temp_dir}/workflows.json
body_file=${temp_dir}/body.json
pattern_file=${temp_dir}/patterns
log_file=${temp_dir}/awx.log
printf 'Authorization: Basic %s\n' "$(printf 'awx-recovery:%s' "${AWX_ADMIN_PASSWORD}" | base64 -w0)" >"${admin_header}"

echo "AWX-01 배포/API 상태를 확인한다. 실패하면 Operator 로그와 CR status를 먼저 출력한다."
if ! ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n awx rollout status deploy/awx-web --timeout=30s && \
   ${kubectl_command} -n awx rollout status deploy/awx-task --timeout=30s && \
   ${kubectl_command} -n awx get awx awx -o jsonpath='{.status.version}' | grep -Fx 24.6.1"; then
  ssh "${ssh_options[@]}" "${k3s_host}" \
    "${kubectl_command} -n awx get awx awx -o yaml; \
     ${kubectl_command} -n awx logs deploy/awx-operator-controller-manager -c awx-manager --tail=200" >&2
  exit 1
fi
argo_state=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n argocd get application platform-root awx -o jsonpath='{range .items[*]}{.metadata.name}{\"|\"}{.status.sync.status}{\"|\"}{.status.health.status}{\"|\"}{.spec.source.targetRevision}{\"\\n\"}{end}'")
grep -Fxq "platform-root|Synced|Healthy|${expected_root_revision}" <<<"${argo_state}"
grep -Fxq "awx|Synced|Healthy|${expected_app_revision}" <<<"${argo_state}"

awx_service_ip=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n awx get service awx-service -o jsonpath='{.spec.clusterIP}'")
readonly awx_service_ip
[[ "${awx_service_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
ssh "${ssh_options[@]}" -o ExitOnForwardFailure=yes -N \
  -L "127.0.0.1:${local_port}:${awx_service_ip}:80" "${k3s_host}" \
  >"${temp_dir}/port-forward.log" 2>&1 &
port_forward_pid=$!
for _ in $(seq 1 30); do
  if curl --silent --fail "http://127.0.0.1:${local_port}/api/v2/ping/" >/dev/null 2>&1; then break; fi
  sleep 1
done
kill -0 "${port_forward_pid}" >/dev/null 2>&1 || { cat "${temp_dir}/port-forward.log" >&2; exit 1; }

api_get() {
  curl --silent --show-error --fail --header "@${admin_header}" \
    "http://127.0.0.1:${local_port}/api/v2$1"
}
api_get '/inventories/?page_size=200' >"${all_inventories}"
api_get '/job_templates/?page_size=200' >"${all_templates}"
api_get '/credentials/?page_size=200' >"${all_credentials}"
api_get '/workflow_job_templates/?page_size=200' >"${all_workflows}"

production_id=$(jq -er '.results[] | select(.name=="운영 VM 정적 인벤토리 (실행 금지)") | .id' "${all_inventories}")
boundary_id=$(jq -er '.results[] | select(.name=="AWX-01 검증 전용 (cluster 내부)") | .id' "${all_inventories}")
check_id=$(jq -er '.results[] | select(.name=="AWX-01 credential check") | .id' "${all_templates}")
denied_id=$(jq -er '.results[] | select(.name=="AWX-01 credential denied") | .id' "${all_templates}")
apply_id=$(jq -er '.results[] | select(.name=="AWX-01 approved apply") | .id' "${all_templates}")
allowed_credential_id=$(jq -er '.results[] | select(.name=="AWX-01 verifier allowed") | .id' "${all_credentials}")
denied_credential_id=$(jq -er '.results[] | select(.name=="AWX-01 verifier denied") | .id' "${all_credentials}")
workflow_id=$(jq -er '.results[] | select(.name=="AWX-01 check-to-apply 승인") | .id' "${all_workflows}")
jq -n --argjson allowed_credential "${allowed_credential_id}" \
  --argjson denied_credential "${denied_credential_id}" --argjson check_template "${check_id}" \
  --argjson denied_template "${denied_id}" --argjson apply_template "${apply_id}" \
  --argjson workflow "${workflow_id}" \
  '{$allowed_credential,$denied_credential,$check_template,$denied_template,$apply_template,$workflow}' >"${objects_file}"

echo "증거 1/4 inventory: ip-plan 정적 host 집합과 job template limit을 판정한다."
api_get "/hosts/?inventory=${production_id}&page_size=200" >"${body_file}"
jq -e '
  .count == 5 and
  ([.results[].name] | sort) == (["k3s-01.imcherry5778.xyz","netbird-01.imcherry5778.xyz",
    "object-01.imcherry5778.xyz","postgres-01.imcherry5778.xyz","warpgate-01.imcherry5778.xyz"] | sort)
' "${body_file}" >/dev/null
api_get "/inventory_sources/?inventory=${production_id}&page_size=200" | jq -e '.count == 0' >/dev/null
api_get "/hosts/?inventory=${boundary_id}&page_size=200" | jq -e '
  .count == 1 and .results[0].name == "awx-verifier.awx.svc.cluster.local"
' >/dev/null
for template_id in "${check_id}" "${denied_id}" "${apply_id}"; do
  api_get "/job_templates/${template_id}/" | jq -e \
    --argjson boundary "${boundary_id}" '
      .inventory == $boundary and .limit == "awx-verifier.awx.svc.cluster.local" and
      .ask_inventory_on_launch == false and .ask_limit_on_launch == false and
      .ask_credential_on_launch == false and .ask_job_type_on_launch == false
    ' >/dev/null
done
api_get "/job_templates/${check_id}/" | jq -e '.job_type == "check"' >/dev/null
echo "INVENTORY_EVIDENCE production_hosts=5 dynamic_sources=0 boundary_hosts=1 job_limit=exact"

echo "증거 2·3/4 credential 격리와 check/apply 사람 승인 경계를 실제 SSO 사용자로 대조한다."
node "${repo_root}/gitops/tools/awx-01/browser-verify.js" \
  --connect-ip "${connect_ip}" \
  --daily-password-file "${kc_secret_dir}/daily-password" \
  --daily-totp-file "${kc_secret_dir}/daily-totp" \
  --privileged-password-file "${kc_secret_dir}/privileged-password" \
  --privileged-totp-file "${kc_secret_dir}/privileged-totp" \
  --object-file "${objects_file}" --secret-env-file "${awx_env}"

echo "AWX job 및 Pod 로그에 비밀 원문이 없는지 확인한다."
awk -F= 'NF >= 2 {value=substr($0,index($0,"=")+1); if (length(value)>=20) print value}' \
  "${awx_env}" >"${pattern_file}"
if git -C "${repo_root}" grep -F -f "${pattern_file}" -- . >/dev/null 2>&1; then
  echo "Git 추적 파일에서 AWX-01 비밀 원문을 찾았다." >&2
  exit 1
fi
ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} -n awx logs -l app.kubernetes.io/managed-by=awx-operator \
    --all-containers=true --prefix=true --tail=-1" >"${log_file}" 2>/dev/null
if grep -F -f "${pattern_file}" "${log_file}" >/dev/null 2>&1; then
  echo "AWX Pod 로그에서 비밀 원문을 찾았다." >&2
  exit 1
fi
echo "SECRET_LOG_EVIDENCE git=0 awx_pod_logs=0 job_stdout=0"

echo "증거 4/4 capacity-plan 지표를 배포 직후 다시 읽는다."
k3s_capacity=$(ssh "${ssh_options[@]}" "${k3s_host}" '
  available=$(free -m | awk "/^Mem:/{print \$7}")
  swap_used=$(free -m | awk "/^Swap:/{print \$3}")
  root_used=$(df -P / | awk "NR==2{gsub(/%/,\"\",\$5); print \$5}")
  printf "%s|%s|%s\n" "$available" "$swap_used" "$root_used"
')
IFS='|' read -r guest_available_mib guest_swap_used_mib guest_root_used_pct <<<"${k3s_capacity}"
node_usage=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} top node k3s-01.imcherry5778.xyz --no-headers")
pvc_count=$(ssh "${ssh_options[@]}" "${k3s_host}" \
  "${kubectl_command} get pvc -A --no-headers 2>/dev/null | wc -l")
host_capacity=$(ssh "${ssh_options[@]}" "${proxmox_host}" '
  available=$(free -m | awk "/^Mem:/{print \$7}")
  swap_used=$(free -m | awk "/^Swap:/{print \$3}")
  read -r data metadata < <(lvs --noheadings --units p --nosuffix -o data_percent,metadata_percent pve/data)
  root_used=$(df -P / | awk "NR==2{gsub(/%/,\"\",\$5); print \$5}")
  printf "%s|%s|%s|%s|%s\n" "$available" "$swap_used" "$data" "$metadata" "$root_used"
')
IFS='|' read -r host_available_mib host_swap_used_mib thin_data_pct thin_metadata_pct host_root_used_pct <<<"${host_capacity}"

decision=GO
if (( guest_available_mib < 12288 || guest_swap_used_mib > 0 || guest_root_used_pct >= 75 || \
      host_available_mib < 12288 || host_swap_used_mib > 0 || host_root_used_pct >= 70 )); then
  decision=STOP
fi
awk -v data="${thin_data_pct}" -v metadata="${thin_metadata_pct}" \
  'BEGIN { exit !((data+0)>=60 || (metadata+0)>=50) }' && decision=STOP || true
printf 'CAPACITY_EVIDENCE decision=%s k3s_guest_available_mib=%s k3s_swap_used_mib=%s k3s_root_used_pct=%s node="%s" pvc_count=%s host_available_mib=%s host_swap_used_mib=%s thin_data_pct=%s thin_metadata_pct=%s host_root_used_pct=%s\n' \
  "${decision}" "${guest_available_mib}" "${guest_swap_used_mib}" "${guest_root_used_pct}" \
  "${node_usage}" "${pvc_count}" "${host_available_mib}" "${host_swap_used_mib}" \
  "${thin_data_pct}" "${thin_metadata_pct}" "${host_root_used_pct}"
[[ "${decision}" == GO ]]

echo "AWX-01 네 완료 증거 통과. 선택지 (b)이므로 실제 운영 대상 cross-VLAN SSH 증거가 아니다."
