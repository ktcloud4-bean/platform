#!/usr/bin/env bash
# immutable Argo SHA에서 TRAEFIK-METRICS를 검증하고, 리소스를 먼저 prune한 뒤 literal main으로 복구한다.
set -Eeuo pipefail

readonly repo_root=$(git rev-parse --show-toplevel)
readonly mode=${1:-apply}
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly main_revision=${TRAEFIK_METRICS_MAIN_REVISION:?시작 main SHA가 필요하다}
readonly cleanup_root_revision=${TRAEFIK_METRICS_CLEANUP_ROOT_REVISION:?cleanup root pointer SHA가 필요하다}
readonly config_revision=${TRAEFIK_METRICS_CONFIG_REVISION:-}
readonly root_revision=${TRAEFIK_METRICS_ROOT_REVISION:-}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ ${mode} == apply || ${mode} == cleanup ]] || {
  echo 'usage: apply-live.sh [apply|cleanup]' >&2
  exit 2
}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'TRAEFIK-METRICS 적용 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}
for revision in "${main_revision}" "${cleanup_root_revision}"; do
  [[ ${revision} =~ ^[0-9a-f]{40}$ ]] || {
    echo 'TRAEFIK-METRICS 적용 실패 단계=preflight 원인=immutable SHA 형식이 아니다.' >&2
    exit 1
  }
done
if [[ ${mode} == apply ]]; then
  for revision in "${config_revision}" "${root_revision}"; do
    [[ ${revision} =~ ^[0-9a-f]{40}$ ]] || {
      echo 'TRAEFIK-METRICS 적용 실패 단계=preflight 원인=immutable SHA 형식이 아니다.' >&2
      exit 1
    }
  done
fi

exec 9>/tmp/ktcloud4-bean-argo-root.lock
flock -n 9 || {
  echo 'TRAEFIK-METRICS 적용 실패 단계=lock 원인=다른 ARGO-ROOT 작업이 실행 중이다.' >&2
  exit 1
}
exec 8>/tmp/ktcloud4-bean-traefik-live.lock
flock -n 8 || {
  echo 'TRAEFIK-METRICS 적용 실패 단계=lock 원인=다른 TRAEFIK-LIVE 작업이 실행 중이다.' >&2
  exit 1
}

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" sudo -n /usr/local/bin/k3s kubectl "$@"
}

patch_root_revision() {
  local revision=$1
  ssh "${ssh_options[@]}" "${k3s_host}" bash -s -- "${revision}" <<'REMOTE'
set -Eeuo pipefail
revision=$1
sudo -n /usr/local/bin/k3s kubectl -n argocd patch applications.argoproj.io platform-root --type=merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"${revision}\"}}}"
REMOTE
}

main_state_matches() {
  remote_kubectl -n argocd get applications.argoproj.io platform-root ingress obs -o json | jq -e --arg main "${main_revision}" '
    [.items[] | {name: .metadata.name, target: .spec.source.targetRevision, revision: .status.sync.revision, sync: .status.sync.status, health: .status.health.status}] as $apps |
    ($apps | length == 3) and ($apps | all(.[]; .target == "main" and .revision == $main and .sync == "Synced" and .health == "Healthy"))
  ' >/dev/null
}

wait_for_main_restore() {
  for _ in $(seq 1 72); do
    if main_state_matches 2>/dev/null; then
      echo "Rollback=PASS root_ingress_obs=main revision=${main_revision}"
      return 0
    fi
    sleep 5
  done
  echo 'TRAEFIK-METRICS 적용 실패 단계=rollback 원인=platform-root/ingress/obs가 main에서 Synced/Healthy로 복구되지 않았다.' >&2
  return 1
}

cleanup_state_matches() {
  remote_kubectl -n argocd get applications.argoproj.io platform-root ingress obs -o json | jq -e --arg cleanup "${cleanup_root_revision}" --arg main "${main_revision}" '
    [.items[] | {name: .metadata.name, target: .spec.source.targetRevision, revision: .status.sync.revision, sync: .status.sync.status, health: .status.health.status}] as $apps |
    ($apps | length == 3) and
    ($apps | any(.[]; .name == "platform-root" and .target == $cleanup and .revision == $cleanup and .sync == "Synced" and .health == "Healthy")) and
    ($apps | map(select(.name != "platform-root")) | all(.[]; .target == "main" and .revision == $main and .sync == "Synced" and .health == "Healthy"))
  ' >/dev/null
}

cleanup_recovery_state_matches() {
  remote_kubectl -n argocd get applications.argoproj.io platform-root ingress obs -o json | jq -e --arg main "${main_revision}" '
    [.items[] | {name: .metadata.name, target: .spec.source.targetRevision, revision: .status.sync.revision, sync: .status.sync.status, health: .status.health.status}] as $apps |
    ($apps | length == 3) and
    ($apps | any(.[]; .name == "platform-root" and .target == .revision and .sync == "Synced" and .health == "Healthy")) and
    ($apps | map(select(.name != "platform-root")) | all(.[]; .target == "main" and .revision == $main and .sync == "Synced" and .health == "Healthy"))
  ' >/dev/null
}

