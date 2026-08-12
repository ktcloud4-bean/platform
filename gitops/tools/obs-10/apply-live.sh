#!/usr/bin/env bash
# OBS-10을 immutable Argo SHA에서 검증하고 literal main으로 반드시 복구한다.
set -Eeuo pipefail

readonly repo_root=$(git rev-parse --show-toplevel)
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly main_revision=${OBS10_MAIN_REVISION:?시작 main SHA가 필요하다}
readonly config_revision=${OBS10_CONFIG_REVISION:?obs 설정 commit SHA가 필요하다}
readonly root_revision=${OBS10_ROOT_REVISION:?immutable root pointer SHA가 필요하다}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'OBS-10 적용 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}
for revision in "${main_revision}" "${config_revision}" "${root_revision}"; do
  [[ ${revision} =~ ^[0-9a-f]{40}$ ]] || {
    echo 'OBS-10 적용 실패 단계=preflight 원인=immutable SHA 형식이 아니다.' >&2
    exit 1
  }
done

exec 9>/tmp/ktcloud4-bean-argo-root.lock
flock -n 9 || {
  echo 'OBS-10 적용 실패 단계=lock 원인=다른 ARGO-ROOT 작업이 실행 중이다.' >&2
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
  remote_kubectl -n argocd get applications.argoproj.io platform-root obs -o json | jq -e --arg main "${main_revision}" '
    [.items[] | {name: .metadata.name, target: .spec.source.targetRevision, revision: .status.sync.revision, sync: .status.sync.status, health: .status.health.status}] as $apps |
    ($apps | length == 2) and ($apps | all(.[]; .target == "main" and .revision == $main and .sync == "Synced" and .health == "Healthy"))
  ' >/dev/null
}

wait_for_main_restore() {
  for _ in $(seq 1 72); do
    if main_state_matches 2>/dev/null; then
      echo "Rollback=PASS root_obs=main revision=${main_revision}"
      return 0
    fi
    sleep 5
  done
  echo 'OBS-10 적용 실패 단계=rollback 원인=platform-root/obs가 main에서 Synced/Healthy로 복구되지 않았다.' >&2
  return 1
}

root_patched=false
restore() {
  local status=$?
  trap - EXIT
  if [[ ${root_patched} == true ]]; then
    patch_root_revision main >/dev/null || status=1
    wait_for_main_restore || status=1
  fi
  exit "${status}"
}
trap restore EXIT

main_state_matches || {
  echo 'OBS-10 적용 실패 단계=preflight 원인=platform-root/obs가 시작 main에서 Synced/Healthy가 아니다.' >&2
  exit 1
}

scope=$("${repo_root}/gitops/tools/obs-10/verify-live.sh" scope-pre)
printf '%s\n' "${scope}"

patch_root_revision "${root_revision}" >/dev/null
root_patched=true

OBS10_EXPECTED_CONFIG_REVISION="${config_revision}" \
OBS10_EXPECTED_ROOT_REVISION="${root_revision}" \
OBS10_PRE_TRAEFIK_POD_UID="$(awk -F= '$1 == "TRAEFIK_POD_UID" {print $2}' <<<"${scope}")" \
OBS10_PRE_GRAFANA_POD_UID="$(awk -F= '$1 == "GRAFANA_POD_UID" {print $2}' <<<"${scope}")" \
OBS10_PRE_SERVICE_COUNT="$(awk -F= '$1 == "OBS_SERVICE_COUNT" {print $2}' <<<"${scope}")" \
OBS10_PRE_SERVICEMONITOR_COUNT="$(awk -F= '$1 == "OBS_SERVICEMONITOR_COUNT" {print $2}' <<<"${scope}")" \
OBS10_PRE_NETWORKPOLICY_COUNT="$(awk -F= '$1 == "OBS_NETWORKPOLICY_COUNT" {print $2}' <<<"${scope}")" \
OBS10_PRE_PVC_COUNT="$(awk -F= '$1 == "OBS_PVC_COUNT" {print $2}' <<<"${scope}")" \
OBS10_PRE_SECRET_COUNT="$(awk -F= '$1 == "OBS_SECRET_COUNT" {print $2}' <<<"${scope}")" \
OBS10_PRE_INGRESS_COUNT="$(awk -F= '$1 == "OBS_INGRESS_COUNT" {print $2}' <<<"${scope}")" \
  "${repo_root}/gitops/tools/obs-10/verify-live.sh"
