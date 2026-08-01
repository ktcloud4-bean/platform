#!/usr/bin/env bash
# route/HCC 없이 격리 namespace에서 offline AppSec startup과 egress policy를 검증한다.
set -euo pipefail

: "${K3S_SSH_TARGET:?K3S_SSH_TARGET을 지정해야 합니다}"
: "${K3S_SSH_KNOWN_HOSTS:?K3S_SSH_KNOWN_HOSTS를 지정해야 합니다}"

if (($# != 0)); then
  printf '%s\n' '사용법: verify-kubernetes-offline-startup.sh' >&2
  exit 2
fi
if [[ ! -f $K3S_SSH_KNOWN_HOSTS ]]; then
  printf '%s\n' '오류: trusted known_hosts 파일이 없습니다.' >&2
  exit 2
fi

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly SCRIPT_DIR
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../../.." && pwd)
readonly REPO_ROOT
readonly APP_DIR="$REPO_ROOT/gitops/apps/crowdsec"
readonly VERIFY_NAMESPACE=crowdsec-fix-01-offline-verify

metadata_value() {
  local key=$1
  local -a values
  mapfile -t values < <(sed -n "s/^${key}=//p" "$APP_DIR/release-metadata.env")
  if ((${#values[@]} != 1)) || [[ -z ${values[0]} ]]; then
    printf '오류: release-metadata.env의 %s가 정확히 하나가 아닙니다.\n' "$key" >&2
    return 2
  fi
  printf '%s' "${values[0]}"
}

ssh_base=(
  ssh
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$K3S_SSH_KNOWN_HOSTS"
  -o PasswordAuthentication=no
  -o ConnectTimeout=10
  "$K3S_SSH_TARGET"
)
readonly k3s_kubectl='sudo -n /usr/local/bin/k3s kubectl'
scratch=$(mktemp -d /tmp/crowdsec-fix-01-k8s-offline.XXXXXX)
created=false

cleanup() {
  if $created; then
    for _ in {1..10}; do
      "${ssh_base[@]}" "$k3s_kubectl delete namespace $VERIFY_NAMESPACE --wait=false" \
        >/dev/null 2>&1 || true
      if ! "${ssh_base[@]}" "$k3s_kubectl get namespace $VERIFY_NAMESPACE" \
        >/dev/null 2>&1; then
        break
      fi
      sleep 3
    done
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT

if "${ssh_base[@]}" "$k3s_kubectl get namespace $VERIFY_NAMESPACE" >/dev/null 2>&1; then
  printf '중단: 격리 namespace %s가 이미 존재합니다.\n' "$VERIFY_NAMESPACE" >&2
  exit 2
fi

traefik_before=$("${ssh_base[@]}" \
  "$k3s_kubectl get helmchartconfig -n kube-system traefik -o json; $k3s_kubectl get pod -n kube-system -l app.kubernetes.io/name=traefik -o json" |
  jq -sc '[.[0].metadata.generation, .[0].metadata.resourceVersion, .[1].items[0].metadata.uid, .[1].items[0].status.containerStatuses[0].imageID, .[1].items[0].status.containerStatuses[0].restartCount]')

helm template crowdsec-01 "$APP_DIR" -n "$VERIFY_NAMESPACE" \
  -f "$APP_DIR/values-crowdsec-01.yaml" \
  --set lapi.persistentVolume.data.enabled=false \
  --show-only templates/docker-start-configmap.yaml \
  --show-only templates/lapi-configmap.yaml \
  --show-only templates/lapi-service.yaml \
  --show-only templates/lapi-deployment.yaml \
  --show-only templates/appsec-configmap.yaml \
  --show-only templates/appsec-service.yaml \
  --show-only templates/appsec-deployment.yaml \
  --show-only templates/crowdsec-01-snapshots.yaml \
  --show-only templates/crowdsec-01-networkpolicy.yaml \
  > "$scratch/rendered.yaml"

if rg -n '^kind: (Secret|PersistentVolume|PersistentVolumeClaim|Ingress|IngressRoute|Middleware|HelmChartConfig)$' \
  "$scratch/rendered.yaml"; then
  printf '%s\n' '오류: 격리 startup render에 금지된 live 경로 자원이 있습니다.' >&2
  exit 1
fi

"${ssh_base[@]}" "$k3s_kubectl create namespace $VERIFY_NAMESPACE" >/dev/null
created=true
umask 077
openssl rand -hex 32 > "$scratch/cs-lapi-secret"
openssl rand -hex 32 > "$scratch/registration-token"
openssl rand -hex 32 > "$scratch/bouncer-key"
jq -n \
  --arg namespace "$VERIFY_NAMESPACE" \
  --rawfile cs_lapi_secret "$scratch/cs-lapi-secret" \
  --rawfile registration_token "$scratch/registration-token" \
  --rawfile bouncer_key "$scratch/bouncer-key" \
  '{
    apiVersion: "v1",
    kind: "Secret",
    metadata: {name: "crowdsec-01-bootstrap", namespace: $namespace},
    type: "Opaque",
    data: {
      CS_LAPI_SECRET: ($cs_lapi_secret | rtrimstr("\n") | @base64),
      REGISTRATION_TOKEN: ($registration_token | rtrimstr("\n") | @base64),
      BOUNCER_KEY_CROWDSEC_01: ($bouncer_key | rtrimstr("\n") | @base64)
    }
  }' | "${ssh_base[@]}" "$k3s_kubectl apply -f -" >/dev/null

secret_keys=$("${ssh_base[@]}" \
  "$k3s_kubectl get secret -n $VERIFY_NAMESPACE crowdsec-01-bootstrap -o json" |
  jq -r '.data | keys | sort | join(",")')
[[ $secret_keys == 'BOUNCER_KEY_CROWDSEC_01,CS_LAPI_SECRET,REGISTRATION_TOKEN' ]]

"${ssh_base[@]}" "$k3s_kubectl apply --server-side --dry-run=server -n $VERIFY_NAMESPACE -f -" \
  < "$scratch/rendered.yaml" >/dev/null
"${ssh_base[@]}" "$k3s_kubectl apply -n $VERIFY_NAMESPACE -f -" \
  < "$scratch/rendered.yaml" >/dev/null
"${ssh_base[@]}" \
  "$k3s_kubectl rollout status -n $VERIFY_NAMESPACE deployment/crowdsec-01-lapi --timeout=180s" \
  >/dev/null
"${ssh_base[@]}" \
  "$k3s_kubectl rollout status -n $VERIFY_NAMESPACE deployment/crowdsec-01-appsec --timeout=180s" \
  >/dev/null

appsec_pod_json=$("${ssh_base[@]}" \
  "$k3s_kubectl get pod -n $VERIFY_NAMESPACE -l k8s-app=crowdsec-01,type=appsec -o json")
appsec_pod=$(jq -r 'if (.items | length) == 1 then .items[0].metadata.name else empty end' \
  <<< "$appsec_pod_json")
[[ -n $appsec_pod ]]
jq -e '
  .items[0].status.initContainerStatuses as $init
  | ($init | length) == 3
    and all($init[]; .state.terminated.exitCode == 0)
    and .items[0].status.containerStatuses[0].ready
    and (.items[0].status.containerStatuses[0].restartCount == 0)
' <<< "$appsec_pod_json" >/dev/null

builder_log=$("${ssh_base[@]}" \
  "$k3s_kubectl logs -n $VERIFY_NAMESPACE $appsec_pod -c prepare-crowdsec-01-offline-startup")
[[ $builder_log == 'CROWDSEC-01_OFFLINE_STARTUP_PREPARED' || \
  $builder_log == 'CROWDSEC-01_OFFLINE_STARTUP_REUSED' ]]
appsec_log=$("${ssh_base[@]}" \
  "$k3s_kubectl logs -n $VERIFY_NAMESPACE $appsec_pod -c crowdsec-appsec")
lapi_log=$("${ssh_base[@]}" \
  "$k3s_kubectl logs -n $VERIFY_NAMESPACE deployment/crowdsec-01-lapi")
grep -Fqx 'CROWDSEC-01_OFFLINE_STARTUP: Hub preparation disabled' <<< "$appsec_log"
if rg -n 'Running hub update|version\.crowdsec\.net|cscli .* (parsers|collections|scenarios|postoverflows|appsec-configs|appsec-rules) (install|upgrade)' \
  <<< "$appsec_log" || rg -n 'Running hub update|version\.crowdsec\.net' <<< "$lapi_log"; then
  printf '%s\n' '오류: 격리 Kubernetes startup 로그에서 Hub 설치·갱신 호출이 발견됐습니다.' >&2
  exit 1
fi

startup_hashes=$("${ssh_base[@]}" \
  "$k3s_kubectl exec -n $VERIFY_NAMESPACE $appsec_pod -c crowdsec-appsec -- sha256sum /docker_start.sh /offline-startup/docker_start.sh")
[[ $(awk '$2 == "/docker_start.sh" {print $1}' <<< "$startup_hashes") == \
  "$(metadata_value CROWDSEC_DOCKER_START_SHA256)" ]]
[[ $(awk '$2 == "/offline-startup/docker_start.sh" {print $1}' <<< "$startup_hashes") == \
  "$(metadata_value CROWDSEC_OFFLINE_STARTUP_SHA256)" ]]
builder_api_hash=$("${ssh_base[@]}" \
  "$k3s_kubectl get configmap -n $VERIFY_NAMESPACE crowdsec-01-offline-startup-builder -o json" |
  jq -r '.binaryData["prepare-offline-startup.sh"]' | base64 --decode | sha256sum | awk '{print $1}')
[[ $builder_api_hash == \
  "$(metadata_value CROWDSEC_OFFLINE_STARTUP_BUILDER_SHA256)" ]]

"${ssh_base[@]}" \
  "$k3s_kubectl exec -n $VERIFY_NAMESPACE $appsec_pod -c crowdsec-appsec -- sh -c 'nc -z -w 3 crowdsec-01-service 8080'" \
  >/dev/null
if "${ssh_base[@]}" \
  "$k3s_kubectl exec -n $VERIFY_NAMESPACE $appsec_pod -c crowdsec-appsec -- sh -c 'timeout 5 nc -z -w 3 1.1.1.1 443'" \
  >/dev/null 2>&1; then
  printf '%s\n' '오류: 격리 AppSec Pod의 외부 TCP egress가 허용됐습니다.' >&2
  exit 1
fi

network_policy_json=$("${ssh_base[@]}" \
  "$k3s_kubectl get networkpolicy -n $VERIFY_NAMESPACE -o json")
jq -e '
  [.items[] | select(.metadata.name == "crowdsec-01-appsec-to-lapi")][0]
  | .spec.podSelector.matchLabels["k8s-app"] == "crowdsec-01"
    and .spec.podSelector.matchLabels.type == "appsec"
    and .spec.egress[0].to[0].podSelector.matchLabels["k8s-app"] == "crowdsec-01"
    and .spec.egress[0].to[0].podSelector.matchLabels.type == "lapi"
' <<< "$network_policy_json" >/dev/null

decisions=$("${ssh_base[@]}" \
  "$k3s_kubectl exec -n $VERIFY_NAMESPACE deployment/crowdsec-01-lapi -- cscli decisions list -o json")
jq -e 'length == 0' <<< "$decisions" >/dev/null

traefik_after=$("${ssh_base[@]}" \
  "$k3s_kubectl get helmchartconfig -n kube-system traefik -o json; $k3s_kubectl get pod -n kube-system -l app.kubernetes.io/name=traefik -o json" |
  jq -sc '[.[0].metadata.generation, .[0].metadata.resourceVersion, .[1].items[0].metadata.uid, .[1].items[0].status.containerStatuses[0].imageID, .[1].items[0].status.containerStatuses[0].restartCount]')
[[ $traefik_after == "$traefik_before" ]]

cleanup
created=false
if "${ssh_base[@]}" "$k3s_kubectl get namespace $VERIFY_NAMESPACE" >/dev/null 2>&1; then
  printf '%s\n' '오류: 격리 namespace 정리가 완료되지 않았습니다.' >&2
  exit 1
fi
trap - EXIT

printf '%s\n' \
  'PASS: 실제 Kubernetes init/main startup의 원본·builder·offline script hash가 고정값과 일치합니다.' \
  'PASS: AppSec→LAPI는 허용되고 외부 TCP egress는 차단되며 Hub 설치·갱신 요청은 0건입니다.' \
  'PASS: route/HCC/PVC 없이 검증했고 Traefik HCC·Pod 상태는 불변이며 격리 namespace를 제거했습니다.'
