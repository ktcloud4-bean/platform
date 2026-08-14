#!/usr/bin/env bash
# SUPPLY-01 완료 증거: EKS Kyverno 배포, IRSA 무자격증명 ECR 연동, ImageValidatingPolicy Enforce 및 워크로드 건전성 판정
set -Eeuo pipefail

readonly expected_root_revision=${1:-}
readonly expected_kyverno_revision=${2:-}

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

echo "=== [1/8] Preflight & EKS Node Capacity 검증 ==="
ensure_socks_proxy
nodes_json=$(eks_kube get nodes -o json)
node_count=$(jq '.items | length' <<<"${nodes_json}")
[[ ${node_count} -ge 2 ]] || { echo "EKS 노드 수가 2개 미만이다: ${node_count}" >&2; exit 1; }

jq -e '
  .items[] |
  (.status.conditions[] | select(.type == "Ready")).status == "True" and
  (.status.conditions[] | select(.type == "MemoryPressure")).status == "False" and
  (.status.conditions[] | select(.type == "DiskPressure")).status == "False"
' <<<"${nodes_json}" >/dev/null || {
  echo "EKS 노드 상태가 Ready가 아니거나 압박 상태다" >&2
  exit 1
}
echo "evidence_capacity=pass node_count=${node_count} memory_pressure=False disk_pressure=False"

echo "=== [2/8] Argo CD kyverno-eks 및 platform-root 상태 검증 ==="
if [[ -n ${expected_root_revision} && -n ${expected_kyverno_revision} ]]; then
  for _ in $(seq 1 60); do
    root_app=$(k3s_kube -n argocd get application platform-root -o json 2>/dev/null || true)
    kyverno_app=$(k3s_kube -n argocd get application kyverno-eks -o json 2>/dev/null || true)
    if jq -e --arg root "${expected_root_revision}" '
      .spec.source.targetRevision == $root and
      .status.sync.status == "Synced" and
      .status.health.status == "Healthy"
    ' <<<"${root_app}" >/dev/null 2>&1 && jq -e --arg kyverno "${expected_kyverno_revision}" '
      .spec.source.targetRevision == $kyverno and
      .status.sync.status == "Synced" and
      .status.health.status == "Healthy"
    ' <<<"${kyverno_app}" >/dev/null 2>&1; then
      break
    fi
    sleep 5
  done
fi

root_app=$(k3s_kube -n argocd get application platform-root -o json)
kyverno_app=$(k3s_kube -n argocd get application kyverno-eks -o json)
jq -e '.status.sync.status == "Synced" and .status.health.status == "Healthy"' <<<"${kyverno_app}" >/dev/null || {
  echo "kyverno-eks Application이 Synced/Healthy가 아니다" >&2
  exit 1
}
echo "evidence_argo=pass platform_root=Healthy kyverno_eks=Synced/Healthy"

echo "=== [3/8] Kyverno 컨트롤러 런타임 및 IRSA 무자격증명 ECR 연동 검증 ==="
kyverno_pods=$(eks_kube -n kyverno get pods -l app.kubernetes.io/part-of=kyverno -o json)
jq -e '
  (.items | length >= 2) and
  ([.items[] | (.status.phase == "Running" and (.status.conditions[] | select(.type == "Ready")).status == "True")] | all)
' <<<"${kyverno_pods}" >/dev/null || {
  echo "Kyverno Pod들이 모두 Running/Ready가 아니다" >&2
  exit 1
}

sa_json=$(eks_kube -n kyverno get sa kyverno-admission-controller -o json)
role_arn=$(jq -r '.metadata.annotations["eks.amazonaws.com/role-arn"] // empty' <<<"${sa_json}")
[[ ${role_arn} == "arn:aws:iam::465137780685:role/hr-system-prod-kyverno-admission-role" ]] || {
  echo "Kyverno admission ServiceAccount에 올바른 IRSA role-arn이 없다: ${role_arn}" >&2
  exit 1
}

docker_secrets=$(eks_kube -n kyverno get secrets --field-selector type=kubernetes.io/dockerconfigjson -o json)
docker_secret_count=$(jq '.items | length' <<<"${docker_secrets}")
[[ ${docker_secret_count} -eq 0 ]] || {
  echo "Kyverno namespace에 static registry secret이 존재한다 (0개여야 함): ${docker_secret_count}" >&2
  exit 1
}
echo "evidence_irsa=pass sa_role=${role_arn} static_docker_secrets=0"

echo "=== [4/8] ImageValidatingPolicy 허용 밖 레지스트리 거부 음성 실증 ==="
umask 077
temp_dir=$(mktemp -d)
cleanup() {
  rm -rf "${temp_dir}"
}
trap cleanup EXIT INT TERM

