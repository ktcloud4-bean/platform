#!/usr/bin/env bash
# =============================================================================
# AWS-SEC-05: ASR 보안 오설정(SSH 0.0.0.0/0) 탐지 → 자동조치 원복 검증 스크립트
# =============================================================================
# 1. 시연 전용 더미 보안그룹(asr_demo_target_sg)에 SSH(22) 0.0.0.0/0 인바운드 오설정 고의 생성.
# 2. ASR 런북(AWS-DisablePublicAccessForSecurityGroup)을 ASR 전용 Role(SO0111-DisablePublicAccessForSecurityGroup-asrdemo)로 실행.
# 3. SSM Automation 완료(Success) 및 SSH 룰 자동 제거/원복 확인.
# 4. trap 안전장치: 스크립트 중단이나 실패 시에도 trap으로 반드시 revoke를 보장하며, revoke 실패 시 명시적 에러 처리.
# 5. 실행 후 SSH 0.0.0.0/0 잔여 규칙 0건 검증.
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly script_dir
repo_root=$(cd -- "${script_dir}/../../../.." && pwd)
readonly repo_root
tofu_dir="${repo_root}/infra/aws/tofu-app-security"
readonly tofu_dir

export AWS_PAGER=""
REGION="${AWS_REGION:-ap-northeast-2}"
NAMESPACE="${ASR_NAMESPACE:-asrdemo}"
ROLE_NAME="SO0111-DisablePublicAccessForSecurityGroup-${NAMESPACE}"

echo "============================================================"
echo " AWS-SEC-05 ASR 보안 오설정 자동 원복 실측 검증"
echo "============================================================"

# 더미 SG ID 획득
SG_ID=$(tofu -chdir="${tofu_dir}" output -raw asr_demo_target_sg_id 2>/dev/null || aws ec2 describe-security-groups --filters "Name=group-name,Values=hr-system-prod-asr-demo-target-sg" --query 'SecurityGroups[0].GroupId' --output text)
if [[ -z "${SG_ID}" || "${SG_ID}" == "None" ]]; then
  echo "ERROR: asr_demo_target_sg_id 를 찾을 수 없습니다." >&2
  exit 1
fi
echo "[*] Demo Target Security Group: ${SG_ID}"

# ASR IAM Role ARN 확인
ROLE_ARN=$(aws iam get-role --role-name "${ROLE_NAME}" --query 'Role.Arn' --output text 2>/dev/null || true)
if [[ -z "${ROLE_ARN}" || "${ROLE_ARN}" == "None" ]]; then
  echo "ERROR: ASR IAM Role (${ROLE_NAME})이 존재하지 않습니다. ASR member-roles 스택이 배포되었는지 확인하십시오." >&2
  exit 1
fi
echo "[*] ASR Automation Role: ${ROLE_ARN}"

# SSH 0.0.0.0/0 규칙 존재 여부 확인 함수
has_ssh_open() {
  aws ec2 describe-security-groups --group-ids "${SG_ID}" --region "${REGION}" \
    --query "SecurityGroups[0].IpPermissions[?ToPort==\`22\` && contains(IpRanges[].CidrIp, '0.0.0.0/0')]" \
    --output text
}

# 안전한 정리를 위한 trap 핸들러 등록
CLEANUP_REQUIRED=0
cleanup() {
  local exit_code=$?
  if [[ "${CLEANUP_REQUIRED}" -eq 1 ]]; then
    echo ""
    echo "[!] Trap handler executing: Ensuring SSH 0.0.0.0/0 rule is revoked from ${SG_ID}..."
    if [[ -n "$(has_ssh_open)" ]]; then
      if aws ec2 revoke-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "${REGION}" >/dev/null 2>&1; then
        echo "  [OK] Successfully cleaned up SSH open rule via trap."
      else
        echo "  [CRITICAL ERROR] Failed to revoke SSH open rule in trap handler!" >&2
        exit 2
      fi
    else
      echo "  [OK] SSH open rule already absent."
    fi
  fi
  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

# Step 1: 보안 오설정 고의 생성 (SSH 0.0.0.0/0)
echo ""
echo "[Step 1] Creating intentional misconfiguration (SSH 0.0.0.0/0 on dummy SG)..."
CLEANUP_REQUIRED=1
aws ec2 authorize-security-group-ingress --group-id "${SG_ID}" --protocol tcp --port 22 --cidr 0.0.0.0/0 --region "${REGION}" >/dev/null 2>&1 || true

if [[ -z "$(has_ssh_open)" ]]; then
  echo "ERROR: Failed to authorize SSH 0.0.0.0/0 on ${SG_ID}" >&2
  exit 1
fi
echo "  [OK] Confirmed SSH 0.0.0.0/0 rule is active on ${SG_ID}"

# Step 2: ASR SSM Automation 런북 실행
echo ""
echo "[Step 2] Executing ASR remediation runbook (AWS-DisablePublicAccessForSecurityGroup)..."
EXEC_ID=$(aws ssm start-automation-execution \
  --document-name "AWS-DisablePublicAccessForSecurityGroup" \
  --parameters "GroupId=${SG_ID},AutomationAssumeRole=${ROLE_ARN}" \
  --region "${REGION}" \
  --query 'AutomationExecutionId' --output text)
echo "  SSM Automation Execution ID: ${EXEC_ID}"

# Step 3: 실행 완료 대기 및 상태 폴링
echo ""
echo "[Step 3] Waiting for SSM Automation execution to complete..."
STATUS="InProgress"
for i in $(seq 1 30); do
  STATUS=$(aws ssm get-automation-execution --automation-execution-id "${EXEC_ID}" --region "${REGION}" --query 'AutomationExecution.AutomationExecutionStatus' --output text)
  echo "  [Poll ${i}/30] Status: ${STATUS}"
  if [[ "${STATUS}" != "InProgress" && "${STATUS}" != "Pending" ]]; then
    break
  fi
  sleep 5
done

if [[ "${STATUS}" != "Success" ]]; then
  echo "ERROR: ASR Automation execution ended with unexpected status: ${STATUS}" >&2
  exit 1
fi
echo "  [OK] ASR Automation finished with status Success."

# Step 4: SSH 룰 제거 및 정상 원복 확인
echo ""
echo "[Step 4] Verifying SSH 0.0.0.0/0 rule is automatically removed..."
sleep 2
REMAINING=$(has_ssh_open)
if [[ -n "${REMAINING}" ]]; then
  echo "ERROR: SSH 0.0.0.0/0 rule still exists on ${SG_ID} after remediation!" >&2
  exit 1
fi
echo "  [PASS] SSH 0.0.0.0/0 rule has been successfully removed by ASR."

# 정리 플래그 해제 (이미 정상 제거됨)
CLEANUP_REQUIRED=0

echo ""
echo "============================================================"
echo " AWS-SEC-05 ASR Remediation Scenario PASSED"
echo "============================================================"
