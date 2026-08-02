#!/usr/bin/env bash
# POL-02 완료 증거 중 admission 두 경계만 한 번씩 판정한다.
#   1. 예외의 정확한 범위와 실제 만료
#   2. E2E-01에서 이미 서명한 정상 release의 Enforce 회귀 없음
# shellcheck disable=SC2029
set -Eeuo pipefail

mode=${1:-}
signed_digest=${2:-}
case "${mode}" in
  exception)
    [[ -z ${signed_digest} ]] || { echo "exception mode는 digest를 받지 않는다" >&2; exit 2; }
    ;;
  signed-release)
    [[ ${signed_digest} =~ ^sha256:[0-9a-f]{64}$ ]] || {
      echo "사용법: $0 signed-release <signed-digest>" >&2
      exit 2
    }
    ;;
  *)
    echo "사용법: $0 exception | signed-release <signed-digest>" >&2
    exit 2
    ;;
esac
readonly signed_digest

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly kubectl_command=${KUBECTL:-sudo /usr/local/bin/k3s kubectl}
readonly known_hosts=${K3S_SSH_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}
readonly repository=harbor.imcherry5778.xyz/ci01-evidence/ci01-app
readonly exception_name=pol-02-expiry-proof
readonly proof_name=pol-02-expiring-exception
readonly outside_name=pol-02-expiring-exception-outside
readonly release_name=pol-02-signed-release
readonly ssh_options=(
  -o BatchMode=yes
  -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=${known_hosts}"
  -o PasswordAuthentication=no
)
kube() { ssh "${ssh_options[@]}" "${k3s_host}" "${kubectl_command} $*"; }

umask 077
temp_dir=$(mktemp -d)
readonly temp_dir
cleanup() {
  local status=$?
  kube -n e2e-01 delete pod "${release_name}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kube -n kyverno delete policyexception "${exception_name}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  find "${temp_dir}" -type f -delete 2>/dev/null || true
  rmdir "${temp_dir}" 2>/dev/null || true
  return "${status}"
}
trap cleanup EXIT INT TERM

if [[ ${mode} == exception ]] && \
  kube -n kyverno get policyexception "${exception_name}" >/dev/null 2>&1; then
  echo "이전 POL-02 검증 PolicyException이 남아 있다: ${exception_name}" >&2
  exit 1
fi
if [[ ${mode} == signed-release ]] && \
  kube -n e2e-01 get pod "${release_name}" >/dev/null 2>&1; then
  echo "이전 POL-02 검증 Pod가 남아 있다: ${release_name}" >&2
  exit 1
fi

if [[ ${mode} == exception ]]; then
remote_epoch=$(ssh "${ssh_options[@]}" "${k3s_host}" 'date -u +%s')
[[ ${remote_epoch} =~ ^[0-9]+$ ]] || { echo "k3s 시각을 읽지 못했다" >&2; exit 1; }
expiry_epoch=$((remote_epoch + 30))
expiry=$(date -u -d "@${expiry_epoch}" +%Y-%m-%dT%H:%M:%SZ)

jq -n --arg expiry "${expiry}" --arg name "${exception_name}" '{
  apiVersion: "kyverno.io/v2",
  kind: "PolicyException",
  metadata: {
    name: $name,
    namespace: "kyverno",
    annotations: {
      "pol-02.imcherry5778.xyz/owner": "POL-02 verifier",
      "pol-02.imcherry5778.xyz/reason": "Exact-scope admission expiration proof",
      "pol-02.imcherry5778.xyz/expires-at": $expiry
    }
  },
  spec: {
    background: false,
    exceptions: [{
      policyName: "pol-01-require-pod-run-as-non-root",
      ruleNames: ["require-pod-run-as-non-root"]
    }],
    match: {any: [{resources: {
      kinds: ["Pod"],
      namespaces: ["e2e-01"],
      names: ["pol-02-expiring-exception"]
    }}]},
    conditions: {all: [{
      key: ("{{ time_before(\u0027{{ time_now_utc() }}\u0027,\u0027" + $expiry + "\u0027) }}"),
      operator: "Equals",
      value: true
    }]}
  }
}' >"${temp_dir}/exception.json"
kube create -f - <"${temp_dir}/exception.json" >/dev/null

