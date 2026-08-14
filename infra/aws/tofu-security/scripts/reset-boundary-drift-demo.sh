#!/usr/bin/env bash
# 권한 드리프트 축소 데모(36-ciem-boundary-drift-check.tf) 리셋.
# Slack "✅ 이 권한들 제거" 버튼을 누르면 ciem-key-exception-callback.py의
# _handle_apply_reduced_policy가 iam:PutRolePolicy로 Role의 인라인 정책을
# 직접 덮어써서, tofu-identity의 Terraform 상태와 실제 AWS 상태가 어긋난다.
# 다음 테이크를 원래 상태로 되돌리려면 그 Role의 권한 정의 리소스만
# -target으로 다시 apply해서 원복한다.
#
# ⚠️ 이 스크립트는 project-f가 아니라 tofu-identity 디렉터리에서 실행해야
# 한다(그 Role들을 tofu-identity가 소유하므로) - TOFU_IDENTITY_DIR로 경로를
# 넘기거나, infra/aws/tofu-identity에서 직접 실행할 것.
#
# 사용법: bash reset-boundary-drift-demo.sh <role-key>
# 예시:   bash reset-boundary-drift-demo.sh observer
#   (role-key: observer / observability-reader / security-reader / identity-reader)
set -euo pipefail

ROLE_KEY="${1:?사용법: $0 <role-key> (observer/observability-reader/security-reader/identity-reader)}"
ROLE_KEY_UNDERSCORE="${ROLE_KEY//-/_}"
TOFU_IDENTITY_DIR="${TOFU_IDENTITY_DIR:-$(pwd)}"

TARGET="aws_iam_role_policy.${ROLE_KEY_UNDERSCORE}_permissions"

echo "▶ ${TARGET} 를 tofu-identity 원본 정의로 되돌립니다"
(cd "$TOFU_IDENTITY_DIR" && terraform apply -target="$TARGET" -auto-approve)

echo ""
echo "▶ 최종 확인 (복원된 정책의 Action 목록)"
ROLE_NAME="platform-saml-${ROLE_KEY}"
POLICY_NAME=$(aws iam list-role-policies --role-name "$ROLE_NAME" --query 'PolicyNames[0]' --output text)
aws iam get-role-policy --role-name "$ROLE_NAME" --policy-name "$POLICY_NAME" \
  --query 'PolicyDocument.Statement[*].Action'

echo ""
echo "Clean Ready State 완료 (${ROLE_KEY})."
echo "⚠️ 방금 복원된 정책도 IAM 전파 지연(최대 몇 분) 대상입니다 - 다음 테이크 전에"
echo "  wait-for-command-stable.sh allowed 등으로 실제로 다시 풀렸는지 확인할 것."