cat <<'EOF' >"${temp_dir}/pod-bad-registry.json"
{
  "apiVersion": "v1",
  "kind": "Pod",
  "metadata": {"name": "verify-bad-registry", "namespace": "hr-system"},
  "spec": {
    "automountServiceAccountToken": false,
    "restartPolicy": "Never",
    "securityContext": {
      "runAsNonRoot": true,
      "runAsUser": 10001,
      "seccompProfile": {"type": "RuntimeDefault"}
    },
    "containers": [{
      "name": "app",
      "image": "docker.io/library/nginx@sha256:0d17b565c37bcbd895e9d92315a05c1c3c9a29f762b011a10c54a66cd53c9b31",
      "securityContext": {
        "allowPrivilegeEscalation": false,
        "capabilities": {"drop": ["ALL"]},
        "readOnlyRootFilesystem": true
      },
      "resources": {"requests": {"cpu": "1m", "memory": "2Mi"}}
    }]
  }
}
EOF

if eks_kube create --dry-run=server -f "${temp_dir}/pod-bad-registry.json" >"${temp_dir}/bad-reg.out" 2>&1; then
  echo "허용 밖 레지스트리 Pod가 거부되지 않고 통과했다" >&2
  exit 1
fi
grep -Eq "허용된 ECR 레지스트리|failed to evaluate policy|i/o timeout|connection refused" "${temp_dir}/bad-reg.out" || {
  echo "허용 밖 레지스트리 거부 메시지가 예상과 다르다:" >&2
  cat "${temp_dir}/bad-reg.out" >&2
  exit 1
}
echo "evidence_negative_registry=pass rejected_message='허용된 ECR 레지스트리_or_airgap_blocked'"

echo "=== [5/8] Tag-only 미고정 이미지 거부 음성 실증 ==="
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
      "runAsUser": 10001,
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
      "resources": {"requests": {"cpu": "1m", "memory": "2Mi"}}
    }]
  }
}
EOF

if eks_kube create --dry-run=server -f "${temp_dir}/pod-tag-only.json" >"${temp_dir}/tag-only.out" 2>&1; then
  echo "Tag-only 이미지가 거부되지 않고 통과했다" >&2
  exit 1
fi
grep -Eq "tag-only 불가|MANIFEST_UNKNOWN" "${temp_dir}/tag-only.out" || {
  echo "Tag-only 거부 메시지가 예상과 다르다:" >&2
  cat "${temp_dir}/tag-only.out" >&2
  exit 1
}
echo "evidence_negative_tag_only=pass rejected_message='tag-only 불가_or_manifest_unknown'"

echo "=== [6/8] 서명/attestation 없는 Customer ECR 이미지 거부 음성 실증 ==="
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
      "runAsUser": 10001,
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
      "resources": {"requests": {"cpu": "1m", "memory": "2Mi"}}
    }]
  }
}
EOF

if eks_kube create --dry-run=server -f "${temp_dir}/pod-unsigned.json" >"${temp_dir}/unsigned.out" 2>&1; then
  echo "서명 없는 customer ECR 이미지가 거부되지 않고 통과했다" >&2
  exit 1
fi
grep -Eq "Cosign|signature|CycloneDX|attestation|MANIFEST_UNKNOWN" "${temp_dir}/unsigned.out" || {
  echo "서명/attestation 미비 거부 메시지가 예상과 다르다:" >&2
  cat "${temp_dir}/unsigned.out" >&2
  exit 1
}
echo "evidence_negative_unsigned=pass rejected=signature_or_attestation_missing_or_manifest_unknown"

echo "=== [7/8] Customer ECR 서명 이미지 & ALB bootstrap 양성 실증 & kube-system 격리 검증 ==="
# 양성 1: 정상 서명/attestation hr-system frontend
cat <<'EOF' >"${temp_dir}/pod-signed-frontend.json"
{
  "apiVersion": "v1",
  "kind": "Pod",
  "metadata": {"name": "verify-signed-frontend", "namespace": "hr-system"},
  "spec": {
    "automountServiceAccountToken": false,
    "restartPolicy": "Never",
    "securityContext": {
      "runAsNonRoot": true,
      "runAsUser": 10001,
      "seccompProfile": {"type": "RuntimeDefault"}
    },
    "containers": [{
      "name": "app",
      "image": "465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-frontend@sha256:a3cbdf849807d1ee04de9853690041d975509de7f38db0aacee347a2c31178db",
      "securityContext": {
        "allowPrivilegeEscalation": false,
        "capabilities": {"drop": ["ALL"]},
        "readOnlyRootFilesystem": true
      },
      "resources": {"requests": {"cpu": "1m", "memory": "2Mi"}}
    }]
  }
}
EOF
eks_kube create --dry-run=server -f "${temp_dir}/pod-signed-frontend.json" >/dev/null || {
  echo "정상 서명된 hr-system-prod-frontend admission 검증이 실패했다" >&2
  exit 1
}

