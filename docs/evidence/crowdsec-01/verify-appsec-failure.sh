#!/usr/bin/env bash
# 승인 뒤 CrowdSec AppSec Pod 하나만 삭제해 route-scoped fail-closed와 자동 복구를 검증한다.
set -euo pipefail

: "${CROWDSEC_01_BASE_URL:?예: https://k3s-01.imcherry5778.xyz}"
: "${K3S_SSH_TARGET:?K3S_SSH_TARGET을 지정해야 합니다}"
: "${K3S_SSH_KNOWN_HOSTS:?K3S_SSH_KNOWN_HOSTS를 지정해야 합니다}"
: "${CROWDSEC_01_APPROVE_APPSEC_FAILURE_TEST:?APPSEC-POD-DELETE-APPROVED를 지정해야 합니다}"

if [[ $CROWDSEC_01_APPROVE_APPSEC_FAILURE_TEST != APPSEC-POD-DELETE-APPROVED ]]; then
  printf '%s\n' '오류: AppSec 장애 시험 승인 문구가 일치하지 않습니다.' >&2
  exit 2
fi
if (($# != 0)); then
  printf '%s\n' '사용법: verify-appsec-failure.sh' >&2
  exit 2
fi
if [[ ! -f $K3S_SSH_KNOWN_HOSTS ]]; then
  printf '%s\n' '오류: trusted known_hosts 파일이 없습니다.' >&2
  exit 2
fi

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
mapfile -t helm_releases < <(sed -n \
  '/^[[:space:]]*helm:$/,/^[[:space:]]*destination:$/ {
    s/^[[:space:]]*releaseName:[[:space:]]*//p
  }' "$repo_root/gitops/root/crowdsec-application.yaml")
if ((${#helm_releases[@]} != 1)) ||
    [[ ! ${helm_releases[0]} =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]]; then
  printf '%s\n' '오류: CrowdSec Helm releaseName을 단일 원본에서 읽지 못했습니다.' >&2
  exit 2
fi
helm_release=${helm_releases[0]}
unset helm_releases

ssh_base=(
  ssh
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$K3S_SSH_KNOWN_HOSTS"
  -o PasswordAuthentication=no
  -o ConnectTimeout=10
  "$K3S_SSH_TARGET"
)

remote_kubectl() {
  local remote_command
  printf -v remote_command '%q ' sudo -n /usr/local/bin/k3s kubectl "$@"
  "${ssh_base[@]}" "$remote_command"
}

status() {
  local path=$1
  curl -sS -o /dev/null --max-time 10 -w '%{http_code}' \
    "${CROWDSEC_01_BASE_URL%/}$path" 2>/dev/null || true
}

appsec=$(remote_kubectl -n crowdsec-01 get pod \
  -l "k8s-app=${helm_release},type=appsec" -o json)
if [[ $(jq '.items | length' <<< "$appsec") != 1 ||
      $(jq -r '.items[0].status.containerStatuses[0].ready' <<< "$appsec") != true ]]; then
  printf '%s\n' '중단: Ready인 AppSec Pod가 정확히 하나가 아닙니다.' >&2
  exit 1
fi
appsec_name=$(jq -r '.items[0].metadata.name' <<< "$appsec")
appsec_uid=$(jq -r '.items[0].metadata.uid' <<< "$appsec")
traefik_uid=$(remote_kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik \
  -o 'jsonpath={.items[0].metadata.uid}')

remote_kubectl -n crowdsec-01 delete pod "$appsec_name" --wait=false >/dev/null

saw_fail_closed=false
for _ in {1..60}; do
  waf_status=$(status /crowdsec-01/waf/failure-test)
  control_status=$(status /crowdsec-01/control/failure-test)
  if [[ $waf_status == 403 && $control_status == 200 ]]; then
    saw_fail_closed=true
    break
  fi
  sleep 1
done
if ! $saw_fail_closed; then
  printf '%s\n' '실패: AppSec unavailable 구간의 WAF 403/control 200을 관측하지 못했습니다.' >&2
  exit 1
fi

remote_kubectl -n crowdsec-01 rollout status \
  "deployment/${helm_release}-appsec" --timeout=180s >/dev/null
new_appsec=$(remote_kubectl -n crowdsec-01 get pod \
  -l "k8s-app=${helm_release},type=appsec" -o json)
[[ $(jq '.items | length' <<< "$new_appsec") == 1 ]]
[[ $(jq -r '.items[0].metadata.uid' <<< "$new_appsec") != "$appsec_uid" ]]
[[ $(jq -r '.items[0].status.containerStatuses[0].restartCount' <<< "$new_appsec") == 0 ]]
[[ $(status /crowdsec-01/waf/recovered) == 200 ]]
[[ $(status /crowdsec-01/control/recovered) == 200 ]]
[[ $(remote_kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik \
  -o 'jsonpath={.items[0].metadata.uid}') == "$traefik_uid" ]]

printf '%s\n' 'PASS: AppSec Pod 삭제 중 WAF 403/control 200, 자동 재생성 뒤 WAF/control 200, Traefik UID 불변을 검증했습니다.'