cleanup_resources_absent() {
  local deployment service servicemonitor policy
  deployment=$(remote_kubectl -n kube-system get deployment traefik -o json) || return 1
  service=$(remote_kubectl -n kube-system get service traefik-metrics -o name 2>/dev/null || true)
  servicemonitor=$(remote_kubectl -n obs get servicemonitor obs-traefik -o name 2>/dev/null || true)
  policy=$(remote_kubectl -n obs get networkpolicy obs-prometheus-scrape-egress -o json) || return 1
  [[ -z ${service} && -z ${servicemonitor} ]] || return 1
  jq -e '
    [.spec.template.spec.containers[] | select(.name == "traefik") | .args[]?] as $args |
    ($args | index("--metrics.prometheus.addRoutersLabels=true") | not)
  ' <<<"${deployment}" >/dev/null || return 1
  jq -e '
    any(.spec.egress[];
      .to == [{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}}, "podSelector":{"matchLabels":{"app.kubernetes.io/name":"traefik"}}}] and
      .ports == [{"protocol":"TCP", "port":9100}]
    ) | not
  ' <<<"${policy}" >/dev/null
}

wait_for_cleanup_root() {
  for _ in $(seq 1 72); do
    if cleanup_state_matches 2>/dev/null && cleanup_resources_absent 2>/dev/null; then
      echo "Cleanup=PASS root=${cleanup_root_revision} resources=pruned"
      return 0
    fi
    sleep 5
  done
  echo 'TRAEFIK-METRICS 적용 실패 단계=cleanup 원인=private metrics 리소스와 Traefik 설정을 main 기준으로 prune하지 못했다.' >&2
  return 1
}

root_patched=false
cleanup_to_main() {
  patch_root_revision "${cleanup_root_revision}" >/dev/null || return 1
  wait_for_cleanup_root || return 1
  patch_root_revision main >/dev/null || return 1
  wait_for_main_restore || return 1
  root_patched=false
}

restore() {
  local status=$?
  trap - EXIT
  if [[ ${root_patched} == true ]]; then
    cleanup_to_main || status=1
  fi
  exit "${status}"
}
trap restore EXIT

if [[ ${mode} == cleanup ]]; then
  (main_state_matches || cleanup_recovery_state_matches) || {
    echo 'TRAEFIK-METRICS 적용 실패 단계=preflight 원인=cleanup 가능한 root/ingress/obs 상태가 아니다.' >&2
    exit 1
  }
  root_patched=true
  cleanup_to_main
  exit 0
fi

main_state_matches || {
  echo 'TRAEFIK-METRICS 적용 실패 단계=preflight 원인=platform-root/ingress/obs가 시작 main에서 Synced/Healthy가 아니다.' >&2
  exit 1
}

capacity=$("${repo_root}/gitops/tools/traefik-metrics/verify-live.sh" capacity-pre)
printf '%s\n' "${capacity}"

patch_root_revision "${root_revision}" >/dev/null
root_patched=true

TRAEFIK_METRICS_ARGO_LOCK_HELD=true \
TRAEFIK_METRICS_TRAEFIK_LOCK_HELD=true \
TRAEFIK_METRICS_EXPECTED_ROOT_REVISION="${root_revision}" \
TRAEFIK_METRICS_EXPECTED_INGRESS_REVISION="${config_revision}" \
TRAEFIK_METRICS_EXPECTED_OBS_REVISION="${config_revision}" \
TRAEFIK_METRICS_PRE_HEAD_SERIES="$(awk -F= '$1 == "HEAD_SERIES" {print $2}' <<<"${capacity}")" \
TRAEFIK_METRICS_PRE_PROMETHEUS_WORKING_SET="$(awk -F= '$1 == "PROMETHEUS_WORKING_SET" {print $2}' <<<"${capacity}")" \
TRAEFIK_METRICS_PRE_AVAILABLE_BYTES="$(awk -F= '$1 == "AVAILABLE_BYTES" {print $2}' <<<"${capacity}")" \
TRAEFIK_METRICS_PRE_TRAEFIK_POD_UID="$(awk -F= '$1 == "TRAEFIK_POD_UID" {print $2}' <<<"${capacity}")" \
TRAEFIK_METRICS_PRE_KUBE_SYSTEM_SERVICE_COUNT="$(awk -F= '$1 == "KUBE_SYSTEM_SERVICE_COUNT" {print $2}' <<<"${capacity}")" \
TRAEFIK_METRICS_PRE_OBS_SERVICEMONITOR_COUNT="$(awk -F= '$1 == "OBS_SERVICEMONITOR_COUNT" {print $2}' <<<"${capacity}")" \
TRAEFIK_METRICS_PRE_OBS_NETWORKPOLICY_COUNT="$(awk -F= '$1 == "OBS_NETWORKPOLICY_COUNT" {print $2}' <<<"${capacity}")" \
TRAEFIK_METRICS_PRE_OBS_PVC_COUNT="$(awk -F= '$1 == "OBS_PVC_COUNT" {print $2}' <<<"${capacity}")" \
TRAEFIK_METRICS_PRE_OBS_SECRET_COUNT="$(awk -F= '$1 == "OBS_SECRET_COUNT" {print $2}' <<<"${capacity}")" \
TRAEFIK_METRICS_PRE_OBS_INGRESS_COUNT="$(awk -F= '$1 == "OBS_INGRESS_COUNT" {print $2}' <<<"${capacity}")" \
  "${repo_root}/gitops/tools/traefik-metrics/verify-live.sh"
