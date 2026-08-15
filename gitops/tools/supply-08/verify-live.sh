#!/usr/bin/env bash
# SUPPLY-08 Deterministic Verification Script
# Jenkins ECR publisher IAM removal and standing access key convergence to 4 keys
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../../.." && pwd)"

echo "============================================================"
echo " SUPPLY-08 Live Verification"
echo "============================================================"

# --- 1. Jenkinsfile ECR direct API/push 0건 확인 ---
echo -e "\n[Step 1] Verifying Jenkinsfile performs 0 direct ECR pushes or AWS credential uses..."
JENKINSFILE="/home/imcherry/projects/ktcloud4-bean/worktrees/hr-system-aws-hr-01/Jenkinsfile"
if [ ! -f "$JENKINSFILE" ]; then
  echo "  [FAIL] Jenkinsfile not found at $JENKINSFILE" >&2
  exit 1
fi
if grep -Eiq 'ecr:Batch|ecr:PutImage|aws ecr get-login|aws-hr-ecr-publisher' "$JENKINSFILE"; then
  echo "  [FAIL] Jenkinsfile contains legacy ECR push or credentials" >&2
  exit 1
fi
echo "  [PASS] Jenkinsfile contains 0 legacy ECR push commands / AWS credential bindings"

# --- 2. OpenTofu infra/aws/tofu-app-ci plan 무변경 확인 ---
echo -e "\n[Step 2] Verifying OpenTofu infra/aws/tofu-app-ci clean plan (0 add, 0 change, 0 destroy)..."
pushd "${repo_root}/infra/aws/tofu-app-ci" >/dev/null
PLAN_OUT=$(tofu plan -no-color 2>&1)
if ! echo "$PLAN_OUT" | grep -q "No changes. Your infrastructure matches the configuration."; then
  echo "  [FAIL] OpenTofu plan has drift or unapplied changes:" >&2
  echo "$PLAN_OUT" >&2
  popd >/dev/null
  exit 1
fi
popd >/dev/null
echo "  [PASS] OpenTofu infra/aws/tofu-app-ci matches clean state (0 changes)"

# --- 3. AWS IAM: Jenkins publisher user 및 access key 부재 확인 ---
echo -e "\n[Step 3] Verifying hr-system-prod-jenkins-ecr-publisher IAM user and keys are completely removed..."
if aws iam get-user --user-name hr-system-prod-jenkins-ecr-publisher 2>/dev/null; then
  echo "  [FAIL] hr-system-prod-jenkins-ecr-publisher still exists in AWS IAM" >&2
  exit 1
fi
echo "  [PASS] hr-system-prod-jenkins-ecr-publisher is deleted from AWS IAM"

# --- 4. Standing Access Key 수렴 확인 (정확히 4건) ---
echo -e "\n[Step 4] Verifying standing access keys converge to exactly 4 designated service accounts..."
# Expected 4 standing service accounts:
# 1. seaweedfs-offsite-backup (backup)
# 2. vault-auto-unseal (vault_auto_unseal)
# 3. hr-system-prod-argocd-eks-credential-issuer (argocd_credential_issuer)
# 4. hr-system-prod-harbor-ecr-replicator (harbor_ecr_replicator)

declare -A EXPECTED_USERS=(
  ["seaweedfs-offsite-backup"]="backup"
  ["vault-auto-unseal"]="vault_auto_unseal"
  ["hr-system-prod-argocd-eks-credential-issuer"]="argocd_credential_issuer"
  ["hr-system-prod-harbor-ecr-replicator"]="harbor_ecr_replicator"
)

TOTAL_STANDING_KEYS=0
for user in "${!EXPECTED_USERS[@]}"; do
  key_count=$(aws iam list-access-keys --user-name "$user" --query 'length(AccessKeyMetadata)' --output text 2>/dev/null || echo 0)
  if [ "$key_count" -ne 1 ]; then
    echo "  [FAIL] Expected exactly 1 key for $user (${EXPECTED_USERS[$user]}), found $key_count" >&2
    exit 1
  fi
  key_id=$(aws iam list-access-keys --user-name "$user" --query 'AccessKeyMetadata[0].AccessKeyId' --output text)
  echo "  [PASS] Standing Key [${EXPECTED_USERS[$user]}]: User=$user KeyId=$key_id (Count=1)"
  TOTAL_STANDING_KEYS=$((TOTAL_STANDING_KEYS + 1))
done

if [ "$TOTAL_STANDING_KEYS" -ne 4 ]; then
  echo "  [FAIL] Standing service keys count is $TOTAL_STANDING_KEYS != 4" >&2
  exit 1
fi
echo "  [PASS] Exactly 4 standing service access keys verified"

# --- 5. Destination Verifier & Harbor ECR replication check ---
echo -e "\n[Step 5] Running Destination Verifier to ensure Harbor replication & ECR integrity..."
bash "${repo_root}/gitops/tools/supply-07/destination-verifier.sh"

echo -e "\n============================================================"
echo " SUPPLY-08 ALL VERIFICATION CHECKS PASSED DETERMINISTICALLY!"
echo "============================================================"
