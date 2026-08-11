#!/usr/bin/env bash
# AWS-HR-02 완료 증거: immutable Argo 상태와 실행 중인 Dashy/Pomerium 설정만 판정한다.
set -Eeuo pipefail

readonly expected_root_revision=${1:-}
readonly expected_pomerium_revision=${2:-}
for revision in "${expected_root_revision}" "${expected_pomerium_revision}"; do
  [[ ${revision} =~ ^[0-9a-f]{40}$ ]] || {
    echo '사용법: verify-live.sh <platform-root-pointer-sha> <pomerium-config-sha>' >&2
    exit 2
  }
done

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo -n /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
[[ -f ${known_hosts} && ! -L ${known_hosts} ]] || {
  echo 'AWS-HR-02 검증 실패 단계=preflight 원인=인증된 k3s known_hosts 파일이 없다.' >&2
  exit 1
}

readonly ssh_options=(
  -n
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)
kube() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }

argo_state=''
for _ in $(seq 1 72); do
  argo_state=$(kube -n argocd get applications.argoproj.io platform-root pomerium -o json 2>/dev/null || true)
  if jq -e --arg root "${expected_root_revision}" --arg pomerium "${expected_pomerium_revision}" '
    ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
    ([.items[] | select(.metadata.name == "pomerium")][0] // {}) as $pomerium_app |
    $root_app.spec.source.targetRevision == $root and
    $root_app.status.sync.revision == $root and
    $root_app.status.sync.status == "Synced" and
    $root_app.status.health.status == "Healthy" and
    $pomerium_app.spec.source.targetRevision == $pomerium and
    $pomerium_app.status.sync.revision == $pomerium and
    $pomerium_app.status.sync.status == "Synced" and
    $pomerium_app.status.health.status == "Healthy"
  ' <<<"${argo_state}" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
jq -e --arg root "${expected_root_revision}" --arg pomerium "${expected_pomerium_revision}" '
  ([.items[] | select(.metadata.name == "platform-root")][0] // {}) as $root_app |
  ([.items[] | select(.metadata.name == "pomerium")][0] // {}) as $pomerium_app |
  $root_app.spec.source.targetRevision == $root and
  $root_app.status.sync.revision == $root and
  $root_app.status.sync.status == "Synced" and
  $root_app.status.health.status == "Healthy" and
  $pomerium_app.spec.source.targetRevision == $pomerium and
  $pomerium_app.status.sync.revision == $pomerium and
  $pomerium_app.status.sync.status == "Synced" and
  $pomerium_app.status.health.status == "Healthy"
' <<<"${argo_state}" >/dev/null || {
  echo 'AWS-HR-02 검증 실패 단계=argo 원인=platform-root/Pomerium이 immutable SHA에서 Synced/Healthy가 아니다.' >&2
  exit 1
}

deployments=$(kube -n pomerium get deployment pomerium dashy -o json)
config_maps=$(jq -r '
  .items[] |
  .spec.template.spec.volumes[]? |
  select(.configMap != null) |
  .configMap.name
' <<<"${deployments}" | sort -u)
[[ $(wc -l <<<"${config_maps}") -ge 2 ]] || {
  echo 'AWS-HR-02 검증 실패 단계=workload 원인=Pomerium/Dashy ConfigMap mount를 읽지 못했다.' >&2
  exit 1
}
configs=$(kube -n pomerium get configmap ${config_maps} -o json)
jq -e '
  ([.items[] | select(.data["conf.yml"]? != null)][0].data["conf.yml"]) as $dashy |
  ([.items[] | select(.data["config.yaml"]? != null)][0].data["config.yaml"]) as $pomerium |
  ($pomerium | split("  - name: hr-system-www")[1] | split("  - name: hr-system-admin")[0]) as $www_route |
  ($pomerium | split("  - name: hr-system-admin")[1]) as $admin_route |
  ($dashy | contains("title: HR 직원 포털") and
            contains("url: https://www.imcherry5778.xyz") and
            contains("title: HR 관리자") and
            contains("url: https://admin.imcherry5778.xyz") and
            contains("- /hr-users") and
            contains("- /hr-admins") and
            (contains("Board Demo") | not) and
            (contains("board.imcherry5778.xyz") | not)) and
  ($www_route | contains("from: https://www.imcherry5778.xyz") and
                contains("- claim/groups: /hr-users") and
                contains("- claim/groups: /hr-admins") and
                (contains("claim/groups: /platform-users") | not)) and
  ($admin_route | contains("from: https://admin.imcherry5778.xyz") and
                  contains("- claim/groups: /hr-admins"))
' <<<"${configs}" >/dev/null || {
  echo 'AWS-HR-02 검증 실패 단계=config 원인=실행 중 Dashy/Pomerium HR group 설정이 선언과 다르다.' >&2
  exit 1
}

echo 'AWS-HR-02 Argo=PASS Pomerium=PASS Dashy=PASS'
