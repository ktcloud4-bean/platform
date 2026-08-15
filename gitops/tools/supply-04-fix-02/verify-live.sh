#!/usr/bin/env bash
# SUPPLY-04-FIX-02: remove the completed bootstrap Job from the runtime app.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly main_revision=${SUPPLY04FIX02_MAIN_REVISION:?main SHA is required}
readonly config_revision=${SUPPLY04FIX02_CONFIG_REVISION:?configuration SHA is required}
readonly root_revision=${SUPPLY04FIX02_ROOT_REVISION:?immutable root SHA is required}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

fail() {
  echo "SUPPLY-04-FIX-02 검증 실패 단계=$1 원인=$2" >&2
  exit 1
}

for revision in "$main_revision" "$config_revision" "$root_revision"; do
  [[ $revision =~ ^[0-9a-f]{40}$ ]] || fail preflight 'immutable SHA 형식이 아니다.'
done
[[ -f $known_hosts && ! -L $known_hosts ]] || fail preflight '인증된 k3s known_hosts 파일이 없다.'

exec 9>/tmp/ktcloud4-bean-argo-root.lock
flock -n 9 || fail lock '다른 ARGO-ROOT 작업이 실행 중이다.'

remote_kubectl() {
  ssh "${ssh_options[@]}" "$k3s_host" sudo -n /usr/local/bin/k3s kubectl "$@"
}

patch_root_revision() {
  local revision=$1
  ssh "${ssh_options[@]}" "$k3s_host" bash -s -- "$revision" <<'REMOTE'
set -Eeuo pipefail
revision=$1
sudo -n /usr/local/bin/k3s kubectl -n argocd patch applications.argoproj.io platform-root --type=merge \
  -p "{\"spec\":{\"source\":{\"targetRevision\":\"$revision\"}}}"
REMOTE
}

main_state_matches() {
  remote_kubectl -n argocd get applications.argoproj.io platform-root keycloak -o json \
    | jq -e --arg main "$main_revision" '
      ([.items[] | select(.metadata.name == "platform-root")][0]) as $root |
      ([.items[] | select(.metadata.name == "keycloak")][0]) as $keycloak |
      $root.spec.source.targetRevision == "main" and
      $root.status.sync.revision == $main and
      $root.status.sync.status == "Synced" and
      $root.status.health.status == "Healthy" and
      $keycloak.spec.source.targetRevision == "main" and
      $keycloak.status.sync.revision == $main and
      $keycloak.status.sync.status == "Synced" and
      $keycloak.status.health.status == "Healthy"
    ' >/dev/null
}

immutable_state_matches() {
  remote_kubectl -n argocd get applications.argoproj.io platform-root keycloak -o json \
    | jq -e --arg expected_root "$root_revision" --arg expected_config "$config_revision" \
      --argjson root_before "$root_history_before" --argjson keycloak_before "$keycloak_history_before" '
      ([.items[] | select(.metadata.name == "platform-root")][0]) as $root |
      ([.items[] | select(.metadata.name == "keycloak")][0]) as $keycloak |
      $root.spec.source.targetRevision == $expected_root and
      $keycloak.spec.source.targetRevision == $expected_config and
      ($root.status.history[-1].id > $root_before) and
      ($keycloak.status.history[-1].id > $keycloak_before) and
      ($root.status.history[-1].revision == $expected_root) and
      ($keycloak.status.history[-1].revision == $expected_config)
    ' >/dev/null
}

wait_for() {
  local expected=$1
  for _ in $(seq 1 36); do
    if [[ $expected == main ]] && main_state_matches 2>/dev/null; then return 0; fi
    if [[ $expected == immutable ]] && immutable_state_matches 2>/dev/null; then return 0; fi
    sleep 5
  done
  return 1
}

verify_runtime() {
  remote_kubectl -n keycloak get deployment keycloak -o json \
    | jq -e '.status.readyReplicas == 1 and .status.availableReplicas == 1' >/dev/null
  remote_kubectl -n keycloak get jobs -o json \
    | jq -e '[.items[].metadata.name] | (index("keycloak-bootstrap-v2") == null and index("keycloak-bootstrap-v3") == null)' >/dev/null
}

v3_completion=$(remote_kubectl -n keycloak get job keycloak-bootstrap-v3 -o json \
  | jq -er '.status.completionTime')
root_history_before=$(remote_kubectl -n argocd get application.argoproj.io platform-root -o json \
  | jq -er '.status.history[-1].id // -1')
keycloak_history_before=$(remote_kubectl -n argocd get application.argoproj.io keycloak -o json \
  | jq -er '.status.history[-1].id // -1')
main_state_matches || fail preflight 'platform-root/keycloak가 현재 main SHA에서 Synced/Healthy가 아니다.'
remote_kubectl -n keycloak get job keycloak-bootstrap-v3 -o json \
  | jq -e --arg completion "$v3_completion" '.status.succeeded == 1 and .status.completionTime == $completion' >/dev/null \
  || fail preflight '기존 v3 완료 상태가 예상과 다르다.'

root_patched=false
restore() {
  local status=$?
  trap - EXIT INT TERM HUP
  if [[ $root_patched == true ]]; then
    patch_root_revision main >/dev/null || status=1
    wait_for main || status=1
  fi
  exit "$status"
}
trap restore EXIT INT TERM HUP

patch_root_revision "$root_revision" >/dev/null
root_patched=true
wait_for immutable || fail immutable 'bootstrap Job 제거 선언이 immutable SHA에서 Synced/Healthy가 아니다.'
verify_runtime || fail runtime 'Deployment가 Ready가 아니거나 bootstrap Job이 남아 있다.'
echo "SUPPLY-04-FIX-02 Argo=PASS bootstrap=manual-boundary runtime=healthy jobs=absent"
