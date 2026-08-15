# AWS-SEC-06: 보안 시나리오 5종 라이브 실측 검증 및 운영 문서화 보고서

## 1. 개요

- **작업 ID**: `AWS-SEC-06`
- **목표**: 온프레미스 플랫폼 및 AWS 통합 환경에서 수립된 5대 보안 통제 시나리오를 라이브 실측으로 검증하고, 격리성·최소권한·안전장치를 실증하여 운영 문서화한다.
- **수행 일시**: 2026-08-15
- **담당자**: Antigravity Platform Security Engineer

---

## 2. 5대 보안 시나리오 실측 검증 결과 요약

| 시나리오 | 대상 및 격리 경계 | 검증 도구 / 명령 | 실측 결과 | 판정 |
|---|---|---|---|---|
| **1. PII 데이터 이중 마스킹** | HR Aurora PostgreSQL (`hr_system`) | `verify-db-sec.sh` (IAM DB Token 쿼리) | 일반 사용자 `salary=null`, 변경이력 `'****'`, 감사자 원본 노출, 원본 테이블 직접 조회 거부 | **PASSED** |
| **2. ASR 오설정 자동 원복** | 더미 보안그룹 (`asr_demo_target_sg`) | `verify-asr-remediation.sh` (SSM Automation) | SSH `0.0.0.0/0` 규칙 고의 생성 → SSM Automation 자동 실행 → SSH 규칙 자동 제거 및 잔여 0건 | **PASSED** |
| **3. 긴급 세션 강제 종료** | 격리 테스트 계정 (`test-session-revoke-demo`) | `verify-all-scenarios.sh` (Action Executor Lambda) | 4개 운영 SAML Role + Demo Role에 Deny 인라인 정책 부착 확인, 팀원 세션 영향 0건, 테스트 후 정책 완전 제거 | **PASSED** |
| **4. 권한 드리프트 및 Slack 엔드포인트** | 데모 Role (`platform-saml-demo-role`) | Access Analyzer Policy Gen & curl 위조 서명 | 미사용 권한 제외 정밀 정책 생성(`SUCCEEDED`), 운영 SAML Role 4개 불변, 위조 서명 `401 Unauthorized` 차단 | **PASSED** |
| **5. Grafana SOC 대시보드** | Managed Grafana & Security Lake Glue DB | `aws grafana`, `aws athena`, `aws glue` CLI | Grafana `ACTIVE`, SAML `CONFIGURED`, Athena Workgroup `ENABLED`, Security Lake Glue DB 생존 확인 | **PASSED** |

---

## 3. 시나리오별 상세 실측 데이터 및 재현 절차

### [Scene 1] RDS Aurora PostgreSQL PII 데이터 이중 마스킹
- **재현 절차**:
  1. `general_user_readonly`로 IAM DB 토큰(`aws rds generate-db-auth-token`) 발급 후 접속.
  2. 원본 테이블 직접 조회: `SELECT * FROM employees;` → `permission denied for table employees` (거부 확인).
  3. 마스킹 뷰 조회: `SELECT email, department, salary FROM masked.employees_general;` → `salary: null` 마스킹 확인.
  4. 변경 이력 뷰 조회: `SELECT field_name, old_value, new_value FROM masked.change_history_general WHERE field_name = 'salary';` → `'****'` 마스킹 확인.
  5. `security_auditor_readonly`로 접속하여 감사 뷰 조회: `salary: 45000000` 원본 노출 확인.
- **실측 샘플**:
  ```json
  {
    "salary_sample_general": [
      { "email": "admin@imcherry5778.xyz", "department": "HR", "salary": null },
      { "email": "swfco.naver.com@gmail.com", "department": "개발팀", "salary": null }
    ],
    "salary_sample_audit": [
      { "email": "swfco.naver.com@gmail.com", "salary": 45000000 }
    ],
    "employee_count": 6
  }
  ```

