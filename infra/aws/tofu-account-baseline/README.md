# AWS 계정 보안 기준선

작업: `AWS-SEC-01`
잠금: `TOFU-STATE`, `AWS-ACCOUNT-SEC`

이 root는 계정 전역 CloudTrail·Config·Security Hub FSBP·GuardDuty·Access
Analyzer·Security Lake·CIS CloudWatch alarm 12개·보안 SNS/Slack·계정 보안 설정을
소유한다. HR RDS audit WORM, VPC Flow Logs, Grafana와 CIEM/ASR은
`tofu-app-security`의 후속 작업 범위다.

## 입력과 첫 적용

실제 입력은 저장소 밖 mode `0600` 파일에 둔다. `terraform.tfvars.example`은 값 없는
형식 참고용이고 Git에 실제 연락처·Slack 식별자·PagerDuty URL을 넣지 않는다.

기존 `management-events` multi-region CloudTrail은 새 trail을 만들지 않는다. 아래
import 도구가 이를 baseline state로 가져온 뒤, 로그 파일 검증·전용 S3·CloudWatch Logs
전송을 보정한다. Config service-linked role과 AWS 기본 Cost Explorer dimensional monitor가
이미 있으면 같은 도구가 import하며, 적용자 AWS STS account ID를 provider guard에 전달한다.

```bash
cd infra/aws/tofu-account-baseline
scripts/import-existing.sh /absolute/path/account-baseline.tfvars
tofu plan -input=false -var-file=/absolute/path/account-baseline.tfvars
# 명시된 계정 보안 변경 승인 뒤에만
tofu apply -input=false -var-file=/absolute/path/account-baseline.tfvars
```

## 적용 영향과 rollback

- 기존 CloudTrail의 S3 목적지·KMS·CloudWatch Logs 연동과 log-file validation을 보정한다.
- Config recorder를 모든 지원 리소스/글로벌 IAM 리소스에 대해 켜고, FSBP·GuardDuty·Security
  Lake·Access Analyzer·CIS metric alarm·account S3 public access block·EBS 기본 암호화와
  snapshot public sharing 차단·IAM password policy를 적용한다.
- CloudTrail/Config bucket·KMS·CloudWatch Logs는 `prevent_destroy`로 보호한다. 제거가
  필요한 경우 이 보호를 별도 변경과 plan으로 해제해야 한다.
- `enable_cis_benchmark=false`는 유지한다. Slack workspace는 Terraform 전에 AWS Console의
  Amazon Q Developer in chat applications에서 승인하고 private `security-alerts` 채널에
  Amazon Q 앱을 초대한다.

## 후속 root contract

`tofu-app-security`은 remote state에서 다음 네 값만 읽는다.

- `security_alerts_topic_arn`
- `cloudtrail_arn`
- `cloudtrail_log_group_name`
- `access_analyzer_arn`
