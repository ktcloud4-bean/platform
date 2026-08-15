# AWS-SEC-07 완료 증거

검증일: 2026-08-15
브랜치: `feat/aws-sec-07`

## 범위

`/service/` IAM identity 네 개의 access key를 read-only로 관찰하고, owner·생성일·마지막
사용·90일 회전기한을 보안 SNS에 알리는 Lambda와 월간 schedule을 추가했다. 회전 자체는
사람 승인 아래 consumer별 dual-key runbook으로만 수행한다.

key ID와 secret은 이 문서, Lambda 반환값, CloudWatch log, SNS 본문에 기록하지 않는다.

## 완료 증거 요약

| 항목 | 결과 |
|---|---|
| 라이브 대상 계수 | `service_users=4`, `service_keys=4`, 각 user active key 1개 |
| 라이브 수명 기준 | 생성 age 0~14일, 마지막 사용 최근, 90일 초과 0개 |
| 누락 경보 | Owner tag 누락 4건을 `ALERT`로 판정 |
| 자동 조치 | disable/delete 0건 |
| read-only IAM policy | `UpdateAccessKey`·`DeleteAccessKey` 0건 |
| monthly schedule | `ENABLED`, `cron(15 0 1 * ? *)` |
| final OpenTofu plan | `No changes` |

## 라이브 Lambda 실행

```text
inventory_status=ALERT expected_users=4 observed_service_users=4 observed_service_keys=4 issue_count=4 automatic_disable_delete=0
response_secret_scan=PASS
```

현재 owner 누락은 결함으로 숨기지 않고 경보 대상이다. 생성일·마지막 사용·회전기한은
Lambda SNS 본문에 key ID 없이 함께 표시하도록 선언했으며, 단위 fixture가 이 본문에
`created`, `last_used`, `rotation_deadline`, `owner=MISSING`을 포함하고 key material을
포함하지 않음을 확인했다.

## 선언·권한·정적 검증

```text
tofu init -backend=false + validate                         PASS
tofu fmt -check + git diff --check                          PASS
service inventory mocked handler                          PASS
AWS apply: 9 added, 0 changed, 0 destroyed                 PASS
AWS-SEC-07 service policy mutation actions                 0
final tofu plan                                             No changes
```

추가된 AWS 리소스는 inventory Lambda, Lambda log group/error alarm, read-only role/policy,
Lambda 기본 log attachment, Scheduler invoke policy, monthly schedule과 permission이다.
기존 IAM user/key, Vault secret, Harbor DB, Argo Secret 및 다른 root state는 변경하지 않았다.

## 회전 runbook

상세 순서와 rollback은
[`docs/runbook/aws-service-access-key-rotation.md`](../../runbook/aws-service-access-key-rotation.md)가
소유한다. 네 consumer는 `object-01` offsite backup, Vault KMS auto-unseal, Argo private EKS,
Harbor ECR replication이며 공통 순서는 다음과 같다.

```text
두 번째 key 생성 → 외부/Vault 원본 갱신 → consumer canary → 새 key 사용 확인
→ 이전 key 비활성화 → grace window 후 이전 key 삭제
```

실패하면 이전 key를 먼저 유지하고 새 key만 폐기한다. 자동 회전·자동 폐기와 credential
원문 출력은 없다.
