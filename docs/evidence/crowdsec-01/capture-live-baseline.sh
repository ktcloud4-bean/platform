#!/usr/bin/env bash
# 승인 뒤 적용 직전에 기존 ingress와 Traefik 경계를 비밀 없이 고정한다. Kubernetes에는 쓰지 않는다.
set -euo pipefail

: "${CROWDSEC_01_BASE_URL:?예: https://k3s-01.imcherry5778.xyz}"
: "${K3S_SSH_TARGET:?K3S_SSH_TARGET을 지정해야 합니다}"
: "${K3S_SSH_KNOWN_HOSTS:?K3S_SSH_KNOWN_HOSTS를 지정해야 합니다}"

if (($# != 1)); then
  printf '%s\n' '사용법: capture-live-baseline.sh <새-결과-디렉터리>' >&2
  exit 2
fi
if [[ -e $1 ]]; then
  printf '오류: 기존 결과 경로를 덮어쓰지 않습니다: %s\n' "$1" >&2
  exit 2
fi
if [[ ! -f $K3S_SSH_KNOWN_HOSTS ]]; then
  printf '%s\n' '오류: trusted known_hosts 파일이 없습니다.' >&2
  exit 2
fi

mkdir -m 700 -- "$1"
output=$(realpath "$1")
host=${CROWDSEC_01_BASE_URL#https://}
host=${host%%/*}

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

remote_kubectl get ingress,ingressroute.traefik.io,middleware.traefik.io -A -o json |
  jq -S '[.items[] | {apiVersion,kind,metadata:{namespace:.metadata.namespace,name:.metadata.name},spec}]' \
  > "$output/ingress-objects.json"

remote_kubectl -n argocd get application platform-root ingress keycloak \
  -o 'custom-columns=NAME:.metadata.name,REVISION:.status.sync.revision,SYNC:.status.sync.status,HEALTH:.status.health.status' --no-headers \
  > "$output/applications.tsv"
remote_kubectl get nodes \
  -o 'custom-columns=NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,DISKPRESSURE:.status.conditions[?(@.type=="DiskPressure")].status' --no-headers \
  > "$output/nodes.tsv"
remote_kubectl get pods -A --field-selector=status.phase!=Succeeded \
  -o 'custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,READY:.status.containerStatuses[*].ready' --no-headers \
  > "$output/pods.tsv"
remote_kubectl -n kube-system get replicaset -l app.kubernetes.io/name=traefik -o json |
  jq -S '[.items[] | {metadata:{name:.metadata.name,uid:.metadata.uid,creationTimestamp:.metadata.creationTimestamp}}]' \
  > "$output/traefik-replicasets.json"

traefik=$(remote_kubectl -n kube-system get pod -l app.kubernetes.io/name=traefik -o json)
if [[ $(jq '.items | length' <<< "$traefik") != 1 ]]; then
  printf '%s\n' '오류: Traefik Pod가 정확히 하나가 아닙니다.' >&2
  exit 1
fi
traefik_deployment=$(remote_kubectl -n kube-system get deployment traefik -o json)

cert_fingerprint=$(openssl s_client -connect "$host:443" -servername "$host" </dev/null 2>/dev/null |
  openssl x509 -noout -fingerprint -sha256 | sed 's/^sha256 Fingerprint=//I')
http_result=$(curl -sS -o /dev/null --max-time 10 -w '%{http_code}\t%{redirect_url}' \
  "http://$host/ingress-01-regression?preserve=1")
https_status=$(curl -sS -o /dev/null --max-time 10 -w '%{http_code}' \
  "https://$host/ingress-01-regression?preserve=1" || true)

{
  printf 'CAPTURED_AT=%s\n' "$(date -Iseconds)"
  printf 'TRAEFIK_NAME=%s\n' "$(jq -r '.items[0].metadata.name' <<< "$traefik")"
  printf 'TRAEFIK_UID=%s\n' "$(jq -r '.items[0].metadata.uid' <<< "$traefik")"
  printf 'TRAEFIK_RESTART_COUNT=%s\n' "$(jq -r '.items[0].status.containerStatuses[0].restartCount' <<< "$traefik")"
  printf 'TRAEFIK_IMAGE=%s\n' "$(jq -r '.items[0].spec.containers[0].image' <<< "$traefik")"
  printf 'TRAEFIK_IMAGE_ID=%s\n' "$(jq -r '.items[0].status.containerStatuses[0].imageID' <<< "$traefik")"
  printf 'TRAEFIK_DEPLOYMENT_UID=%s\n' "$(jq -r '.metadata.uid' <<< "$traefik_deployment")"
  printf 'TRAEFIK_DEPLOYMENT_GENERATION=%s\n' "$(jq -r '.metadata.generation' <<< "$traefik_deployment")"
  printf 'CERT_SHA256=%s\n' "$cert_fingerprint"
  printf 'HTTP_RESULT=%s\n' "$http_result"
  printf 'HTTPS_STATUS=%s\n' "$https_status"
} > "$output/metadata.env"

printf 'PASS: 적용 전 ingress object, root/ingress/keycloak Application, Node/Pod, Traefik, TLS/301 기준선을 %s에 저장했습니다.\n' "$output"
