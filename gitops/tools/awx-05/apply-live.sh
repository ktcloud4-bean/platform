#!/usr/bin/env bash
# AWX-05를 root/child immutable SHA에서 한 번 실행한 뒤, 성공·실패와 관계없이
# platform-root와 AWX child를 literal main으로 복원한다.
set -Eeuo pipefail

readonly repo_root=$(git rev-parse --show-toplevel)
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly main_revision=${AWX05_MAIN_REVISION:?시작 main SHA가 필요하다}
readonly config_revision=${AWX05_CONFIG_REVISION:?AWX-05 선언 commit SHA가 필요하다}
readonly root_revision=${AWX05_ROOT_REVISION:?immutable root pointer SHA가 필요하다}
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

for revision in "${main_revision}" "${config_revision}" "${root_revision}"; do
  [[ ${revision} =~ ^[0-9a-f]{40}$ ]] || { echo "AWX-05 immutable SHA 형식이 아니다" >&2; exit 1; }
done
[[ -r ${known_hosts} && ! -L ${known_hosts} ]] || { echo "인증된 k3s known_hosts 파일을 읽을 수 없다" >&2; exit 1; }

exec 9>/tmp/ktcloud4-bean-argo-root.lock
flock -n 9 || { echo "AWX-05 중지: 다른 ARGO-ROOT 작업이 실행 중이다" >&2; exit 1; }

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"
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

app_state_matches() {
  local root_target=$1 root_sync=$2 awx_target=$3 awx_sync=$4
  remote_kubectl -n argocd get applications.argoproj.io platform-root awx -o json | jq -e \
    --arg root_target "${root_target}" --arg root_sync "${root_sync}" \
    --arg awx_target "${awx_target}" --arg awx_sync "${awx_sync}" '
      . as $doc | def app($name): $doc.items[] | select(.metadata.name == $name);
      (app("platform-root") | .spec.source.targetRevision == $root_target and .status.sync.revision == $root_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded" and .status.operationState.operation.sync.revision == $root_sync) and
      (app("awx") | .spec.source.targetRevision == $awx_target and .status.sync.revision == $awx_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded" and .status.operationState.operation.sync.revision == $awx_sync)
    ' >/dev/null
}

wait_for_app_state() {
  local root_target=$1 root_sync=$2 awx_target=$3 awx_sync=$4 label=$5
  for _ in $(seq 1 72); do
    if app_state_matches "${root_target}" "${root_sync}" "${awx_target}" "${awx_sync}" 2>/dev/null; then
      printf 'AWX05_ARGO=PASS state=%s\n' "${label}"
      return 0
    fi
    sleep 5
  done
  printf 'AWX-05 실패 단계=argo 원인=%s 상태가 Synced/Healthy/Succeeded가 아니다\n' "${label}" >&2
  return 1
}

starting_state_matches() {
  remote_kubectl -n argocd get applications.argoproj.io platform-root awx -o json | jq -e \
    --arg main "${main_revision}" '
      . as $doc | def app($name): $doc.items[] | select(.metadata.name == $name);
      ["platform-root", "awx"] | all(. as $name |
        (app($name) | .spec.source.targetRevision == "main" and .status.sync.revision == $main and
          .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded"))
    ' >/dev/null
}

root_patched=false
success=false
restore() {
  local status=$?
  trap - EXIT
  if [[ ${root_patched} == true ]]; then
    patch_root_revision main >/dev/null || status=1
    wait_for_app_state main "${main_revision}" main "${main_revision}" rollback || status=1
  fi
  if [[ ${success} != true ]]; then
    AWX05_ROLLBACK_REVISION="${main_revision}" "${repo_root}/gitops/tools/awx-05/prepare-live.sh" --rollback || status=1
  fi
  exit "${status}"
}
trap restore EXIT

starting_state_matches || {
  echo "AWX-05 중지: platform-root/AWX가 시작 main SHA에서 Synced/Healthy/Succeeded가 아니다" >&2
  exit 1
}

patch_root_revision "${root_revision}" >/dev/null
root_patched=true
wait_for_app_state "${root_revision}" "${root_revision}" "${config_revision}" "${config_revision}" immutable
AWX05_EXPECTED_ROOT_REVISION="${root_revision}" \
AWX05_EXPECTED_ROOT_SYNC_REVISION="${root_revision}" \
AWX05_EXPECTED_CHILD_REVISION="${config_revision}" \
AWX05_EXPECTED_CHILD_SYNC_REVISION="${config_revision}" \
  "${repo_root}/gitops/tools/awx-05/verify-live.sh" platform
"${repo_root}/gitops/tools/awx-05/verify-live.sh" run-canary

patch_root_revision main >/dev/null
wait_for_app_state main "${main_revision}" main "${main_revision}" rollback
root_patched=false
success=true
trap - EXIT
printf 'AWX05_IMMUTABLE=PASS main=%s config=%s root=%s restored=literal-main\n' \
  "${main_revision}" "${config_revision}" "${root_revision}"
