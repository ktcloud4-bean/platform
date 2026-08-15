# AWS-SEC-04: 격리 데모 아이덴티티 및 SAML Role 최소권한 축소 검증 보고서

## 1. 개요

- **작업 ID**: `AWS-SEC-04`
- **목표**: CIEM 권한 축소와 비상 세션 회수를 실증하기 위한 격리된 데모 아이덴티티(`test-session-revoke-demo`) 및 데모 SAML Role(`platform-saml-demo-role`)을 안전하게 선언하고, 운영 IAM/SAML에 영향을 주지 않으면서 Access Analyzer 정책 축소를 실측 검증한다.
- **수행 일시**: 2026-08-15
- **담당자**: Antigravity Platform Security Engineer

---

## 2. 격리 아키텍처 및 소유권 원칙

1. **단일 소유권 및 중복 0건**:
   - 운영 SAML Role 4개(`platform-saml-observer`, `platform-saml-observability-reader`, `platform-saml-security-reader`, `platform-saml-identity-reader`)는 `infra/aws/tofu-identity`가 소유한다.
   - 데모 SAML Role(`platform-saml-demo-role`) 및 정책(`AWSSEC04DemoPermissions`)은 `infra/aws/tofu-app-security/demo_identity.tf`가 단독 소유한다.
   - 상호 OpenTofu state 및 리소스 선언 간 중복 `0건`.

2. **Keycloak 계정 격리**:
   - 데모 사용자: `test-session-revoke-demo` (이메일: `test-session-revoke-demo@imcherry5778.xyz`)
   - 전용 데모 그룹: `/aws-console-demo-users`
   - 전용 SAML Client Role: `aws-console-demo-operator` (AWS SAML client `https://signin.aws.amazon.com/saml`)
   - 전용 Protocol Mapper: `aws-demo-role-name` (`https://aws.amazon.com/SAML/Attributes/Role` 매핑)
   - 운영 그룹(`/platform-users`, `/platform-privileged`, `/soar-operators`, `/soar-readers`, `/grafana-amg-editors`)과 완전 분리 (`membership_polluted=0`).

3. **운영 SAML 불변성**:
   - 기존 운영 SAML Role 4개의 Keycloak Client Role 및 Protocol Mapper, 멤버십 변경 `0건` 보존.

4. **네트워크 및 Traefik Ingress 보안**:
   - `gitops/apps/keycloak/middleware-ciem-vpc-admin.yaml`의 allowlist에 온프레미스 플랫폼 관리망(`10.10.0.0/16`) 및 운영 터널(`100.64.0.0/10`), AWS VPC 세션 종료 서브넷(`10.20.10.0/24`, `10.20.20.0/24`)을 함께 허용하여 Ingress 경로 보안 및 관리 제어를 정합화.

---

## 3. 4대 완료 증거 검증 결과

| 검증 항목 | 검증 도구 / 명령 | 판정 기준 | 실측 결과 | 판정 |
|---|---|---|---|---|
| **1. 데모 Role 소유권 및 중복 0건** | `verify-demo-identity.sh` (Step 2) | `tofu-app-security` 단독 소유, `tofu-identity` 선언 중복 0건 | `platform-saml-demo-role` 정상 등록, `tofu-identity` 중복 0건 | **PASS** |
| **2. Keycloak 테스트 사용자 격리** | `provision-keycloak-demo-identity.sh --check` | 실제 팀원 계정과 exact 구분, 운영 group 속하지 않음 | `user=test-session-revoke-demo`, `group=/aws-console-demo-users`, `operational_membership_polluted=0` | **PASS** |
| **3. Access Analyzer 정책 축소 검증** | `verify-demo-identity-access-analyzer.sh` | 데모 Role 실제 API 호출 이력 기반 Access Analyzer 축소 정책 생성 (`SUCCEEDED`, 미호출 서비스 제외) | EC2(DescribeRegions, DescribeInstances, DescribeVpcs)·STS 호출 기반 축소 정책 생성 완료 (S3, RDS, Logs, CW 제외) | **PASS** |
| **4. 운영 SAML Role 4개 불변성** | `provision-keycloak-demo-identity.sh --check` | 4개 운영 SAML Role 정책/멤버십 변경 0건 | `operational_roles_unchanged=4` 불변 확인 | **PASS** |

---

## 4. 실측 세부 데이터

### 4.1 Access Analyzer 생성 정책 실측 (Job ID: `98502367-81f2-4a0c-8206-046b340ff4c9`)

