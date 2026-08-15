#!/usr/bin/env bash
# =============================================================================
# AWS-SEC-05: ASR 자동 원복 및 격리 배포 5대 완료 증거 종합 검증 스크립트
# =============================================================================
# 1. CloudFormation 3개 스택(admin, member-roles, member) CREATE_COMPLETE 및 종료 보호 확인
# 2. Security Hub Custom Action (ASRRemediation) 등록 확인
# 3. 더미 보안그룹이 어떤 인스턴스/ENI에도 미부착 확인
# 4. 시나리오 스크립트 실행 및 trap/revoke 검증
# 5. 실행 뒤 SSH 0.0.0.0/0 잔여 규칙 0건 확인
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly script_dir
repo_root=$(cd -- "${script_dir}/../../../.." && pwd)
readonly repo_root
tofu_dir="${repo_root}/infra/aws/tofu-app-security"
readonly tofu_dir

export AWS_PAGER=""
REGION="${AWS_REGION:-ap-northeast-2}"

echo "============================================================"
echo " AWS-SEC-05 ASR 자동 원복 5대 완료 증거 종합 검증"
echo "============================================================"

# Step 1: OpenTofu 정적 검증
echo -n "[1/5] OpenTofu fmt & validate ... "
tofu -chdir="${tofu_dir}" fmt -check >/dev/null
tofu -chdir="${tofu_dir}" validate >/dev/null
echo "PASS"

# Step 2: 3개 CloudFormation 스택 상태 및 종료 보호 검증
echo "[2/5] CloudFormation 3개 스택 상태 및 종료 보호 검증 ..."
STACKS=("hr-system-prod-asr" "hr-system-prod-asr-member-roles" "hr-system-prod-asr-member")

for stack in "${STACKS[@]}"; do
  STATUS=$(aws cloudformation describe-stacks --stack-name "${stack}" --region "${REGION}" --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)
  if [[ "${STATUS}" != "CREATE_COMPLETE" && "${STATUS}" != "UPDATE_COMPLETE" ]]; then
    echo "  [FAIL] Stack ${stack} status is '${STATUS}' (expected CREATE_COMPLETE or UPDATE_COMPLETE)" >&2
    exit 1
  fi
  
  TERM_PROT=$(aws cloudformation describe-stacks --stack-name "${stack}" --region "${REGION}" --query 'Stacks[0].EnableTerminationProtection' --output text 2>/dev/null || true)
  if [[ "${TERM_PROT}" != "True" && "${TERM_PROT}" != "true" ]]; then
    echo "  [FAIL] Stack ${stack} termination protection is '${TERM_PROT}' (expected True)" >&2
    exit 1
  fi
  echo "  - Stack ${stack}: Status=${STATUS}, TerminationProtection=${TERM_PROT} (OK)"
done
echo "PASS: All 3 CloudFormation stacks active with termination protection."

# Step 3: Security Hub Custom Action 등록 확인
echo -n "[3/5] Security Hub Custom Action (ASRRemediation) 등록 확인 ... "
ACTIONS=$(aws securityhub describe-action-targets --region "${REGION}" --query 'ActionTargets[].ActionTargetArn' --output text 2>/dev/null || true)
if echo "${ACTIONS}" | grep -q "ASRRemediation"; then
  echo "PASS (ActionTarget found)"
else
  echo "FAIL (ASRRemediation not found in Security Hub action targets)" >&2
  exit 1
fi

# Step 4: 더미 보안그룹 인스턴스/ENI 미부착 검증
echo -n "[4/5] 더미 보안그룹 인스턴스/ENI 미부착 확인 ... "
SG_ID=$(tofu -chdir="${tofu_dir}" output -raw asr_demo_target_sg_id 2>/dev/null || aws ec2 describe-security-groups --filters "Name=group-name,Values=hr-system-prod-asr-demo-target-sg" --query 'SecurityGroups[0].GroupId' --output text)
if [[ -z "${SG_ID}" || "${SG_ID}" == "None" ]]; then
  echo "FAIL (Cannot find asr_demo_target_sg_id)" >&2
  exit 1
fi

ENI_COUNT=$(aws ec2 describe-network-interfaces --filters "Name=group-id,Values=${SG_ID}" --region "${REGION}" --query 'length(NetworkInterfaces)' --output text)
if [[ "${ENI_COUNT}" -eq 0 ]]; then
  echo "PASS (attached ENIs = 0, completely isolated)"
else
  echo "FAIL (Security group ${SG_ID} is attached to ${ENI_COUNT} ENIs!)" >&2
  exit 1
fi

# Step 5: 시나리오 스크립트 실행 및 trap/SSM 자동 원복 & 잔여 0건 검증
echo "[5/5] ASR 보안 오설정 자동 원복 시나리오 실측 검증 ..."
"${script_dir}/verify-asr-remediation.sh"

# 최종 잔여 규칙 재확인
REMAINING=$(aws ec2 describe-security-groups --group-ids "${SG_ID}" --region "${REGION}" \
  --query "SecurityGroups[0].IpPermissions[?ToPort==\`22\` && contains(IpRanges[].CidrIp, '0.0.0.0/0')]" \
  --output text)
if [[ -n "${REMAINING}" ]]; then
  echo "FAIL: Residual SSH 0.0.0.0/0 rule found after verification!" >&2
  exit 1
fi
echo "PASS: SSH 0.0.0.0/0 residual rules = 0."

echo "============================================================"
echo " AWS-SEC-05 ALL 5 EVIDENCE VERIFICATIONS PASSED"
echo "============================================================"
