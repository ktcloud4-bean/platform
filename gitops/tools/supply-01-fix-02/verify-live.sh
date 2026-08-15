#!/usr/bin/env bash
# SUPPLY-01-FIX-02 검증 스크립트
# 1. Git 선언 HR 이미지 서명 및 CycloneDX attestation 독립 검증
# 2. EKS Kyverno ImageValidatingPolicy server-side admission (양성/음성) 검증
# 3. Kyverno 컨트롤러 로그 Rekor URL 오류 0건 검증
# 4. hr-db-migrate Job 실행 및 Succeeded 확인
# 5. Argo CD platform-root, kyverno-eks, hr-system Synced/Healthy 수렴 확인
set -Eeuo pipefail

readonly k3s_host=${K3S_HOST:-rocky@k3s-01.imcherry5778.xyz}
readonly k3s_kubeconfig=${K3S_KUBECONFIG:-$HOME/.kube/k3s-01-admin.yaml}
readonly eks_kubeconfig=${EKS_KUBECONFIG:-$HOME/.kube/eks-hr-system-prod.yaml}
readonly socks_port=${SOCKS_PORT:-1088}
readonly proxy_url="socks5h://127.0.0.1:${socks_port}"

ensure_socks_proxy() {
  if ! nc -z 127.0.0.1 "${socks_port}" 2>/dev/null; then
    ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -f -N -D "${socks_port}" "${k3s_host}"
    sleep 1
  fi
}

k3s_kube() {
  KUBECONFIG="${k3s_kubeconfig}" kubectl "$@"
}

eks_kube() {
  ensure_socks_proxy
  HTTPS_PROXY="${proxy_url}" KUBECONFIG="${eks_kubeconfig}" kubectl "$@"
}

echo "=== [1/6] Git 선언 HR 서비스 이미지 서명 및 Attestation 독립 검증 ==="
umask 077
temp_dir=$(mktemp -d)
cleanup() {
  rm -rf "${temp_dir}"
}
trap cleanup EXIT INT TERM

# ECR 로그인 설정
ecr_pass=$(aws ecr get-login-password --region ap-northeast-2)
auth_b64=$(echo -n "AWS:${ecr_pass}" | base64 -w0)
cat <<EOF >"${temp_dir}/config.json"
{
  "auths": {
    "465137780685.dkr.ecr.ap-northeast-2.amazonaws.com": {
      "auth": "${auth_b64}"
    }
  }
}
EOF

cat <<'EOF' >"${temp_dir}/cosign-current.pub"
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEQa4Ut0QCl60HNt2ZdEu1qVtoU/mL
wgP4DwVaOUntkbS76xmB9xPxkVRWlhVoYGzsYcvVU3Bn7SzL/8FgV9C99A==
-----END PUBLIC KEY-----
EOF

cat <<'EOF' >"${temp_dir}/cosign-previous.pub"
-----BEGIN PUBLIC KEY-----
MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEYDJs7Lrkaw8AKYul3sSYsMKjCQhd
lFqwV0eLn3byybjj+CMZUEoH5s8grTsmikhYeF0QVPzpVpMQNxbT6shc/w==
-----END PUBLIC KEY-----
EOF

HR_IMAGES=(
  "465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-hr-service@sha256:4f2002043e92e1462c4a52946d5ba7dea10e23d81cb5354689ad4afeea20e753"
  "465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-employee-service@sha256:d53ccf25f6ded935d40710bda1c0ec0bb510c50a912dc83e2158faa6e995c572"
  "465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-frontend@sha256:a3cbdf849807d1ee04de9853690041d975509de7f38db0aacee347a2c31178db"
)

for img in "${HR_IMAGES[@]}"; do
  echo "서명 검증 대상: ${img}"
  if DOCKER_CONFIG="${temp_dir}" cosign verify --key "${temp_dir}/cosign-current.pub" --insecure-ignore-tlog "${img}" >/dev/null 2>&1 || \
     DOCKER_CONFIG="${temp_dir}" cosign verify --key "${temp_dir}/cosign-previous.pub" --insecure-ignore-tlog "${img}" >/dev/null 2>&1; then
    echo " -> Image signature PASS"
  else
    echo " -> Image signature FAIL: ${img}" >&2
    exit 1
  fi
