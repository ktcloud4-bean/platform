#!/usr/bin/env bash
# shellcheck disable=SC2029
# OBS-02의 선언, UI, 최소권한, 용량과 Traefik 불변을 완료 증거 범위에서만 검증한다.
set -Eeuo pipefail

readonly mode=${1:-verify}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly kc_secret_dir=${KC01_SECRET_DIR:-${secret_root}/keycloak}
readonly grafana_password_file=${OBS02_GRAFANA_PASSWORD_FILE:-${secret_root}/obs/grafana-admin-password}
readonly connect_ip=${OBS02_CONNECT_IP:-10.10.20.10}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly available_stop_bytes=$((8 * 1024 * 1024 * 1024))
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ ${mode} == capacity-pre || ${mode} == verify ]] || {
  echo 'usage: verify-live.sh [capacity-pre|verify]' >&2
  exit 2
}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'OBS-02 검증 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

fail() {
  local stage=$1
  shift
  echo "OBS-02 검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

remote_kubectl() {
  # 인자는 이 스크립트가 만든 비밀 없는 고정값만 전달한다.
  # shellcheck disable=SC2029,SC2086
  ssh "${ssh_options[@]}" "${k3s_host}" ${kubectl_command} "$@"
}

wait_for_route_tls() {
  local hostname attempt ready
  for hostname in grafana.imcherry5778.xyz prometheus.imcherry5778.xyz alertmanager.imcherry5778.xyz; do
    ready=false
    for ((attempt = 1; attempt <= 36; attempt++)); do
      if curl --silent --show-error --fail \
        --resolve "${hostname}:443:${connect_ip}" \
        "https://${hostname}/.well-known/pomerium" >/dev/null 2>&1; then
        ready=true
        break
      fi
      sleep 5
    done
    [[ "${ready}" == true ]] || fail route-tls "${hostname} strict TLS가 180초 안에 준비되지 않았다."
  done
  echo 'RouteTLS=PASS grafana prometheus alertmanager'
}

measure_capacity() {
  ssh "${ssh_options[@]}" "${k3s_host}" 'bash -s' <<'REMOTE'
set -euo pipefail
k='sudo -n /usr/local/bin/k3s kubectl'
available_bytes=$(free -b | awk '/Mem:/{print $7}')
swap_used_bytes=$(free -b | awk '/Swap:/{print $3}')
pvc_request_bytes=$(
  ${k} get pvc -A -o json \
    | jq -r '.items[].spec.resources.requests.storage' \
    | while IFS= read -r quantity; do numfmt --from=iec-i "${quantity}"; done \
    | awk '{sum+=$1} END{printf "%.0f\n",sum+0}'
)
printf 'AVAILABLE_BYTES=%s\nSWAP_USED_BYTES=%s\nPVC_REQUEST_BYTES=%s\n' \
  "${available_bytes}" "${swap_used_bytes}" "${pvc_request_bytes}"
REMOTE
}

measure_traefik() {
  local hcc_generation traefik_json
  hcc_generation=$(remote_kubectl -n kube-system get helmchartconfig traefik -o jsonpath='{.metadata.generation}')
  traefik_json=$(remote_kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o json)
  jq -r --arg generation "${hcc_generation}" '
    .items as $pods |
    if ($generation | test("^[0-9]+$")) and ($pods | length == 1) then
      "HELMCHARTCONFIG_GENERATION=" + $generation,
      "TRAEFIK_POD_UID=" + $pods[0].metadata.uid,
      "TRAEFIK_RESTARTS=" + ([ $pods[0].status.containerStatuses[]?.restartCount ] | add | tostring)
    else error("unexpected HelmChartConfig generation or Traefik Pod count") end
  ' <<<"${traefik_json}"
}

capacity_gate() {
  local prefix=$1 values=$2 available_bytes swap_used_bytes pvc_request_bytes
  available_bytes=$(awk -F= '$1=="AVAILABLE_BYTES"{print $2}' <<<"${values}")
  swap_used_bytes=$(awk -F= '$1=="SWAP_USED_BYTES"{print $2}' <<<"${values}")
  pvc_request_bytes=$(awk -F= '$1=="PVC_REQUEST_BYTES"{print $2}' <<<"${values}")
  [[ ${available_bytes} =~ ^[0-9]+$ && ${swap_used_bytes} =~ ^[0-9]+$ &&
     ${pvc_request_bytes} =~ ^[0-9]+$ ]] || fail capacity "${prefix} RAM/PVC 측정값을 읽지 못했다."
  (( available_bytes >= available_stop_bytes )) || fail capacity "${prefix} k3s available RAM이 8 GiB 정지선 아래다."
  (( swap_used_bytes == 0 )) || fail capacity "${prefix} k3s swap 사용량이 0이 아니다."
}

if [[ ${mode} == capacity-pre ]]; then
  capacity=$(measure_capacity)
  capacity_gate PRE "${capacity}"
  traefik=$(measure_traefik) || fail preflight 'HelmChartConfig/Traefik 기준값을 읽지 못했다.'
  printf '%s\n%s\n' "${capacity}" "${traefik}"
  echo 'OBS02_CAPACITY_PRE=PASS'
  exit 0
fi

readonly expected_root_revision=${OBS02_EXPECTED_ROOT_REVISION:?root pointer SHA가 필요하다}
readonly expected_obs_revision=${OBS02_EXPECTED_OBS_REVISION:?obs settings SHA가 필요하다}
readonly expected_pomerium_revision=${OBS02_EXPECTED_POMERIUM_REVISION:?pomerium settings SHA가 필요하다}
readonly pre_available_bytes=${OBS02_PRE_AVAILABLE_BYTES:?배포 전 available bytes가 필요하다}
readonly pre_pvc_request_bytes=${OBS02_PRE_PVC_REQUEST_BYTES:?배포 전 PVC 합계가 필요하다}
readonly pre_hcc_generation=${OBS02_PRE_HELMCHARTCONFIG_GENERATION:?배포 전 HelmChartConfig generation이 필요하다}
readonly pre_traefik_uid=${OBS02_PRE_TRAEFIK_POD_UID:?배포 전 Traefik Pod UID가 필요하다}
readonly pre_traefik_restarts=${OBS02_PRE_TRAEFIK_RESTARTS:?배포 전 Traefik restart count가 필요하다}

[[ ${expected_root_revision} =~ ^[0-9a-f]{40}$ && ${expected_obs_revision} =~ ^[0-9a-f]{40}$ &&
   ${expected_pomerium_revision} =~ ^[0-9a-f]{40}$ ]] || fail argo 'immutable SHA 형식이 아니다.'
[[ ${pre_available_bytes} =~ ^[0-9]+$ && ${pre_pvc_request_bytes} =~ ^[0-9]+$ &&
   ${pre_hcc_generation} =~ ^[0-9]+$ && ${pre_traefik_restarts} =~ ^[0-9]+$ ]] || fail preflight '배포 전 기준값 형식이 아니다.'

argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root obs pomerium -o json 2>/dev/null || true)
  if jq -e \
    --arg root "${expected_root_revision}" \
    --arg obs "${expected_obs_revision}" \
    --arg pomerium "${expected_pomerium_revision}" '
      ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
      ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
      ([.items[] | select(.metadata.name == "pomerium")][0] // {}) as $pomerium_app |
      $root_app.spec.source.targetRevision == $root and
      $root_app.status.sync.revision == $root and
      $root_app.status.sync.status == "Synced" and
      $root_app.status.health.status == "Healthy" and
      $obs_app.spec.source.targetRevision == $obs and
      $obs_app.status.sync.revision == $obs and
      $obs_app.status.sync.status == "Synced" and
      $obs_app.status.health.status == "Healthy" and
      $pomerium_app.spec.source.targetRevision == $pomerium and
      $pomerium_app.status.sync.revision == $pomerium and
      $pomerium_app.status.sync.status == "Synced" and
      $pomerium_app.status.health.status == "Healthy"
    ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e \
  --arg root "${expected_root_revision}" \
  --arg obs "${expected_obs_revision}" \
  --arg pomerium "${expected_pomerium_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
    ([.items[] | select(.metadata.name == "pomerium")][0] // {}) as $pomerium_app |
    $root_app.spec.source.targetRevision == $root and $root_app.status.sync.revision == $root and
    $root_app.status.sync.status == "Synced" and $root_app.status.health.status == "Healthy" and
    $obs_app.spec.source.targetRevision == $obs and $obs_app.status.sync.revision == $obs and
    $obs_app.status.sync.status == "Synced" and $obs_app.status.health.status == "Healthy" and
    $pomerium_app.spec.source.targetRevision == $pomerium and $pomerium_app.status.sync.revision == $pomerium and
    $pomerium_app.status.sync.status == "Synced" and $pomerium_app.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null || fail argo 'root/obs/pomerium이 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} obs=${expected_obs_revision} pomerium=${expected_pomerium_revision}"

for workload in deployment/obs-grafana statefulset/prometheus-obs-prometheus statefulset/alertmanager-obs-alertmanager deployment/pomerium; do
  namespace=obs
  [[ ${workload} == deployment/pomerium ]] && namespace=pomerium
  remote_kubectl -n "${namespace}" rollout status "${workload}" --timeout=180s >/dev/null \
    || fail deployment "${namespace}/${workload}가 Ready가 아니다."
done

wait_for_route_tls

: "${OBS02_DENY_USERNAME:?platform-users 미소속 계정 이름이 필요하다}"
: "${OBS02_DENY_PASSWORD_FILE:?platform-users 미소속 계정 password file이 필요하다}"
: "${OBS02_DENY_TOTP_FILE:?platform-users 미소속 계정 TOTP file이 필요하다}"
python3 "${repo_root}/gitops/tools/obs-02/verify-routes.py" \
  --repo-root "${repo_root}" \
  --connect-ip "${connect_ip}" \
  --user-username "${OBS02_USER_USERNAME:-imcherry}" \
  --user-password-file "${KC01_USER_PASSWORD_FILE:-${kc_secret_dir}/daily-password}" \
  --user-totp-file "${KC01_USER_TOTP_FILE:-${kc_secret_dir}/daily-totp}" \
  --deny-username "${OBS02_DENY_USERNAME}" \
  --deny-password-file "${OBS02_DENY_PASSWORD_FILE}" \
  --deny-totp-file "${OBS02_DENY_TOTP_FILE}" \
  --privileged-username "${OBS02_PRIVILEGED_USERNAME:-imcherry-admin}" \
  --privileged-password-file "${KC01_PRIVILEGED_PASSWORD_FILE:-${kc_secret_dir}/privileged-password}" \
  --privileged-totp-file "${KC01_PRIVILEGED_TOTP_FILE:-${kc_secret_dir}/privileged-totp}" \
  --grafana-password-file "${grafana_password_file}"

post_capacity=$(measure_capacity)
capacity_gate POST "${post_capacity}"
post_available_bytes=$(awk -F= '$1=="AVAILABLE_BYTES"{print $2}' <<<"${post_capacity}")
post_pvc_request_bytes=$(awk -F= '$1=="PVC_REQUEST_BYTES"{print $2}' <<<"${post_capacity}")
(( post_pvc_request_bytes == pre_pvc_request_bytes )) \
  || fail capacity 'OBS-02 뒤 신규 PVC 선언이 생겼다.'
post_traefik=$(measure_traefik) || fail ingress 'HelmChartConfig/Traefik 적용 후 기준값을 읽지 못했다.'
post_hcc_generation=$(awk -F= '$1=="HELMCHARTCONFIG_GENERATION"{print $2}' <<<"${post_traefik}")
post_traefik_uid=$(awk -F= '$1=="TRAEFIK_POD_UID"{print $2}' <<<"${post_traefik}")
post_traefik_restarts=$(awk -F= '$1=="TRAEFIK_RESTARTS"{print $2}' <<<"${post_traefik}")
[[ ${post_hcc_generation} == "${pre_hcc_generation}" && ${post_traefik_uid} == "${pre_traefik_uid}" &&
   ${post_traefik_restarts} == "${pre_traefik_restarts}" ]] \
  || fail ingress 'HelmChartConfig generation 또는 Traefik Pod UID/restart가 바뀌었다.'
printf 'Capacity=PASS PRE_AVAILABLE_BYTES=%s POST_AVAILABLE_BYTES=%s PRE_PVC_REQUEST_BYTES=%s POST_PVC_REQUEST_BYTES=%s\n' \
  "${pre_available_bytes}" "${post_available_bytes}" "${pre_pvc_request_bytes}" "${post_pvc_request_bytes}"
echo "Ingress=PASS HelmChartConfigGeneration=${post_hcc_generation} TraefikUID=unchanged Restarts=${post_traefik_restarts}"
echo 'OBS02_VERIFY=PASS'