- **초기 부여 권한 (19개 액션)**:
  `cloudwatch:DescribeAlarms`, `cloudwatch:GetMetricData`, `cloudwatch:ListMetrics`, `ec2:DescribeAvailabilityZones`, `ec2:DescribeInstances`, `ec2:DescribeNetworkInterfaces`, `ec2:DescribeRegions`, `ec2:DescribeRouteTables`, `ec2:DescribeSecurityGroups`, `ec2:DescribeSubnets`, `ec2:DescribeTags`, `ec2:DescribeVpcs`, `logs:DescribeLogGroups`, `logs:FilterLogEvents`, `rds:DescribeDBClusters`, `rds:DescribeDBInstances`, `s3:GetObject`, `s3:ListAllMyBuckets`, `s3:ListBucket`
- **데모 세션 실제 호출 API**:
  `ec2:DescribeRegions`, `ec2:DescribeInstances`, `ec2:DescribeVpcs`, `sts:GetCallerIdentity`
- **Access Analyzer 생성 축소 정책**:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SupportedServiceSid0",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeRegions",
        "ec2:DescribeVpcs",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

### 4.2 종합 검증 스크립트 실행 로그

```text
============================================================
 AWS-SEC-04 격리 데모 아이덴티티 종합 검증
============================================================
[1/4] OpenTofu fmt & validate ... PASS
[2/4] 데모 Role 소유권 및 tofu-identity 중복 0건 검증 ... PASS (tofu-app-security single ownership, overlap=0)
[3/4] Keycloak 데모 계정 격리 및 운영 Role 불변성 검증 ... PASS (isolated demo user, operational_roles_unchanged=4, membership_polluted=0)
[4/4] Access Analyzer 정책 생성 검증 ...
[*] AWS-SEC-04 Access Analyzer Policy Generation Verification
[*] Account: 465137780685, Region: ap-northeast-2
[*] Demo Role: arn:aws:iam::465137780685:role/platform-saml-demo-role
[*] CloudTrail: arn:aws:cloudtrail:ap-northeast-2:465137780685:trail/management-events
[*] Access Analyzer Role: arn:aws:iam::465137780685:role/hr-system-prod-ciem-access-analyzer-cloudtrail-role

[Step 1] AssumeRole into demo SAML role...

[Step 2] Executing selected API calls with demo session...
  Assumed Identity: arn:aws:sts::465137780685:assumed-role/platform-saml-demo-role/aws-sec-04-verification-session
  - ec2:DescribeRegions returned 17 regions
  - ec2:DescribeInstances returned 2 reservations
  - ec2:DescribeVpcs returned 2 vpcs

[Step 3] Starting Access Analyzer Policy Generation Job...
  Policy Generation Job ID: 98502367-81f2-4a0c-8206-046b340ff4c9

[Step 4] Waiting for Policy Generation Job to complete...
  [Poll 1/30] Status: IN_PROGRESS
  [Poll 2/30] Status: IN_PROGRESS
  [Poll 3/30] Status: IN_PROGRESS
  [Poll 4/30] Status: IN_PROGRESS
  [Poll 5/30] Status: IN_PROGRESS
  [Poll 6/30] Status: IN_PROGRESS
  [Poll 7/30] Status: SUCCEEDED

[Step 5] Validating generated policy...
  Generated Policy count: 1
  Initial Policy declared actions:
cloudwatch:DescribeAlarms cloudwatch:GetMetricData cloudwatch:ListMetrics ec2:DescribeAvailabilityZones ec2:DescribeInstances ec2:DescribeNetworkInterfaces ec2:DescribeRegions ec2:DescribeRouteTables ec2:DescribeSecurityGroups ec2:DescribeSubnets ec2:DescribeTags ec2:DescribeVpcs logs:DescribeLogGroups logs:FilterLogEvents rds:DescribeDBClusters rds:DescribeDBInstances s3:GetObject s3:ListAllMyBuckets s3:ListBucket 
  Generated Policy statement:
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "SupportedServiceSid0",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeRegions",
        "ec2:DescribeVpcs",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
  [PASS] Generated policy successfully excluded uncalled services (S3, RDS, Logs).

[SUCCESS] Access Analyzer Policy Generation SUCCEEDED for platform-saml-demo-role (Job: 98502367-81f2-4a0c-8206-046b340ff4c9)
============================================================
 AWS-SEC-04 ALL VERIFICATIONS PASSED
============================================================
```

---

## 5. 결론 및 산출물

- `AWS-SEC-04`의 모든 요구사항(단일 소유권, 아이덴티티 격리, 실측 API 기반 Access Analyzer 축소 정책 생성, 운영 SAML 불변성)이 100% 충족되었음을 증명하였다.
- 산출물:
  - OpenTofu 선언: `infra/aws/tofu-app-security/demo_identity.tf`, `ciem.tf`, `remote_state.tf`, `outputs.tf`
  - 프로비저닝/검증 도구: `infra/aws/tofu-app-security/scripts/provision-keycloak-demo-identity.sh`, `verify-demo-identity-access-analyzer.sh`, `verify-demo-identity.sh`
  - GitOps Ingress 미들웨어: `gitops/apps/keycloak/middleware-ciem-vpc-admin.yaml`
