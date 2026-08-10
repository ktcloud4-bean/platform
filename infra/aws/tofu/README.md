# AWS 오프사이트 착지점 · OpenTofu

검증일: 2026-07-31 (`BKP-04` 라이브 적용). 백업 계층 결정은
[ADR-0005](../../../docs/adr/0005-backup-and-offsite-recovery.md), state 경계 원칙은
[ADR-0008](../../../docs/adr/0008-opentofu-provider-and-state-boundary.md)가 소유한다.
전송 경로와 검증 증거는
[docs/runbook/seaweedfs-s3-offsite-backup.md](../../../docs/runbook/seaweedfs-s3-offsite-backup.md)가
소유한다.

## 이 root가 소유하는 것

온프레미스 SeaweedFS의 오프사이트 사본이 착지하는 AWS 자원만 소유한다. 12개 리소스로
bucket과 그 보호 설정, 전송 전용 IAM identity, 경보 채널을 선언한다.

`infra/proxmox/tofu`와 **state를 공유하지 않는다.** 두 계층은 실패 도메인도 자격증명도
다르고, 한쪽 `destroy`가 다른 쪽을 사정권에 넣으면 안 된다. 계정 안의 다른 자원
(기존 CloudTrail bucket 등)은 `resource`로 선언하지도 `import`하지도 않는다.

같은 이유로 `AWS-NET-01`이 만든 사설 착지점(`infra/aws/tofu-network`)과도 state를
공유하지 않는다. 이 bucket은 지워지면 안 되는 자산이고 그쪽 VPN은 비용 때문에 언제든
내릴 수 있어야 한다. 오프사이트 전송은 계속 공인 AWS API endpoint로 나가며 그 VPN을
경유하지 않는다.

`KMS-01`의 Vault auto-unseal key와 service identity는 `infra/aws/tofu-kms`의 별도 state가
소유한다. Vault seal은 부팅 경계이고 이 root의 bucket은 최종 복구 자산이므로 수명주기와
rollback을 섞지 않는다. bucket의 SSE-S3 `AES256`도 유지한다. 같은 KMS key로 SSE-KMS까지
묶으면 KMS 장애가 Vault 부팅과 오프사이트 사본 복호화를 동시에 막기 때문이다.

## 실행

실제 변수값은 저장소 밖 파일에 둔다. 계정 ID와 경보 이메일은 커밋하지 않는다.

```bash
cd infra/aws/tofu
tofu init
tofu plan  -var-file=<저장소 밖 tfvars>
# 명시적 승인 뒤에만 실제 적용
tofu apply -var-file=<저장소 밖 tfvars>
```

관리자 자격증명은 AWS CLI profile 또는 표준 환경변수로만 주입한다. 이 root가 만드는
전송용 access key로 이 root를 적용하지 않는다. 그 key에는 IAM 권한이 없다.

`allowed_account_ids`가 provider 단계에서 계정을 강제한다. 다른 계정 자격증명으로
실행하면 plan이 실패한다.

## 고정 값

| 항목 | 값 | 근거 |
|---|---|---|
| OpenTofu | `~> 1.12` (1.12.5로 검증) | `versions.tf` |
| AWS provider | `hashicorp/aws` 6.56.0 | 정확히 고정. 루트 `.gitignore`가 lock 파일을 제외하므로 재현성의 근거가 이 줄뿐이다 |
| region | `ap-northeast-2` | 변수 기본값 |
| 암호화 | SSE-S3 `AES256` | Vault auto-unseal KMS와 state·key를 공유하지 않아 seal 장애가 최종 복구 사본까지 번지지 않는다 |

6.57.x는 릴리스 당일 패치가 나온 계열이라 후속 패치 없이 일주일을 넘긴 6.56.0을 골랐다.
갱신은 자동으로 오지 않는다. 사람이 릴리스 노트를 읽고 plan을 본 뒤 올린다.

## state와 자격증명

state backend는 전용 S3 bucket의
`platform/infra/aws/tofu/terraform.tfstate` key다. 이 bucket은 versioning·SSE-S3·public
access 차단·TLS 이외 접근 거부를 적용하고 DynamoDB lock table을 함께 쓴다. state에는 IAM
access key secret이 들어갈 수 있으므로 administrator OpenTofu 실행만 이 key에 접근한다.
Jenkins는 app network·ECR의 별도 `v1` key만 읽고 이 root를 실행하거나 state를 읽지 않는다.

`AWS-STATE-RECOVERY-01`에서 유실된 legacy state를 실물 import한 뒤, 무변경 plan을 확인하고
이 backend로 이전했다. 재복구가 필요하면 S3 state를 먼저 보존하고 저장소 밖 mode `0600` 임시
state에서 import·무변경 plan을 끝낸 뒤에만 `tofu init -migrate-state`를 쓴다. raw state와
plan 파일은 Git·Jenkins log·일반 작업 디렉터리에 두지 않는다.

`aws_iam_access_key`는 생성 시점에만 secret을 평문으로 돌려주므로 선언형으로 다루려면
state 보안을 받아들여야 한다. 회수한 자격증명은 저장소 밖 mode `0600` 파일에만 둔다.

```bash
# 전송용 자격증명 회수 (값을 화면에 남기지 않는다)
umask 077
{
  echo "AWS_ACCESS_KEY_ID=$(tofu output -raw backup_access_key_id)"
  echo "AWS_SECRET_ACCESS_KEY=$(tofu output -raw backup_secret_access_key)"
} > <저장소 밖 경로>/offsite-backup.env
```

이 값은 Ansible role `seaweedfs_offsite_backup`의 extra-vars로만 들어가고, host에서는
`/etc/offsite-backup/offsite.env` mode `0600` 한 곳에만 놓인다.

## gate

| 변수 | 기본값 | 언제 여는가 |
|---|---|---|
| `enable_heartbeat_alarm` | `false` | object host에 오프사이트 job이 배포되어 정기 실행될 때. 열어 둔 채 job을 내리면 alarm이 영구히 울린다 |
| `create_backup_access_key` | `true` | 닫으면 IAM user만 만들고 key는 만들지 않는다. key를 사람이 따로 관리할 때 |
| `alert_email` | `""` | 빈 문자열이면 구독을 선언하지 않는다 |

email 구독은 적용만으로 활성화되지 않는다. 수신자가 확인 메일의 링크를 눌러야 하며
그전까지 `alert_subscription_pending` output이 `true`다.

## 폐기

`aws_s3_bucket.offsite`에는 `prevent_destroy = true`가 걸려 있다. 오프사이트 사본을
담은 bucket이 `tofu destroy` 한 번으로 사라지지 않게 하려는 것이다. 실제로 폐기하려면
사람이 그 줄을 내리고 별도 plan을 확인해야 한다.

전송 identity에는 삭제 action이 없으므로 이 identity로는 사본을 지울 수 없다. 정리에는
관리자 자격증명이 필요하다. 이것은 제약이 아니라 의도한 경계다.