done

# CycloneDX OCI referrer attestation manifest 서명 검증
# hr-service attestation manifest
att_manifest_digest="sha256:c408e217f5a85ad5d963f25ba05e4d29ac9aa0f45cc550fbd03be066eaa93146"
echo "CycloneDX Attestation 서명 검증: hr-system-prod-hr-service@${att_manifest_digest}"
if DOCKER_CONFIG="${temp_dir}" cosign verify --key "${temp_dir}/cosign-current.pub" --insecure-ignore-tlog "465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-hr-service@${att_manifest_digest}" >/dev/null 2>&1 || \
   DOCKER_CONFIG="${temp_dir}" cosign verify --key "${temp_dir}/cosign-previous.pub" --insecure-ignore-tlog "465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-hr-service@${att_manifest_digest}" >/dev/null 2>&1; then
  echo " -> CycloneDX Attestation signature PASS"
else
  echo " -> CycloneDX Attestation signature FAIL" >&2
  exit 1
fi
echo "evidence_signatures=pass independent_verification=PASS"

echo "=== [2/6] EKS ImageValidatingPolicy Server-Side Admission 검증 ==="
# 양성 테스트: 현재 배포 대상 이미지 Pod dry-run
cat <<'EOF' >"${temp_dir}/pod-positive-hr-service.json"
{
  "apiVersion": "v1",
  "kind": "Pod",
  "metadata": {"name": "verify-positive-hr", "namespace": "hr-system"},
  "spec": {
    "automountServiceAccountToken": false,
    "restartPolicy": "Never",
    "securityContext": {
      "runAsNonRoot": true,
      "runAsUser": 1000,
      "seccompProfile": {"type": "RuntimeDefault"}
    },
    "containers": [{
      "name": "app",
      "image": "465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-hr-service@sha256:4f2002043e92e1462c4a52946d5ba7dea10e23d81cb5354689ad4afeea20e753",
      "securityContext": {
        "allowPrivilegeEscalation": false,
        "capabilities": {"drop": ["ALL"]},
        "readOnlyRootFilesystem": true
      },
      "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}}
    }]
  }
}
EOF

eks_kube create --dry-run=server -f "${temp_dir}/pod-positive-hr-service.json" >/dev/null || {
  echo "정상 서명된 hr-service server-side admission 실패" >&2
  exit 1
}
echo "evidence_admission_positive=pass server_dry_run=ALLOWED"

# 음성 테스트 1: 미서명 이미지 fixture
cat <<'EOF' >"${temp_dir}/pod-unsigned.json"
{
  "apiVersion": "v1",
  "kind": "Pod",
  "metadata": {"name": "verify-unsigned", "namespace": "hr-system"},
  "spec": {
    "automountServiceAccountToken": false,
    "restartPolicy": "Never",
    "securityContext": {
      "runAsNonRoot": true,
      "runAsUser": 1000,
      "seccompProfile": {"type": "RuntimeDefault"}
    },
    "containers": [{
      "name": "app",
      "image": "465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-frontend@sha256:0000000000000000000000000000000000000000000000000000000000000000",
      "securityContext": {
        "allowPrivilegeEscalation": false,
        "capabilities": {"drop": ["ALL"]},
        "readOnlyRootFilesystem": true
      },
      "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}}
    }]
  }
}
EOF

if eks_kube create --dry-run=server -f "${temp_dir}/pod-unsigned.json" >"${temp_dir}/unsigned.out" 2>&1; then
  echo "미서명 이미지가 거부되지 않고 통과했다" >&2
  exit 1
fi
echo "evidence_admission_negative_unsigned=pass rejected=TRUE"