proof_pod() {
  jq -n --arg name "$1" '{
    apiVersion: "v1",
    kind: "Pod",
    metadata: {name: $name, namespace: "e2e-01"},
    spec: {
      automountServiceAccountToken: false,
      restartPolicy: "Never",
      securityContext: {
        runAsUser: 65532,
        runAsGroup: 65532,
        seccompProfile: {type: "RuntimeDefault"}
      },
      containers: [{
        name: "pause",
        image: "registry.k8s.io/pause:3.10",
        securityContext: {
          runAsNonRoot: true,
          runAsUser: 65532,
          allowPrivilegeEscalation: false,
          readOnlyRootFilesystem: true,
          capabilities: {drop: ["ALL"]}
        },
        resources: {
          requests: {cpu: "1m", memory: "2Mi"},
          limits: {cpu: "10m", memory: "8Mi"}
        }
      }]
    }
  }'
}

# Informer가 생성된 예외의 resourceVersion을 소비할 고정 시간을 준 뒤 admission은 재시도하지 않는다.
sleep 2
proof_pod "${proof_name}" | kube create --dry-run=server -f - >"${temp_dir}/before.out" 2>&1 || {
  echo "정확한 예외 입력이 만료 전에 거부됐다" >&2
  sed -n '1,20p' "${temp_dir}/before.out" >&2
  exit 1
}

if proof_pod "${outside_name}" | kube create --dry-run=server -f - >"${temp_dir}/outside.out" 2>&1; then
  echo "예외 범위 밖 이름이 admission을 통과했다" >&2
  exit 1
fi
grep -Fq 'pol-01-require-pod-run-as-non-root' "${temp_dir}/outside.out"
grep -Fq 'require-pod-run-as-non-root' "${temp_dir}/outside.out"

sleep_seconds=$((expiry_epoch - remote_epoch + 2))
sleep "${sleep_seconds}"
if proof_pod "${proof_name}" | kube create --dry-run=server -f - >"${temp_dir}/after.out" 2>&1; then
  echo "만료된 예외가 같은 위반 입력을 계속 허용했다" >&2
  exit 1
fi
grep -Fq 'pol-01-require-pod-run-as-non-root' "${temp_dir}/after.out"
grep -Fq 'require-pod-run-as-non-root' "${temp_dir}/after.out"
echo "evidence_exception=pass name=${proof_name} exact-before=allowed outside=denied same-after=denied expires-at=${expiry}"

kube -n kyverno delete policyexception "${exception_name}" --wait=true >/dev/null
echo "POL-02 예외 완료 증거 통과"
exit 0
fi

jq -n --arg name "${release_name}" --arg image "${repository}@${signed_digest}" '{
  apiVersion: "v1",
  kind: "Pod",
  metadata: {
    name: $name,
    namespace: "e2e-01",
    labels: {
      "app.kubernetes.io/name": "e2e-01",
      "app.kubernetes.io/component": "pol-02-evidence"
    }
  },
  spec: {
    automountServiceAccountToken: false,
    restartPolicy: "Never",
    imagePullSecrets: [{name: "e2e-01-registry"}],
    securityContext: {
      runAsNonRoot: true,
      runAsUser: 65532,
      runAsGroup: 65532,
      seccompProfile: {type: "RuntimeDefault"}
    },
    containers: [{
      name: "app",
      image: $image,
      imagePullPolicy: "IfNotPresent",
      securityContext: {
        runAsNonRoot: true,
        runAsUser: 65532,
        allowPrivilegeEscalation: false,
        readOnlyRootFilesystem: true,
        capabilities: {drop: ["ALL"]}
      },
      resources: {
        requests: {cpu: "5m", memory: "8Mi"},
        limits: {cpu: "100m", memory: "32Mi"}
      }
    }]
  }
}' >"${temp_dir}/release.json"
kube create -f - <"${temp_dir}/release.json" >/dev/null
kube -n e2e-01 wait --for=condition=Ready "pod/${release_name}" --timeout=300s >/dev/null
kube -n e2e-01 get pod "${release_name}" -o json >"${temp_dir}/release-live.json"
jq -e --arg image "${repository}@${signed_digest}" '
  .status.phase == "Running" and
  .spec.securityContext.runAsNonRoot == true and
  .spec.containers[0].image == $image and
  ([.status.conditions[] | select(.type == "Ready" and .status == "True")] | length) == 1
' "${temp_dir}/release-live.json" >/dev/null
kube -n e2e-01 delete pod "${release_name}" --wait=true >/dev/null
echo "evidence_signed_release=pass image=${repository}@${signed_digest} admission=allowed phase=Running ready=True"
echo "POL-02 signed release 완료 증거 통과"
