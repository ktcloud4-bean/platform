#!/usr/bin/env bash
# 격리 namespace에서 ConfigMap API 저장/조회와 실제 volume mount 뒤 snapshot bytes를 검증한다.
set -euo pipefail

: "${K3S_SSH_TARGET:?K3S_SSH_TARGET을 지정해야 합니다}"
: "${K3S_SSH_KNOWN_HOSTS:?K3S_SSH_KNOWN_HOSTS를 지정해야 합니다}"

if (($# != 0)); then
  printf '%s\n' '사용법: verify-kubernetes-roundtrip.sh' >&2
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
readonly VERIFY_NAMESPACE=crowdsec-fix-01-verify
readonly VERIFY_POD=crowdsec-fix-01-snapshot-verify

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
k3s_kubectl='sudo -n /usr/local/bin/k3s kubectl'
scratch=$(mktemp -d /tmp/crowdsec-fix-01-k8s-roundtrip.XXXXXX)
created=false
cleanup() {
  if $created; then
    "${ssh_base[@]}" "$k3s_kubectl delete namespace $VERIFY_NAMESPACE --wait=true --timeout=90s" \
      >/dev/null 2>&1 || true
  fi
  rm -rf -- "$scratch"
}
trap cleanup EXIT

if "${ssh_base[@]}" "$k3s_kubectl get namespace $VERIFY_NAMESPACE" >/dev/null 2>&1; then
  printf '중단: 격리 namespace %s가 이미 존재합니다.\n' "$VERIFY_NAMESPACE" >&2
  exit 2
fi

helm template crowdsec "$APP_DIR" -n "$VERIFY_NAMESPACE" \
  -f "$APP_DIR/values-crowdsec-01.yaml" \
  --show-only templates/crowdsec-01-snapshots.yaml > "$scratch/snapshots.yaml"

"${ssh_base[@]}" "$k3s_kubectl create namespace $VERIFY_NAMESPACE" >/dev/null
created=true
"${ssh_base[@]}" "$k3s_kubectl apply -n $VERIFY_NAMESPACE -f -" \
  < "$scratch/snapshots.yaml" >/dev/null
"${ssh_base[@]}" "$k3s_kubectl apply -f -" \
  < "$SCRIPT_DIR/kubernetes-roundtrip-pod.yaml" >/dev/null
"${ssh_base[@]}" \
  "$k3s_kubectl wait -n $VERIFY_NAMESPACE --for=condition=Ready pod/$VERIFY_POD --timeout=120s" \
  >/dev/null

api_binary_hash() {
  local configmap=$1
  local key=$2
  "${ssh_base[@]}" "$k3s_kubectl get configmap -n $VERIFY_NAMESPACE $configmap -o json" |
    jq -r --arg key "$key" '.binaryData[$key]' |
    base64 --decode |
    sha256sum |
    awk '{print $1}'
}

archive_expected=$(metadata_value CRS_SNAPSHOT_ARCHIVE_SHA256)
archive_actual=$(api_binary_hash crowdsec-01-crs-snapshot crs-snapshot.tar.gz)
[[ $archive_actual == "$archive_expected" ]]

config_actual=$(api_binary_hash crowdsec-01-appsec-configs crowdsec-01-crs-inband.yaml)
[[ $config_actual == "$(metadata_value CROWDSEC_01_APPSEC_CONFIG_SHA256)" ]]
rule_actual=$(api_binary_hash crowdsec-01-appsec-rules crowdsec-01-crs.yaml)
[[ $rule_actual == "$(metadata_value CROWDSEC_01_CRS_RULE_SHA256)" ]]
exception_actual=$(api_binary_hash crowdsec-01-appsec-rules crowdsec-01-exact-913100-exception.yaml)
[[ $exception_actual == "$(metadata_value CROWDSEC_01_EXCEPTION_SHA256)" ]]

pod_result=$("${ssh_base[@]}" "$k3s_kubectl logs -n $VERIFY_NAMESPACE $VERIFY_POD")
[[ $pod_result == "PASS: archive=$archive_expected files=49" ]]
"${ssh_base[@]}" \
  "$k3s_kubectl exec -n $VERIFY_NAMESPACE $VERIFY_POD -- sh -c 'cd /crs-data && sha256sum -c SHA256SUMS >/dev/null && test \"\$(find . -maxdepth 1 -type f ! -name SHA256SUMS ! -name READY | wc -l)\" -eq 49'" \
  >/dev/null

cleanup
created=false
if "${ssh_base[@]}" "$k3s_kubectl get namespace $VERIFY_NAMESPACE" >/dev/null 2>&1; then
  printf '%s\n' '오류: 격리 namespace 정리가 완료되지 않았습니다.' >&2
  exit 1
fi
trap - EXIT

printf 'PASS: Kubernetes API 후 archive %s와 AppSec YAML bytes, mount/extract한 CRS 49개 hash가 일치하고 격리 namespace를 제거했습니다.\n' \
  "$archive_expected"
