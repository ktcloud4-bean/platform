#!/usr/bin/env bash
# HR RDS(Aurora) PII 데이터 이중 마스킹 + IAM DB Auth 접속 검증
#
# ⚠️ 전제조건: tofu-app-db의 Aurora 클러스터에 iam_database_authentication_enabled
# =true가 켜져 있어야 하고, hr-data-masking-views.sql이 이미 적용돼 있어야 함.
# 둘 다 project-f 밖(tofu-app-db, 수동 psql 적용)에서 먼저 처리해야 이 스크립트가
# 의미 있는 결과를 낸다 - 43-demo-scenario-resources.tf 주석 참고.
#
# RDS는 사설 서브넷 전용이라 이 스크립트를 돌리는 머신에서 직접 못 붙는다 -
# EKS 워커 노드는 같은 VPC라 접속 가능하므로, kubectl run으로 뜨는 임시
# 디버그 파드에서 psql을 실행한다(노드 Role에 좁게 부여한 rds-db:connect
# 권한을 파드가 상속). 파드는 매 실행 끝에 삭제한다(멱등).
set -uo pipefail
cd "$(dirname "$0")"
source ./_lib.sh

scene_banner 05 "HR RDS PII 데이터 이중 마스킹 + IAM DB Auth 접속 검증" \
  "임시 디버그 파드 기동 → IAM 인증 토큰만으로 RDS 접속(고정 비밀번호 없음)" \
  "general_user_readonly로 마스킹 뷰 조회 → salary 컬럼이 NULL로 가려지는지 확인" \
  "security_auditor_readonly 접속 및 IAM DB Auth 활성화 상태까지 최종 확인"

CLUSTER=$(tf_output eks_cluster_name)
KUBECONFIG_FILE=$(mktemp)
aws eks update-kubeconfig --name "$CLUSTER" --region "$AWS_REGION" --kubeconfig "$KUBECONFIG_FILE" >/dev/null
K() { kubectl --kubeconfig "$KUBECONFIG_FILE" "$@"; }

RDS_HOST=$(tf_output rds_endpoint | cut -d: -f1)
DB_NAME="hr_system" # tofu-app-db var.db_name 기본값. 실제 값이 다르면 여기도 바꿀 것.
POD=scenario5-pii-check
PASS=1

cleanup() { K delete pod "$POD" -n default --ignore-not-found --wait=true --timeout=30s >/dev/null 2>&1; rm -f "$KUBECONFIG_FILE"; }
trap cleanup EXIT

K delete pod "$POD" -n default --ignore-not-found --wait=true --timeout=30s >/dev/null 2>&1
step 1 "디버그 파드 기동 후 IAM 인증 토큰으로 RDS 접속"
progress "디버그 파드 기동 (postgres 클라이언트 이미지)"
K run "$POD" -n default --image=postgres:15-alpine --restart=Never --command -- sleep 300 >/dev/null
K wait --for=condition=Ready "pod/$POD" -n default --timeout=90s >/dev/null 2>&1 || { fail "디버그 파드가 Ready 상태가 안 됨"; result_box FAILED "디버그 파드 기동 실패"; scene_report 5 "RDS PII 이중 마스킹 + IAM DB Auth" FAILED "kubectl exec ... psql"; exit 1; }

psql_as() {
  local dbuser="$1" sql="$2" token
  token=$(aws rds generate-db-auth-token --hostname "$RDS_HOST" --port 5432 --username "$dbuser" --region "$AWS_REGION")
  K exec "$POD" -n default -- env PGPASSWORD="$token" PGSSLMODE=require \
    psql "host=$RDS_HOST port=5432 dbname=$DB_NAME user=$dbuser" -t -c "$sql" 2>&1
}

step 2 "마스킹 뷰 조회 - salary 컬럼 NULL 마스킹 확인"
progress "general_user_readonly로 IAM 인증 접속 후 마스킹 뷰 조회 (salary는 NULL로 가려져야 함)"
OUT1=$(psql_as general_user_readonly "SELECT email, salary FROM masked.employees_general LIMIT 3;")
echo "$OUT1"
SALARY_VALUES=$(echo "$OUT1" | awk -F'|' '{gsub(/ /,"",$2); print $2}')
if [ -z "$OUT1" ] || echo "$OUT1" | grep -qi "error\|denied\|timeout"; then
  fail "접속 또는 조회 실패"
  PASS=0
elif echo "$SALARY_VALUES" | grep -qE '[0-9]'; then
  threat "salary가 마스킹되지 않은 원본 숫자로 보임: $OUT1"
  PASS=0
else
  ok "salary가 NULL로 마스킹됨"
fi

step 3 "security_auditor_readonly 접속 및 IAM DB Auth 활성화 최종 확인"
progress "security_auditor_readonly로 감사용 뷰 조회 (접속 자체가 되는지만 확인)"
OUT2=$(psql_as security_auditor_readonly "SELECT count(*) FROM masked.employees_audit;")
echo "$OUT2"
if echo "$OUT2" | grep -qi "error\|denied\|timeout" || [ -z "$OUT2" ]; then
  fail "security_auditor_readonly 접속 실패"
  PASS=0
else
  ok "security_auditor_readonly IAM 인증 접속 성공"
fi

progress "IAM DB 인증 활성화 여부 (Aurora 클러스터 IAMDatabaseAuthenticationEnabled)"
IAM_AUTH=$(aws rds describe-db-clusters --db-cluster-identifier "$(tf_output name_prefix 2>/dev/null || echo hr-system-prod)-aurora" --query 'DBClusters[0].IAMDatabaseAuthenticationEnabled' --output text)
if [ "$IAM_AUTH" = "True" ]; then
  ok "IAMDatabaseAuthenticationEnabled=True"
else
  fail "IAMDatabaseAuthenticationEnabled=$IAM_AUTH (tofu-app-db에서 켜야 함 - 43-demo-scenario-resources.tf 주석 참고)"
  PASS=0
fi

if [ "$PASS" = "1" ]; then
  result_box PASSED "PII 마스킹 정상 동작 + IAM DB Auth 활성화 확인"
  scene_report 5 "RDS PII 이중 마스킹 + IAM DB Auth" PASSED "kubectl exec <pod> -- psql (IAM 토큰)"
else
  result_box FAILED "마스킹 또는 IAM DB Auth 이상 발견"
  scene_report 5 "RDS PII 이중 마스킹 + IAM DB Auth" FAILED "kubectl exec <pod> -- psql (IAM 토큰)"
  exit 1
fi
