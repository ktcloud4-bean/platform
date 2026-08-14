#!/usr/bin/env bash
# AWX-07을 immutable root/child SHA에 올려 사람 승인 전까지 유지하거나, 완료 뒤 literal main으로 복원한다.
set -Eeuo pipefail

mode=${1:-}
[[ ${mode} == prepare-immutable || ${mode} == restore-main ]] || { echo "사용법: $0 prepare-immutable|restore-main" >&2; exit 2; }

readonly repo_root=$(git rev-parse --show-toplevel)
readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly main_revision=${AWX07_MAIN_REVISION:?시작 main SHA가 필요하다}
readonly config_revision=${AWX07_CONFIG_REVISION:?AWX-07 선언 commit SHA가 필요하다}
readonly root_revision=${AWX07_ROOT_REVISION:?immutable root pointer SHA가 필요하다}
ssh_options=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=${known_hosts}")

for revision in "${main_revision}" "${config_revision}" "${root_revision}"; do
  [[ ${revision} =~ ^[0-9a-f]{40}$ ]] || { echo "AWX-07 immutable SHA 형식이 아니다" >&2; exit 1; }
done
[[ -r ${known_hosts} && ! -L ${known_hosts} ]] || { echo "인증된 k3s known_hosts 파일을 읽을 수 없다" >&2; exit 1; }
exec 9>/tmp/ktcloud4-bean-argo-root.lock
flock -n 9 || { echo "AWX-07 중지: 다른 ARGO-ROOT 작업이 실행 중이다" >&2; exit 1; }

remote_kubectl() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }
patch_root_revision() {
  local revision=$1
  ssh "${ssh_options[@]}" "${k3s_host}" bash -s -- "${revision}" <<'REMOTE'
set -Eeuo pipefail
revision=$1
sudo -n /usr/local/bin/k3s kubectl -n argocd patch applications.argoproj.io platform-root --type=merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"${revision}\"}}}"
REMOTE
}
state_matches() {
  local root_target=$1 root_sync=$2 child_target=$3 child_sync=$4
  remote_kubectl -n argocd get applications.argoproj.io platform-root awx -o json | jq -e \
    --arg root_target "${root_target}" --arg root_sync "${root_sync}" --arg child_target "${child_target}" --arg child_sync "${child_sync}" '
      . as $doc | def app($name): $doc.items[] | select(.metadata.name == $name);
      (app("platform-root") | .spec.source.targetRevision == $root_target and .status.sync.revision == $root_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded") and
      (app("awx") | .spec.source.targetRevision == $child_target and .status.sync.revision == $child_sync and .status.sync.status == "Synced" and .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded")
    ' >/dev/null
}
wait_for_state() {
  local root_target=$1 root_sync=$2 child_target=$3 child_sync=$4 label=$5
  for _ in $(seq 1 72); do
    state_matches "${root_target}" "${root_sync}" "${child_target}" "${child_sync}" 2>/dev/null && return 0
    sleep 5
  done
  echo "AWX-07 실패 단계=argo 원인=${label}가 Synced/Healthy/Succeeded가 아니다" >&2
  return 1
}
starting_state_matches() { state_matches main "${main_revision}" main "${main_revision}"; }
root_patched=false
prepared=false
success=false

prepare_immutable() {
  root_patched=false
  prepared=false
  success=false
  restore_failure() {
    local status=$?
    trap - EXIT
    if [[ ${root_patched:-false} == true ]]; then
      patch_root_revision main >/dev/null || status=1
      wait_for_state main "${main_revision}" main "${main_revision}" rollback || status=1
    fi
    if [[ ${prepared:-false} == true ]]; then
      AWX07_ROLLBACK_REVISION="${main_revision}" "${repo_root}/gitops/tools/awx-07/prepare-live.sh" --rollback || status=1
    fi
    [[ ${success:-false} == true ]] && status=0
    exit "${status}"
  }
  trap restore_failure EXIT
  starting_state_matches || { echo "AWX-07 중지: platform-root/AWX가 시작 main SHA에서 Synced/Healthy/Succeeded가 아니다" >&2; exit 1; }
  AWX07_ROLLBACK_REVISION="${main_revision}" "${repo_root}/gitops/tools/awx-07/prepare-live.sh" --apply
  prepared=true
  patch_root_revision "${root_revision}" >/dev/null
  root_patched=true
  wait_for_state "${root_revision}" "${root_revision}" "${config_revision}" "${config_revision}" immutable
  AWX07_EXPECTED_ROOT_REVISION="${root_revision}" AWX07_EXPECTED_ROOT_SYNC_REVISION="${root_revision}" \
  AWX07_EXPECTED_CHILD_REVISION="${config_revision}" AWX07_EXPECTED_CHILD_SYNC_REVISION="${config_revision}" \
  AWX07_EXPECTED_SCM_REVISION="${main_revision}" "${repo_root}/gitops/tools/awx-07/verify-live.sh" platform
  success=true
  trap - EXIT
  printf 'AWX07_IMMUTABLE_READY=PASS main=%s config=%s root=%s approval=required\n' "${main_revision}" "${config_revision}" "${root_revision}"
}

restore_main() {
  patch_root_revision main >/dev/null
  wait_for_state main "${main_revision}" main "${main_revision}" rollback
  printf 'AWX07_MAIN_RESTORED=PASS main=%s root=main child=main\n' "${main_revision}"
}

case ${mode} in
  prepare-immutable) prepare_immutable ;;
  restore-main) restore_main ;;
esac
