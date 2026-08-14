#!/usr/bin/env bash
# Security Hub 위험 수용(Risk Accepted) Finding 일괄 Suppress
#
# project-c의 동일 스크립트를 platform-main 사정에 맞게 다시 골랐다 - 그대로
# 안 옮긴 이유:
#   - EC2/EKS 퍼블릭 노출 관련 항목들: platform-main은 Keycloak/Pomerium EC2가
#     아예 없고 EKS도 private-only라 해당 finding 자체가 안 뜰 가능성이 높음
#     (뜨면 그건 이 스크립트가 아니라 실제 설정을 다시 봐야 하는 신호).
#   - ALB 암호화 미적용 두 건: project-c는 "Pomerium과 mTLS로 이미 암호화됨"이
#     근거였는데, platform-main의 실제 ALB(gitops/apps/hr-system/ingress.yaml)는
#     mTLS가 없는 평문 HTTP라 그 근거가 성립하지 않는다 - "VPN 뒤 사설망 +
#     보안그룹으로만 접근 가능"으로 근거를 바꿈.
#   - RDS/ALB 삭제 보호, Multi-AZ 등 "PoC라 반복 destroy/apply"가 근거였던
#     항목: platform-main은 반복 재배포하는 환경이 아니라 그 근거가 성립하지
#     않는다. Multi-AZ는 순수 비용 이유로만 위험 수용 유지, 삭제 보호는 여기서
#     suppress하지 않는다(실제로 켜는 걸 권장 - 합치기-전-체크리스트.md 참고).
set -euo pipefail

suppress() {
  local title="$1"
  local note="$2"

  local ids
  ids=$(aws securityhub get-findings \
    --filters "{\"Title\":[{\"Value\":\"$title\",\"Comparison\":\"EQUALS\"}],\"RecordState\":[{\"Value\":\"ACTIVE\",\"Comparison\":\"EQUALS\"}]}" \
    --query "Findings[].{Id:Id,ProductArn:ProductArn}" --output json)

  local count
  count=$(echo "$ids" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")

  if [ "$count" -eq 0 ]; then
    echo "  [건너뜀] '$title' - 활성 finding 없음"
    return
  fi

  echo "$ids" | python3 -c "
import json, sys
findings = json.load(sys.stdin)
print(json.dumps([{'Id': f['Id'], 'ProductArn': f['ProductArn']} for f in findings]))
" > /tmp/sh_finding_identifiers.json

  aws securityhub batch-update-findings \
    --finding-identifiers "file:///tmp/sh_finding_identifiers.json" \
    --workflow '{"Status":"SUPPRESSED"}' \
    --note "{\"Text\":\"$note\",\"UpdatedBy\":\"terraform-managed-risk-acceptance\"}" \
    >/dev/null
  echo "  [완료] '$title' - ${count}건 Suppress"
  rm -f /tmp/sh_finding_identifiers.json
}

echo "▶ API Gateway 인증 타입 미지정 (Slack webhook 엔드포인트)"
suppress "API Gateway routes should specify an authorization type" \
  "Slack Interactivity webhook 엔드포인트(28-ciem-key-exception-flow.tf). AWS IAM/JWT 인증 대신 Slack 자체 서명(HMAC, X-Slack-Signature)을 Lambda 코드에서 직접 검증함(scripts/ciem-key-exception-callback.py). AWS 인증을 강제하면 Slack이 보내는 요청 자체가 거부되어 CIEM 1-Click 기능이 깨짐 - 대체 통제 존재로 위험 수용."

echo "▶ ALB 대상 그룹 헬스체크/전송 프로토콜 암호화 (VPN+보안그룹으로 접근 자체가 제한됨)"
suppress "Application and Network Load Balancer target groups should use encrypted health check protocols" \
  "이 ALB(hr-system Ingress)는 Site-to-Site VPN을 거쳐야만 도달 가능한 사설망 안에 있고, 접근 자체가 보안그룹으로 좁게 제한되어 있음 - 인터넷에 노출된 적이 없음. 암호화된 전송 계층을 추가하면 인증서 관리 복잡도만 늘어 위험 수용."
suppress "ELB target groups should use encrypted transport protocols" \
  "위와 동일 사유(VPN+보안그룹으로 네트워크 계층에서 이미 접근이 제한됨) - 위험 수용."

echo "▶ RDS Multi-AZ (비용 이유로 단일 AZ 유지)"
suppress "RDS DB instances should be configured with multiple Availability Zones" \
  "Multi-AZ는 RDS 비용을 약 2배로 늘림 - 이 규모에서 고가용성보다 비용 효율을 우선해 위험 수용. 트래픽/가용성 요구사항이 늘어나면 재검토."

echo "▶ S3 MFA Delete (Terraform/일반 IAM으로 설정 불가)"
suppress "S3 general purpose buckets should have MFA delete enabled" \
  "S3 MFA Delete는 루트 계정 자격증명 + MFA 기기로 AWS CLI에서만 설정 가능한 기능이라 Terraform(IAM Role 기반 인증)으로는 구조적으로 켤 수 없음. 루트 계정 직접 조작이 필요해 위험 수용."

echo "▶ Secrets Manager 자동 로테이션 (외부 시스템 동기화 리스크)"
suppress "Secrets Manager secrets should have automatic rotation enabled" \
  "Slack Bot Token/Keycloak admin 시크릿은 로테이션 Lambda 구현 비용 대비 실효성이 낮고, 자동 로테이션이 온프레미스 Keycloak 등 외부 시스템과의 동기화를 깨뜨릴 위험이 있어 위험 수용."

echo "▶ ASR 솔루션 내부 리소스 (AWS Solutions 템플릿 소유, enable_asr_remediation=true일 때만 해당)"
suppress "DynamoDB tables should automatically scale capacity with demand" \
  "AWS Solutions 'Automated Security Response on AWS' CloudFormation 템플릿이 자체 생성하는 내부 리소스(27-asr-remediation.tf가 감싼 스택 소유, 우리 Terraform 리소스 아님). 이 스택은 AWS가 배포/업데이트를 관리하므로 직접 수정하면 다음 솔루션 업데이트 시 되돌아가거나 충돌할 수 있어 위험 수용."
suppress "CloudFormation stacks should have associated service roles" \
  "위와 동일 사유 - ASR 스택은 AWS 솔루션이 관리."

echo
echo "SECURITY_HUB_SUPPRESS_DONE"