### [Scene 2] ASR 보안 오설정(SSH 0.0.0.0/0) 자동 원복
- **재현 절차**:
  1. 인스턴스에 미부착된 격리 더미 SG(`sg-062ec80b8787da3dc`)에 SSH 22 포트 `0.0.0.0/0` 인바운드 규칙 추가.
  2. ASR 런북 SSM Automation (`AWS-DisablePublicAccessForSecurityGroup`, Role: `SO0111-DisablePublicAccessForSecurityGroup-asrdemo`) 실행.
  3. 상태 폴링: `InProgress` → `Success` 완료 후 SSH 규칙 자동 제거 및 잔여 0건 확인.
  4. `trap` 핸들러로 비정상 종료 시에도 안전 제거 보장.

### [Scene 3] 긴급 세션 강제 종료 (격리 테스트 계정)
- **재현 절차**:
  1. 격리 테스트 계정 `test-session-revoke-demo`를 대상으로 `hr-system-prod-ciem-action-executor` Lambda 호출.
  2. 5개 SAML Role(`platform-saml-observer`, `platform-saml-observability-reader`, `platform-saml-security-reader`, `platform-saml-identity-reader`, `platform-saml-demo-role`)에 `ciem-revoke-session-test-session-revoke-demo` Deny 인라인 정책 부착 확인.
  3. 정책 조건 `{"aws:userid": "*:test-session-revoke-demo"}`으로 실제 운영 팀원 세션 영향 0건 보장.
  4. 테스트 완료 후 인라인 정책 즉시 삭제하여 잔여 0건 확인.

### [Scene 4] CIEM 권한 드리프트 탐지 및 Slack 엔드포인트 보안
- **재현 절차**:
  1. 데모 Role(`platform-saml-demo-role`) AssumeRole 세션으로 EC2 API(DescribeRegions/DescribeInstances/DescribeVpcs)만 호출.
  2. Access Analyzer Policy Generation Job 시작 → Job `SUCCEEDED` 도달.
  3. 생성된 축소 정책 검증: 초기 선언에 있던 미호출 서비스(S3, RDS, CloudWatch, Logs)가 제외되고 실제 호출된 EC2/STS 권한만 포함됨 확인.
  4. 4개 운영 SAML Role의 인라인 정책 불변성 확인 (`AWSID01ObserverReadOnly`, `AWSID02ObservabilityReadOnly`, `AWSID02SecurityReadOnly`, `AWSID01IdentityReadOnly`).
  5. Slack Interactivity 엔드포인트에 위조 서명 전송 → `HTTP 401 Unauthorized` 정상 차단 확인.

### [Scene 5] Amazon Managed Grafana SOC 통합 대시보드
- **재현 절차**:
  1. Managed Grafana 워크스페이스 상태: `ACTIVE` (`g-a1461e6101`).
  2. Keycloak SAML 연동 상태: `CONFIGURED`.
  3. Athena Workgroup: `hr-system-prod-security` (`ENABLED`).
  4. Security Lake Glue Database: `amazon_security_lake_glue_db_ap_northeast_2` 정상 생존 확인.

---

## 4. 종합 검증 실행 로그 (`verify-all-scenarios.sh`)