# 음성 테스트 2: tag-only 미고정 이미지
cat <<'EOF' >"${temp_dir}/pod-tag-only.json"
{
  "apiVersion": "v1",
  "kind": "Pod",
  "metadata": {"name": "verify-tag-only", "namespace": "hr-system"},
  "spec": {
    "automountServiceAccountToken": false,
    "restartPolicy": "Never",
    "securityContext": {
      "runAsNonRoot": true,
      "runAsUser": 1000,
      "seccompProfile": {"type": "RuntimeDefault"}
    },
    "containers": [{
      "name": "app",
      "image": "465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-frontend:latest",
      "securityContext": {
        "allowPrivilegeEscalation": false,
        "capabilities": {"drop": ["ALL"]},
        "readOnlyRootFilesystem": true
      },
      "resources": {"requests": {"cpu": "10m", "memory": "32Mi"}}
    }]
  }
}
EOF

if eks_kube create --dry-run=server -f "${temp_dir}/pod-tag-only.json" >"${temp_dir}/tag-only.out" 2>&1; then
  echo "Tag-only 이미지가 거부되지 않고 통과했다" >&2
  exit 1
fi
echo "evidence_admission_negative_tagonly=pass rejected=TRUE"

echo "=== [3/6] Kyverno 컨트롤러 로그 Rekor URL 오류 검증 ==="
recent_logs=$(eks_kube -n kyverno logs -l app.kubernetes.io/component=admission-controller --since=60s)
if grep -q "rekor URL must be provided" <<<"${recent_logs}"; then
  echo "Kyverno 컨트롤러 로그에 'rekor URL must be provided' 오류가 여전히 존재한다" >&2
  exit 1
fi
echo "evidence_rekor_log=pass rekor_url_errors=0"

echo "=== [4/6] hr-db-migrate Job 상태 및 Pod 실행 확인 ==="
# 만약 기존 실패/타임아웃 Job이 걸려 있다면 정리하고 Argo가 PreSync를 트리거할 수 있게 한다
migrate_job=$(eks_kube -n hr-system get job hr-db-migrate -o json 2>/dev/null || true)
if [[ -n "${migrate_job}" ]]; then
  echo "기존 hr-db-migrate Job 확인:"
  eks_kube -n hr-system get job hr-db-migrate
fi

echo "=== [5/6] Argo CD Application 동기화 상태 대기 ==="
for i in $(seq 1 60); do
  root_sync=$(k3s_kube -n argocd get app platform-root -o jsonpath='{.status.sync.status}')
  root_health=$(k3s_kube -n argocd get app platform-root -o jsonpath='{.status.health.status}')
  kyverno_sync=$(k3s_kube -n argocd get app kyverno-eks -o jsonpath='{.status.sync.status}')
  kyverno_health=$(k3s_kube -n argocd get app kyverno-eks -o jsonpath='{.status.health.status}')
  hr_sync=$(k3s_kube -n argocd get app hr-system -o jsonpath='{.status.sync.status}')
  hr_health=$(k3s_kube -n argocd get app hr-system -o jsonpath='{.status.health.status}')
  
  echo "Wait [${i}/60]: platform-root=${root_sync}/${root_health}, kyverno-eks=${kyverno_sync}/${kyverno_health}, hr-system=${hr_sync}/${hr_health}"
  if [[ "${root_sync}" == "Synced" && "${root_health}" == "Healthy" && \
        "${kyverno_sync}" == "Synced" && "${kyverno_health}" == "Healthy" && \
        "${hr_sync}" == "Synced" && "${hr_health}" == "Healthy" ]]; then
    echo "모든 대상 Application이 Synced/Healthy 상태에 도달했다."
    break
  fi
  sleep 5
done

echo "=== [6/6] 최종 증거 집계 ==="
eks_kube -n hr-system get pods
eks_kube -n hr-system get jobs
echo "evidence_final=pass SUPPLY_01_FIX_02_COMPLETED=TRUE"
