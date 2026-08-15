# AWS-SEC-05: ASR 자동 원복 배포 및 격리 검증 보고서

## 1. 개요

- **작업 ID**: `AWS-SEC-05`
- **목표**: Automated Security Response on AWS (ASR) 자동 원복 프레임워크(admin, member-roles, member CloudFormation 스택 3개)를 배포하고, 격리된 더미 보안그룹에 대한 SSH(0.0.0.0/0) 오설정 자동 원복 실측 및 안전장치(trap/종료 보호)를 검증한다.
- **수행 일시**: 2026-08-15
- **담당자**: Antigravity Platform Security Engineer

---

## 2. ASR 아키텍처 및 구현 세부사항

1. **CloudFormation 스택 3개 배포**:
   - `hr-system-prod-asr` (Admin Orchestrator): Security Hub Custom Action `ASRRemediation`, EventBridge 및 Step Functions 오케스트레이터 배포 (`ShouldDeployWebUI="no"`).
   - `hr-system-prod-asr-member-roles` (Member Roles): SSM Automation 런북 실행용 IAM Role 배포 (`Namespace="asrdemo"`).
   - `hr-system-prod-asr-member` (Member Playbooks): Security Control 표준 런북 배포 (`LoadSCMemberStack="yes"`).
   - 의존성 체인: `asr` -> `asr_member_roles` -> `asr_member` 순차 배포로 IAM Role 참조 오류 방지.

2. **계정 Lambda 동시성 제약 해결 (Curated Admin Template)**:
   - 신규/Sandbox 계정의 Lambda 최소 Unreserved 동시성(10) 제약 하에서, 원본 템플릿의 `ReservedConcurrentExecutions` 하드코딩(1, 5)을 제거한 Curated 템플릿을 S3(`ktcloud4-bean-opentofu-state-465137780685/platform/templates/automated-security-response-admin-curated.template`)에 업로드하여 안정적 배포 완료.

3. **스택 종료 보호 (Termination Protection)**:
   - Security Hub `CloudFormation.1` 보안 기준선 통제를 준수하여 3개 스택 모두 `EnableTerminationProtection=True` 적용.

4. **더미 보안그룹 격리 (`hr-system-prod-asr-demo-target-sg`)**:
   - 실제 워크로드 트래픽에 영향을 주지 않도록 어떤 EC2 인스턴스나 ENI에도 부착되지 않는 격리된 타깃 SG 생성.

5. **자동 원복 시나리오 및 안전장치 (`verify-asr-remediation.sh`)**:
   - 더미 SG에 SSH `0.0.0.0/0` 규칙 생성 -> ASR SSM 런북(`AWS-DisablePublicAccessForSecurityGroup`, Role: `SO0111-DisablePublicAccessForSecurityGroup-asrdemo`) 실행 -> 자동조치 `Success` 및 규칙 자동 제거 확인.
   - `trap cleanup EXIT INT TERM` 핸들러로 스크립트 비정상 종료 시에도 반드시 revoke 수행 보장, revoke 실패 시 명시적 에러 반환.

---

## 3. 5대 완료 증거 검증 결과

| 검증 항목 | 검증 도구 / 명령 | 판정 기준 | 실측 결과 | 판정 |
|---|---|---|---|---|
| **1. 3개 스택 상태 및 종료 보호** | `verify-asr.sh` (Step 2) | admin, member-roles, member 스택 `CREATE_COMPLETE` 및 `TerminationProtection=True` | 3개 스택 모두 `CREATE_COMPLETE` / `TerminationProtection=True` 확인 | **PASS** |
| **2. Security Hub Custom Action 등록** | `aws securityhub describe-action-targets` | Custom Action (`ASRRemediation`) 등록 여부 확인 | `ActionTargetArn` 정상 등록 확인 | **PASS** |
| **3. 더미 보안그룹 격리** | `aws ec2 describe-network-interfaces` | 더미 SG가 어떤 인스턴스/ENI에도 미부착 | `attached ENIs = 0` 완전 격리 확인 | **PASS** |
| **4. 오설정 자동 원복 및 trap 안전장치** | `verify-asr-remediation.sh` | ASR SSM Automation 실행 `Success`, SSH 규칙 자동 원복, trap cleanup 보장 | SSM Automation `Success`, SSH 규칙 자동 삭제, trap 핸들러 동작 확인 | **PASS** |
| **5. SSH 0.0.0.0/0 잔여 규칙 0건** | `aws ec2 describe-security-groups` | 실행 후 SSH 0.0.0.0/0 잔여 규칙 0건 | `residual SSH 0.0.0.0/0 rules = 0` 확인 | **PASS** |

---

## 4. 종합 검증 실행 로그 (`verify-asr.sh`)

```text
============================================================
 AWS-SEC-05 ASR 자동 원복 5대 완료 증거 종합 검증
============================================================
[1/5] OpenTofu fmt & validate ... PASS
[2/5] CloudFormation 3개 스택 상태 및 종료 보호 검증 ...
  - Stack hr-system-prod-asr: Status=CREATE_COMPLETE, TerminationProtection=True (OK)
  - Stack hr-system-prod-asr-member-roles: Status=CREATE_COMPLETE, TerminationProtection=True (OK)
  - Stack hr-system-prod-asr-member: Status=CREATE_COMPLETE, TerminationProtection=True (OK)
PASS: All 3 CloudFormation stacks active with termination protection.
[3/5] Security Hub Custom Action (ASRRemediation) 등록 확인 ... PASS (ActionTarget found)
[4/5] 더미 보안그룹 인스턴스/ENI 미부착 확인 ... PASS (attached ENIs = 0, completely isolated)
[5/5] ASR 보안 오설정 자동 원복 시나리오 실측 검증 ...
============================================================
 AWS-SEC-05 ASR 보안 오설정 자동 원복 실측 검증
============================================================
[*] Demo Target Security Group: sg-062ec80b8787da3dc
[*] ASR Automation Role: arn:aws:iam::465137780685:role/SO0111-DisablePublicAccessForSecurityGroup-asrdemo

[Step 1] Creating intentional misconfiguration (SSH 0.0.0.0/0 on dummy SG)...
  [OK] Confirmed SSH 0.0.0.0/0 rule is active on sg-062ec80b8787da3dc

[Step 2] Executing ASR remediation runbook (AWS-DisablePublicAccessForSecurityGroup)...
  SSM Automation Execution ID: f40c618d-83cf-42c2-9285-8587f051e899

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
PASS: SSH 0.0.0.0/0 residual rules = 0.
============================================================
 AWS-SEC-05 ALL 5 EVIDENCE VERIFICATIONS PASSED
============================================================
```

---

## 5. 산출물 목록

- OpenTofu 인프라 선언:
  - `infra/aws/tofu-app-security/asr.tf`
  - `infra/aws/tofu-app-security/variables.tf`
  - `infra/aws/tofu-app-security/outputs.tf`
  - `infra/aws/tofu-app-security/templates/automated-security-response-admin.template`
- 검증 및 시나리오 스크립트:
  - `infra/aws/tofu-app-security/scripts/verify-asr-remediation.sh`
  - `infra/aws/tofu-app-security/scripts/verify-asr.sh`
