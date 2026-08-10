#!/usr/bin/env bash
# BOARD-DEMO-01 완료 증거: immutable Argo 상태, signed Pod/admission, Pomerium route만 판정한다.
# shellcheck disable=SC2029,SC2329
set -Eeuo pipefail

mode=${1:-}
case ${mode} in
  argo|admission|route) ;;
  *) echo '사용법: verify-live.sh argo <root-sha> <child-sha> | admission <signed-digest> <unsigned-digest> | route' >&2; exit 2 ;;
esac

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-/home/imcherry/.ssh/known_hosts}
readonly repository=harbor.imcherry5778.xyz/board-demo/board-app
readonly secret_root=${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}
readonly board_demo_secret_dir=${BOARD_DEMO_SECRET_DIR:-${secret_root}/board-demo}
readonly board_demo_username=${BOARD_DEMO_USERNAME:-imcherry5778}
readonly board_demo_password_file=${BOARD_DEMO_PASSWORD_FILE:-${board_demo_secret_dir}/route-password}
readonly board_demo_totp_file=${BOARD_DEMO_TOTP_FILE:-${board_demo_secret_dir}/route-totp}
readonly connect_ip=${BOARD_DEMO_CONNECT_IP:-10.10.20.10}
repo_root=$(git rev-parse --show-toplevel)
readonly repo_root
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)
kube() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }

if [[ ${mode} == argo ]]; then
  readonly root_sha=${2:-}
  readonly child_sha=${3:-}
  for sha in "${root_sha}" "${child_sha}"; do
    [[ ${sha} =~ ^[0-9a-f]{40}$ ]] || { echo 'Argo 검증 SHA 형식 오류' >&2; exit 2; }
  done
  state=$(kube -n argocd get application platform-root board-demo pomerium -o json)
  jq -e --arg root "${root_sha}" --arg child "${child_sha}" '
    .items | map({key: .metadata.name, value: .}) | from_entries as $apps |
    ($apps["platform-root"].spec.source.targetRevision == $root) and
    ($apps["platform-root"].status.sync.status == "Synced") and
    ($apps["platform-root"].status.health.status == "Healthy") and
    ($apps["platform-root"].status.sync.revision == $root) and
    (["board-demo", "pomerium"] | all(. as $name |
      $apps[$name].spec.source.targetRevision == $child and
      $apps[$name].status.sync.status == "Synced" and
      $apps[$name].status.health.status == "Healthy" and
      $apps[$name].status.sync.revision == $child))
  ' <<<"${state}" >/dev/null
  echo 'BOARD-DEMO-01 immutable Argo root/board-demo/pomerium 상태 통과'
  exit 0
fi

if [[ ${mode} == admission ]]; then
  readonly signed_digest=${2:-}
  readonly unsigned_digest=${3:-}
  for digest in "${signed_digest}" "${unsigned_digest}"; do
    [[ ${digest} =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'image digest 형식 오류' >&2; exit 2; }
  done
  [[ ${signed_digest} != "${unsigned_digest}" ]] || { echo 'signed/unsigned digest가 같다' >&2; exit 1; }

  kube -n board-demo rollout status deployment/board-demo --timeout=300s >/dev/null
  deployment=$(kube -n board-demo get deployment board-demo -o json)
  jq -e --arg image "${repository}@${signed_digest}" '
    .status.availableReplicas == 1 and
    .spec.template.spec.serviceAccountName == "board-demo" and
    .spec.template.spec.automountServiceAccountToken == false and
    .spec.template.spec.imagePullSecrets == [{name: "board-demo-registry"}] and
    ([.spec.template.spec.containers[] | select(.name == "board-demo") | .image] == [$image])
  ' <<<"${deployment}" >/dev/null
  pod=$(kube -n board-demo get pod -l app.kubernetes.io/name=board-demo,app.kubernetes.io/component=application -o json)
  jq -e --arg image "${repository}@${signed_digest}" '
    .items | length == 1 and
    .[0].status.phase == "Running" and
    ([.[0].status.conditions[] | select(.type == "Ready" and .status == "True")] | length) == 1 and
    (.[0].spec.containers | map(select(.name == "board-demo") | .image) == [$image])
  ' <<<"${pod}" >/dev/null

  if kube -n board-demo get pod board-demo-unsigned >/dev/null 2>&1; then
    echo 'negative test Pod가 admission 전에 이미 존재한다' >&2
    exit 1
  fi
  negative_manifest=$(jq -n --arg image "${repository}@${unsigned_digest}" '{
    apiVersion: "v1", kind: "Pod",
    metadata: {name: "board-demo-unsigned", namespace: "board-demo", labels: {
      "app.kubernetes.io/name": "board-demo", "app.kubernetes.io/component": "negative-evidence"
    }},
    spec: {automountServiceAccountToken: false, restartPolicy: "Never", imagePullSecrets: [{name: "board-demo-registry"}],
      securityContext: {runAsNonRoot: true, runAsUser: 1000, runAsGroup: 1000, seccompProfile: {type: "RuntimeDefault"}},
      containers: [{name: "board-demo", image: $image, imagePullPolicy: "IfNotPresent",
        securityContext: {runAsNonRoot: true, runAsUser: 1000, allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {drop: ["ALL"]}},
        resources: {requests: {cpu: "50m", memory: "128Mi"}, limits: {cpu: "500m", memory: "512Mi"}}
      }]
    }
  }')
  umask 077
  temp_dir=$(mktemp -d)
  cleanup() { rc=$?; find "${temp_dir}" -type f -delete 2>/dev/null || true; rmdir "${temp_dir}" 2>/dev/null || true; return "${rc}"; }
  trap cleanup EXIT INT TERM
  if printf '%s\n' "${negative_manifest}" | ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} create -f -" >"${temp_dir}/admission.out" 2>&1; then
    echo '미서명 artifact Pod가 admission을 통과했다' >&2
    exit 1
  fi
  grep -Fq 'board-demo-verify-release-image' "${temp_dir}/admission.out" || { echo '거부 응답이 Board image policy를 가리키지 않는다' >&2; exit 1; }
  grep -Eiq 'cosign|signature|signed|attestor|verify image|image verification' "${temp_dir}/admission.out" || { echo '거부 응답이 signature 검증 실패를 가리키지 않는다' >&2; exit 1; }
  if kube -n board-demo get pod board-demo-unsigned >/dev/null 2>&1; then
    echo '거부된 Pod가 생성됐다' >&2
    exit 1
  fi
  echo "BOARD-DEMO-01 signed Pod Ready와 unsigned admission 거부 통과: image=${repository}@${signed_digest}"
  exit 0
fi

for secret_file in "${board_demo_password_file}" "${board_demo_totp_file}"; do
  [[ -f ${secret_file} && ! -L ${secret_file} && $(stat -c %a "${secret_file}") == 600 ]] || {
    echo "BOARD-DEMO-01 route: mode 0600 Board 인증 입력이 없다: ${secret_file}" >&2
    exit 1
  }
done
python3 "${repo_root}/gitops/tools/board-demo/verify-route.py" \
  --repo-root "${repo_root}" \
  --connect-ip "${connect_ip}" \
  --username "${board_demo_username}" \
  --password-file "${board_demo_password_file}" \
  --totp-file "${board_demo_totp_file}"