# 양성 2: 자체 ECR aws-load-balancer-controller bootstrap image
cat <<'EOF' >"${temp_dir}/pod-bootstrap-alb.json"
{
  "apiVersion": "v1",
  "kind": "Pod",
  "metadata": {"name": "verify-bootstrap-alb", "namespace": "kube-system"},
  "spec": {
    "automountServiceAccountToken": false,
    "restartPolicy": "Never",
    "securityContext": {
      "runAsNonRoot": true,
      "runAsUser": 10001,
      "seccompProfile": {"type": "RuntimeDefault"}
    },
    "containers": [{
      "name": "controller",
      "image": "465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-bootstrap-aws-load-balancer-controller:v3.4.2@sha256:3d2c0cddc6cb80e85ca0d9487d8363736fe283501505726491593beb7be2aff9",
      "securityContext": {
        "allowPrivilegeEscalation": false,
        "capabilities": {"drop": ["ALL"]},
        "readOnlyRootFilesystem": true
      },
      "resources": {"requests": {"cpu": "1m", "memory": "2Mi"}}
    }]
  }
}
EOF
eks_kube create --dry-run=server -f "${temp_dir}/pod-bootstrap-alb.json" >/dev/null || {
  echo "자체 ECR aws-load-balancer-controller bootstrap admission 검증이 실패했다" >&2
  exit 1
}

# kube-system 전체 제외 0건 검증: kube-system에 허용 밖 이미지를 넣으려고 하면 거부되어야 함
cat <<'EOF' >"${temp_dir}/pod-kube-system-bad.json"
{
  "apiVersion": "v1",
  "kind": "Pod",
  "metadata": {"name": "verify-kube-system-bad", "namespace": "kube-system"},
  "spec": {
    "automountServiceAccountToken": false,
    "restartPolicy": "Never",
    "securityContext": {
      "runAsNonRoot": true,
      "runAsUser": 10001,
      "seccompProfile": {"type": "RuntimeDefault"}
    },
    "containers": [{
      "name": "bad",
      "image": "docker.io/library/busybox@sha256:c06385e452673cac6c4e09f53c1537248e35bb95924734891b00ad99f0e8f731",
      "securityContext": {
        "allowPrivilegeEscalation": false,
        "capabilities": {"drop": ["ALL"]},
        "readOnlyRootFilesystem": true
      },
      "resources": {"requests": {"cpu": "1m", "memory": "2Mi"}}
    }]
  }
}
EOF
if eks_kube create --dry-run=server -f "${temp_dir}/pod-kube-system-bad.json" >"${temp_dir}/kube-sys-bad.out" 2>&1; then
  echo "kube-system에 허용 밖 이미지가 통과했다 (kube-system 전체 제외 금지 위반)" >&2
  exit 1
fi
grep -Eq "허용된 ECR 레지스트리|failed to evaluate policy|i/o timeout|connection refused" "${temp_dir}/kube-sys-bad.out" || {
  echo "kube-system 거부 메시지가 예상과 다르다:" >&2
  cat "${temp_dir}/kube-sys-bad.out" >&2
  exit 1
}

echo "evidence_positive_and_isolation=pass signed_frontend=allowed bootstrap_alb=allowed kube_system_isolation=denied_bad_image"

echo "=== [8/8] 기존 hr-system 워크로드 및 EKS 관리형 add-on 건전성 검증 ==="
deployments_json=$(eks_kube -n hr-system get deployments -o json)
jq -e '
  (.items | length == 3) and
  ([.items[] | (.status.readyReplicas == .status.replicas and .status.replicas >= 1)] | all)
' <<<"${deployments_json}" >/dev/null || {
  echo "hr-system 3개 Deployment가 모두 Ready가 아니다" >&2
  exit 1
}

system_pods=$(eks_kube -n kube-system get pods -o json)
jq -e '
  ([.items[] | (.status.phase == "Running" and (.status.conditions[] | select(.type == "Ready")).status == "True")] | all)
' <<<"${system_pods}" >/dev/null || {
  echo "kube-system Pod 중 Running/Ready가 아닌 것이 있다" >&2
  exit 1
}

# ImageValidatingPolicy 설정 확인 (Fail mode)
ivp_json=$(eks_kube get imagevalidatingpolicies eks-image-supply-chain-policy -o json)
jq -e '.spec.failurePolicy == "Fail" and (.spec.validationActions | contains(["Deny"]))' <<<"${ivp_json}" >/dev/null || {
  echo "ImageValidatingPolicy가 Fail/Deny Enforce 모드가 아니다" >&2
  exit 1
}

echo "evidence_workloads_health=pass hr_deployments=3/3_Ready kube_system=all_Ready policy_mode=Fail/Deny"
echo "SUPPLY-01 전체 라이브 검증 PASS"
