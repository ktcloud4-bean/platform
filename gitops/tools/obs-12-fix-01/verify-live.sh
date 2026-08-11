#!/usr/bin/env bash
# OBS-12-FIX-01의 Grafana 변수 datasource 바인딩만 판정한다.
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly expected_config_revision=${OBS12_FIX01_EXPECTED_CONFIG_REVISION:?obs 설정 commit SHA가 필요하다}
readonly expected_root_revision=${OBS12_FIX01_EXPECTED_ROOT_REVISION:?platform-root pointer SHA가 필요하다}
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
)

fail() {
  local stage=$1
  shift
  echo "OBS-12-FIX-01 검증 실패 단계=${stage} 원인=$*" >&2
  exit 1
}

[[ -f ${known_hosts} && ! -L ${known_hosts} ]] \
  || fail preflight '인증된 k3s known_hosts 파일이 없다.'
[[ ${expected_config_revision} =~ ^[0-9a-f]{40}$ && ${expected_root_revision} =~ ^[0-9a-f]{40}$ ]] \
  || fail preflight 'immutable SHA 형식이 아니다.'

remote_kubectl() {
  ssh "${ssh_options[@]}" "${k3s_host}" sudo -n /usr/local/bin/k3s kubectl "$@"
}

grafana_dashboard() {
  # $()은 Grafana Pod의 sh에서만 확장한다. ssh 인수로 넘기면 k3s host에서 확장될 수 있다.
  ssh "${ssh_options[@]}" "${k3s_host}" 'bash -se' <<'REMOTE'
sudo -n /usr/local/bin/k3s kubectl -n obs exec deploy/obs-grafana -c grafana -- sh -ec 'curl --fail --silent --show-error -u "admin:$(cat /vault/secrets/admin-password)" http://127.0.0.1:3000/api/dashboards/uid/obs-12-argocd-applications'
REMOTE
}

dashboard_matches() {
  jq -e '
    ([.dashboard.panels[]? | (.targets // [])[]? | .expr // ""] | join("\n")) as $queries |
    (.dashboard.uid == "obs-12-argocd-applications" and
     .dashboard.title == "ArgoCD / Application / Overview" and
     .dashboard.editable == false and
     ($queries | contains("argocd_app_info")) and
     ($queries | contains("argocd_app_sync_total")) and
     ($queries | contains("dest_namespace")) and
     ($queries | contains("exported_namespace") | not) and
     ($queries | contains("cluster=\"$cluster\"") | not) and
     ([.dashboard.templating.list[]? | .datasource.uid] | length == 6 and all(.[]; . == "prometheus")) and
     ((.dashboard | tostring) | contains("${datasource}") | not) and
     ([.dashboard.templating.list[]? | .name] | sort == ["application", "application_namespace", "job", "kubernetes_cluster", "namespace", "project"]) and
     any(.dashboard.templating.list[]?; .name == "kubernetes_cluster" and (.query | contains("dest_server"))))
  ' >/dev/null
}

argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(remote_kubectl -n argocd get applications.argoproj.io platform-root obs -o json 2>/dev/null || true)
  if jq -e --arg root_revision "${expected_root_revision}" --arg config_revision "${expected_config_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
    $root_app.spec.source.targetRevision == $root_revision and
    $root_app.status.sync.revision == $root_revision and
    $root_app.status.sync.status == "Synced" and
    $root_app.status.health.status == "Healthy" and
    $obs_app.spec.source.targetRevision == $config_revision and
    $obs_app.status.sync.revision == $config_revision and
    $obs_app.status.sync.status == "Synced" and
    $obs_app.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e --arg root_revision "${expected_root_revision}" --arg config_revision "${expected_config_revision}" '
  ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
  ([.items[] | select(.metadata.name == "obs")][0] // {}) as $obs_app |
  $root_app.spec.source.targetRevision == $root_revision and
  $root_app.status.sync.revision == $root_revision and
  $root_app.status.sync.status == "Synced" and
  $root_app.status.health.status == "Healthy" and
  $obs_app.spec.source.targetRevision == $config_revision and
  $obs_app.status.sync.revision == $config_revision and
  $obs_app.status.sync.status == "Synced" and
  $obs_app.status.health.status == "Healthy"
' <<<"${argo_state}" >/dev/null || fail argo 'platform-root 또는 obs가 immutable SHA에서 Synced/Healthy가 아니다.'
echo "Argo=PASS root=${expected_root_revision} obs=${expected_config_revision}"

remote_kubectl -n obs rollout status deployment/obs-grafana --timeout=180s >/dev/null \
  || fail grafana 'Grafana가 Ready가 아니다.'

dashboard=''
for _ in $(seq 1 36); do
  dashboard=$(grafana_dashboard 2>/dev/null || true)
  if [[ -n ${dashboard} ]] && dashboard_matches <<<"${dashboard}" 2>/dev/null; then
    break
  fi
  sleep 5
done
dashboard_matches <<<"${dashboard}" \
  || fail grafana 'OBS-12 dashboard UID·변수 datasource·정규화 query가 일치하지 않는다.'
echo 'Grafana=PASS uid=obs-12-argocd-applications editable=false variables=prometheus queries=normalized'
echo 'OBS12_FIX01_VERIFY=PASS'