```text
============================================================
 AWS-SEC-06 AWS 통합 보안 시나리오 5종 라이브 실측 검증
============================================================

=== [Scene 1/5] RDS Aurora PostgreSQL PII 데이터 이중 마스킹 검증 ===
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
    { "email": "admin@imcherry5778.xyz", "department": "HR", "salary": null },
    { "email": "imcherry5778@gmail.com", "department": "HR", "salary": null },
    { "email": "swfco.naver.com@gmail.com", "department": "개발팀", "salary": null }
  ],
  "salary_sample_audit": [
    { "email": "admin@imcherry5778.xyz", "salary": 0 },
    { "email": "imcherry5778@gmail.com", "salary": 0 },
    { "email": "swfco.naver.com@gmail.com", "salary": 45000000 }
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
Cleaning up temporary verification resources...
[Scene 1/5 PASS] PII 마스킹 및 IAM DB 인증 정상 확인

=== [Scene 2/5] ASR 보안 오설정(SSH 0.0.0.0/0) 자동 원복 검증 ===
============================================================
 AWS-SEC-05 ASR 보안 오설정 자동 원복 실측 검증
============================================================
[*] Demo Target Security Group: sg-062ec80b8787da3dc
[*] ASR Automation Role: arn:aws:iam::465137780685:role/SO0111-DisablePublicAccessForSecurityGroup-asrdemo

[Step 1] Creating intentional misconfiguration (SSH 0.0.0.0/0 on dummy SG)...
  [OK] Confirmed SSH 0.0.0.0/0 rule is active on sg-062ec80b8787da3dc

[Step 2] Executing ASR remediation runbook (AWS-DisablePublicAccessForSecurityGroup)...
  SSM Automation Execution ID: dd339c1b-2397-4887-8b91-49873dfc7dbd

[Step 3] Waiting for SSM Automation execution to complete...
  [Poll 1/30] Status: InProgress
  [Poll 2/30] Status: InProgress
  [Poll 3/30] Status: Success
  [OK] ASR Automation finished with status Success.

[Step 4] Verifying SSH 0.0.0.0/0 rule is automatically removed...
  [PASS] SSH 0.0.0.0/0 rule has been successfully removed by ASR.

============================================================
 AWS-SEC-05 ASR Remediation Scenario PASSED
============================================================
[Scene 2/5 PASS] ASR 자동 원복 및 격리 타깃 정상 확인

=== [Scene 3/5] 긴급 세션 강제 종료 실측 검증 (대상: test-session-revoke-demo) ===
  [Step 3-1] Invoking CIEM action-executor for session revocation...
  [Step 3-2] Verifying Deny inline policies on SAML roles...
    - Role platform-saml-observer: Deny policy active targeting test-session-revoke-demo (OK)
    - Role platform-saml-observability-reader: Deny policy active targeting test-session-revoke-demo (OK)
    - Role platform-saml-security-reader: Deny policy active targeting test-session-revoke-demo (OK)
    - Role platform-saml-identity-reader: Deny policy active targeting test-session-revoke-demo (OK)
    - Role platform-saml-demo-role: Deny policy active targeting test-session-revoke-demo (OK)
  [Step 3-3] Cleaning up test deny policies (ensuring 0 residual)...
    - All temporary deny policies cleanly removed (0 residual).
[Scene 3/5 PASS] 긴급 세션 종료 및 무잔여 정리 정상 확인

=== [Scene 4/5] CIEM 권한 드리프트 탐지 및 Slack 콜백 엔드포인트 검증 ===
  [Step 4-1] Verifying Access Analyzer Policy Generation on demo role...
  Policy Generation Job ID: 8457f9eb-e920-49fe-8506-08e50f8c000c
  [Poll 13/30] Status: SUCCEEDED
  [PASS] Generated policy successfully excluded uncalled services (S3, RDS, Logs).
  [Step 4-2] Verifying operational SAML roles policy invariance...
    - Role platform-saml-observer: InlinePolicy=[AWSID01ObserverReadOnly], AttachedCount=0 (OK)
    - Role platform-saml-observability-reader: InlinePolicy=[AWSID02ObservabilityReadOnly], AttachedCount=0 (OK)
    - Role platform-saml-security-reader: InlinePolicy=[AWSID02SecurityReadOnly], AttachedCount=0 (OK)
    - Role platform-saml-identity-reader: InlinePolicy=[AWSID01IdentityReadOnly], AttachedCount=0 (OK)
  [Step 4-3] Testing Slack callback endpoint signature verification...
    - Invalid signature rejected with HTTP 401 (OK)
[Scene 4/5 PASS] CIEM 권한 드리프트 및 Slack 엔드포인트 보안 검증 완료

=== [Scene 5/5] Amazon Managed Grafana SOC 대시보드 및 데이터소스 검증 ===
  - Grafana Workspace: ID=g-a1461e6101, Status=ACTIVE (OK)
  - Grafana SAML Authentication: Status=CONFIGURED (OK)
  - Athena Workgroup: Name=hr-system-prod-security, State=ENABLED (OK)
  - Security Lake Glue DB: amazon_security_lake_glue_db_ap_northeast_2 (OK)
[Scene 5/5 PASS] Grafana SOC 워크스페이스 및 데이터소스 생존 확인 완료

============================================================
 AWS-SEC-06 ALL 5 SCENARIOS VERIFICATIONS PASSED
============================================================
```
