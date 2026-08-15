# AWS-DB-SEC-01: HR Aurora IAM DB 인증 활성화 및 역할별 PII 마스킹 뷰 적용 보고서

## 1. 개요

- **작업 ID**: `AWS-DB-SEC-01`
- **목표**: HR Aurora PostgreSQL 클러스터의 IAM Database Authentication을 활성화하고, 역할별 PII 데이터(급여·변경이력) 이중 마스킹 뷰를 적용하여 최소 권한 및 데이터 거버넌스를 실현한다.
- **수행 일시**: 2026-08-15
- **담당자**: Antigravity Platform Security Engineer

---

## 2. 주요 변경 사항 및 기술적 세부사항

1. **Aurora IAM DB 인증 활성화 (`infra/aws/tofu-app-db/rds.tf`)**:
   - `aws_rds_cluster.main`에 `iam_database_authentication_enabled = true` 및 `apply_immediately = true` 적용.
   - Aurora PostgreSQL에서 IAM DB 인증 변경은 클러스터/인스턴스 재부팅 없이 무중단(In-place Dynamic)으로 즉시 적용됨을 사전 검증 및 실측 확인.

2. **클러스터 리소스 ID 출력 (`infra/aws/tofu-app-db/outputs.tf`)**:
   - `aurora_cluster_resource_id = aws_rds_cluster.main.cluster_resource_id` (`cluster-R3RXAS56R7IZH3JKOP27JX4NEE`) 추가.
   - IAM 정책에서 `rds-db:connect` 대상 ARN을 와일드카드(`*`) 대신 `arn:aws:rds-db:${region}:${account_id}:dbuser:${cluster_resource_id}/${db_user}`로 정밀 스코핑 가능.

3. **역할별 PII 마스킹 뷰 및 역할 선언 (`infra/aws/tofu-app-db/sql/hr-data-masking-views.sql`)**:
   - IAM DB 역할 생성: `general_user_readonly`, `security_auditor_readonly`, `db_admin`, `remediation_admin` + `GRANT rds_iam` + `GRANT CONNECT ON DATABASE hr_system`.
   - `masked` 스키마 및 마스킹 뷰:
     - `masked.employees_general`: `salary` 컬럼을 `NULL::integer`로 마스킹.
     - `masked.employees_audit`: `salary` 컬럼 원본 유지.
     - `masked.change_history_general`: `field_name = 'salary'`인 경우 `old_value`와 `new_value`를 `'****'`로 마스킹.
     - `masked.change_history_audit`: 원본 값 유지.
   - 원본 테이블 권한 제한: `REVOKE ALL ON employees, change_history FROM PUBLIC, general_user_readonly, security_auditor_readonly`.
   - 뷰 조회 권한: 일반 사용자에게 `masked.*_general`, 감사자에게 `masked.*_audit`만 `SELECT` 허용.

4. **Rollback 절차**:
   - IAM DB 인증 비활성화: `rds.tf`에서 `iam_database_authentication_enabled = false`로 변경 후 `tofu apply`.
   - 마스킹 뷰 및 권한 원복: `DROP SCHEMA masked CASCADE; REVOKE rds_iam FROM general_user_readonly, security_auditor_readonly;` 실행.

---

## 3. 5대 완료 증거 실측 검증 결과

| 검증 항목 | 검증 도구 / 명령 | 판정 기준 | 실측 결과 | 판정 |
|---|---|---|---|---|
| **1. 라이브 클러스터 변경 및 무중단** | `aws rds describe-db-clusters` | IAM DB Auth 활성화, 재부팅 없이 Dynamic 적용 | `IAMDatabaseAuthenticationEnabled: true`, `Status: available` | **PASS** |
| **2. 기존 애플리케이션 연결 무중단** | `verify-db-sec.sh` (Step 4) | `employee_service` 계정 정상 연결 및 쿼리 성공 | 기존 직원 6명 정상 조회 (`existing_apps_unbroken: true`) | **PASS** |
| **3. Cluster Resource ID 출력** | `tofu output aurora_cluster_resource_id` | `cluster-R3RXAS56R7IZH3JKOP27JX4NEE` 정상 출력 | `rds-db:connect` 정밀 스코핑 계약 충족 | **PASS** |
| **4. general_user_readonly 마스킹 대조** | IAM DB Token 접속 쿼리 | 원본 테이블 거부, `salary=NULL`, 변경이력 `'****'` | 원본 거부(`denied=true`), `salary=null`, `old/new='****'` | **PASS** |
| **5. security_auditor_readonly 감사 대조** | IAM DB Token 접속 쿼리 | 원본 테이블 거부, `salary` 원본 노출 | 원본 거부(`denied=true`), `salary: 45000000` 정상 노출 | **PASS** |

---

## 4. 실측 실행 로그 (`verify-db-sec.sh`)

```text
============================================================
 AWS-DB-SEC-01 Aurora IAM DB 인증 및 PII 마스킹 검증
============================================================
[1/5] OpenTofu fmt & validate ... PASS
[2/5] Aurora 클러스터 및 IAM Database Authentication 상태 확인 ...
  - DB Host: hr-system-prod-aurora.cluster-c5igos8o67r8.ap-northeast-2.rds.amazonaws.com
  - Cluster Resource ID: cluster-R3RXAS56R7IZH3JKOP27JX4NEE
  - Master Secret ARN: arn:aws:secretsmanager:ap-northeast-2:465137780685:secret:rds!cluster-ace998da-7b1a-4311-8c22-50a3621d58d4-17ago9
  [PASS] IAMDatabaseAuthenticationEnabled=True (무중단 Dynamic 적용 확인)
[3/5] VPC 내부 실측용 검증 Lambda 패키징 및 배포 ...
  Waiting for Lambda function to become Active...
[4/5] SQL 마스킹 뷰 적용 및 IAM DB 토큰 접속 실측 실행 ...
  Lambda execution output:
{
  "iam_auth_enabled": true,
  "master_applied_sql": true,
  "existing_apps_unbroken": true,
  "general_user_direct_table_denied": true,
  "general_user_salary_null_masked": true,
  "general_user_history_masked": true,
  "auditor_user_direct_table_denied": true,
  "auditor_user_salary_visible": true,
  "salary_sample_general": [
    {
      "email": "admin@imcherry5778.xyz",
      "department": "HR",
      "salary": null
    },
    {
      "email": "imcherry5778@gmail.com",
      "department": "HR",
      "salary": null
    },
    {
      "email": "swfco.naver.com@gmail.com",
      "department": "개발팀",
      "salary": null
    }
  ],
  "salary_sample_audit": [
    {
      "email": "admin@imcherry5778.xyz",
      "salary": 0
    },
    {
      "email": "imcherry5778@gmail.com",
      "salary": 0
    },
    {
      "email": "swfco.naver.com@gmail.com",
      "salary": 45000000
    }
  ],
  "employee_count": 6
}
[5/5] 4대 검증 항목 상세 판정 ...
  - 마스킹 뷰 및 IAM 역할 SQL 적용: OK
  - 기존 앱(employee_service) 접속 무중단: OK (직원 수: 6명 정상 조회)
  - general_user_readonly: 원본 테이블 거부=OK, salary NULL 마스킹=OK, 변경이력 '****' 마스킹=OK
  - security_auditor_readonly: 원본 테이블 거부=OK, salary 원본 조회=OK
============================================================
 AWS-DB-SEC-01 ALL EVIDENCE VERIFICATIONS PASSED
============================================================
```
