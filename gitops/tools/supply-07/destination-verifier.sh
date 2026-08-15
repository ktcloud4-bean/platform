#!/usr/bin/env bash
# =============================================================================
# SUPPLY-07: Destination Verifier for HR System Releases in AWS ECR
# Verifies Subject Digest, Cosign Signature, and CycloneDX SBOM Referrers
# =============================================================================
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly script_dir
repo_root=$(cd -- "${script_dir}/../../.." && pwd)
readonly repo_root

export AWS_PAGER=""
export KUBECONFIG="${KUBECONFIG:-/home/imcherry/.kube/k3s-01-admin.yaml}"
REGION="${AWS_REGION:-ap-northeast-2}"
ACCOUNT_ID="465137780685"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
BUNDLE="${repo_root}/gitops/apps/kyverno-eks/policies/cosign-trust-bundle.yaml"

echo "============================================================"
echo " SUPPLY-07 ECR Destination Verifier"
echo "============================================================"

# Extract First Public Key from Kyverno EKS trust bundle
TMP_DIR=$(mktemp -d /tmp/dest_verify_XXXXXX)
cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT INT TERM

PUB_KEY="${TMP_DIR}/cosign.pub"
awk '/-----BEGIN PUBLIC KEY-----/{flag=1} /-----END PUBLIC KEY-----/{print; flag=0; exit} flag' "${BUNDLE}" | sed 's/^[[:space:]]*//' > "${PUB_KEY}"

# Login to ECR and configure DOCKER_CONFIG
ECR_PASS=$(aws ecr get-login-password --region "${REGION}")
export DOCKER_CONFIG="${TMP_DIR}/docker"
mkdir -p "${DOCKER_CONFIG}"
AUTH_B64=$(printf "AWS:%s" "${ECR_PASS}" | base64 -w 0)
cat <<EOF > "${DOCKER_CONFIG}/config.json"
{
  "auths": {
    "${ECR_REGISTRY}": {
      "auth": "${AUTH_B64}"
    }
  }
}
EOF

# Candidate digests for verification
declare -A CANDIDATE_DIGESTS=(
  ["frontend"]="sha256:2fbdb08e4c4bf0f9948f59ebad1ae4dac1be6d9b2da515c9f3470da4a7eecf29"
  ["employee-service"]="sha256:4649409db765af5ae216ee326290abfad948e8fa71f981b42bc7519c28eace6c"
  ["hr-service"]="sha256:7817188def8f185519e7d800975e8c9cbb196d1b8d8cce37a16456b38104d208"
)

COMPONENTS=("frontend" "employee-service" "hr-service")
VERIFIED_COUNT=0

for comp in "${COMPONENTS[@]}"; do
  repo_name="hr-system-prod-${comp}"
  full_repo="${ECR_REGISTRY}/${repo_name}"
  digest="${CANDIDATE_DIGESTS[${comp}]}"
  
  echo -e "\n[*] Verifying Component: ${comp}"
  echo "    ECR Target: ${full_repo}@${digest}"
  
  # 1. Verify ECR repository contains the exact image digest
  aws ecr describe-images --repository-name "${repo_name}" --image-ids imageDigest="${digest}" --region "${REGION}" >/dev/null
  echo "    [PASS] Image digest exists in ECR"
  
  # 2. Verify Cosign signature on exact subject digest
  echo "    Verifying Cosign signature on image..."
  cosign verify --key "${PUB_KEY}" --insecure-ignore-tlog=true "${full_repo}@${digest}" >/dev/null
  echo "    [PASS] Cosign image signature is VALID"
  
  # 3. Discover and verify CycloneDX SBOM referrer
  echo "    Discovering OCI 1.1 referrers via ORAS..."
  ORAS_OUT=$(oras discover --distribution-spec v1.1-referrers-api --format json "${full_repo}@${digest}")
  
  SBOM_DIGEST=$(echo "${ORAS_OUT}" | jq -r '
    .manifests[] | select(.artifactType=="application/vnd.cyclonedx+json") | .digest // empty')
  
  if [[ -z "${SBOM_DIGEST}" ]]; then
    echo "    [FAIL] No CycloneDX SBOM referrer found attached to ${digest}" >&2
    exit 1
  fi
  echo "    [PASS] CycloneDX SBOM referrer found: ${SBOM_DIGEST}"
  
  # 4. Verify Cosign signature on CycloneDX SBOM referrer
  echo "    Verifying Cosign signature on CycloneDX SBOM..."
  cosign verify --key "${PUB_KEY}" --insecure-ignore-tlog=true "${full_repo}@${SBOM_DIGEST}" >/dev/null
  echo "    [PASS] CycloneDX SBOM signature is VALID"
  
  VERIFIED_COUNT=$((VERIFIED_COUNT + 1))
done

echo -e "\n============================================================"
echo " Destination Verifier SUCCESS: All ${VERIFIED_COUNT}/${#COMPONENTS[@]} HR components passed verification!"
echo " Candidate release is verified and ready for GitOps deployment."
echo "============================================================"
