#!/usr/bin/env bash
# OBS-15를 immutable Argo SHA에서 한 번 검증하고 literal main으로 반드시 복구한다.
set -Eeuo pipefail

repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly k3s_host=${K3S_HOST:-rocky@10.10.20.10}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly main_revision=${OBS15_MAIN_REVISION:?시작 main SHA가 필요하다}
readonly config_revision=${OBS15_CONFIG_REVISION:?obs 설정 commit SHA가 필요하다}
readonly root_revision=${OBS15_ROOT_REVISION:?immutable root pointer SHA가 필요하다}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'OBS-15 적용 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}
for revision in "${main_revision}" "${config_revision}" "${root_revision}"; do
  [[ ${revision} =~ ^[0-9a-f]{40}$ ]] || {
    echo 'OBS-15 적용 실패 단계=preflight 원인=immutable SHA 형식이 아니다.' >&2
    exit 1
  }
done

exec 9>/tmp/ktcloud4-bean-argo-root.lock
flock -n 9 || {
  echo 'OBS-15 적용 실패 단계=lock 원인=다른 ARGO-ROOT 작업이 실행 중이다.' >&2
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
    [.items[] | {target: .spec.source.targetRevision, revision: .status.sync.revision, sync: .status.sync.status, health: .status.health.status}] as $apps |
    ($apps | length == 2) and ($apps | all(.[]; .target == "main" and .revision == $main and .sync == "Synced" and .health == "Healthy"))
  ' >/dev/null
}

immutable_state_matches() {
  remote_kubectl -n argocd get applications.argoproj.io platform-root obs -o json | jq -e \
    --arg root "${root_revision}" --arg config "${config_revision}" '
      ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
      ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
      $root_app.spec.source.targetRevision == $root and $root_app.status.sync.revision == $root and
      $root_app.status.sync.status == "Synced" and $root_app.status.health.status == "Healthy" and
      $obs_app.spec.source.targetRevision == $config and $obs_app.status.sync.revision == $config and
      $obs_app.status.sync.status == "Synced" and $obs_app.status.health.status == "Healthy"
    ' >/dev/null
}

wait_for_main_restore() {
  for _ in $(seq 1 36); do
    if main_state_matches 2>/dev/null; then
      echo "Rollback=PASS root_obs=main revision=${main_revision}"
      return 0
    fi
    sleep 5
  done
  echo 'OBS-15 적용 실패 단계=rollback 원인=platform-root/obs가 main에서 Synced/Healthy로 복구되지 않았다.' >&2
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
  echo 'OBS-15 적용 실패 단계=preflight 원인=platform-root/obs가 시작 main에서 Synced/Healthy가 아니다.' >&2
  exit 1
}

patch_root_revision "${root_revision}" >/dev/null
root_patched=true

for _ in $(seq 1 36); do
  immutable_state_matches 2>/dev/null && break
  sleep 5
done
immutable_state_matches || {
  echo 'OBS-15 적용 실패 단계=deployment 원인=platform-root/obs가 immutable SHA에서 Synced/Healthy가 아니다.' >&2
  exit 1
}

OBS15_EXPECTED_CONFIG_REVISION="${config_revision}" \
OBS15_EXPECTED_ROOT_REVISION="${root_revision}" \
  "${repo_root}/gitops/tools/obs-15/verify-live.sh"
