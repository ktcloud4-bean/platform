# AWS 서비스 access key 가시화·dual-key 회전

작업: `AWS-SEC-07`

이 문서는 `/service/` IAM identity 네 개의 access key 수명과 회전 절차를 소유한다.
관찰 대상과 회전 기준의 단일 선언은
[`infra/aws/tofu-app-security/variables.tf`](../../infra/aws/tofu-app-security/variables.tf)의
`ciem_service_key_identities`와 `ciem_service_key_rotation_days`다.

## 안전 경계

- `ciem-service-key-inventory` Lambda는 `ListUsers`, `ListAccessKeys`,
  `GetAccessKeyLastUsed`, `ListUserTags`와 보안 SNS `Publish`만 사용한다.
- 출력·Lambda 반환값·CloudWatch 로그·SNS 본문에는 access key ID와 secret을 넣지 않는다.
- owner는 IAM user의 `Owner` tag, 생성일은 IAM `CreateDate`, 마지막 사용은
  `GetAccessKeyLastUsed`, 회전기한은 생성일 + `ciem_service_key_rotation_days`로 계산한다.
- owner·생성일·마지막 사용이 없거나 회전기한에 도달하면 `ALERT`를 발행한다.
- 이 경로에는 `iam:UpdateAccessKey`와 `iam:DeleteAccessKey`가 없다. 자동 disable/delete는
  항상 0건이다.

기본 회전 기준은 90일이며 매월 1일 UTC 00:15에 실행한다. 회전 전에 inventory 결과에서
대상 role, user, slot, owner, 생성일, 마지막 사용일, 회전기한만 확인한다. key ID·secret은
화면이나 완료 기록으로 복사하지 않는다.

## 공통 dual-key 절차

한 번에 한 service만 회전한다. `TOFU-STATE`를 확인하고 해당 consumer의 현재 healthy
상태를 기록한다.

1. 기존 key를 건드리지 않고 두 번째 key를 생성한다. 생성 응답의 secret은 mode `0600`
   저장소 밖 임시 파일로만 전달하며 셸 history, 로그, Git, OpenTofu state에 넣지 않는다.
2. 해당 consumer의 원본 보관소를 새 key로 갱신한다. Vault에 보관하는 경우 새 version을
   먼저 기록하고, runtime에 반영한다. 기존 key와 두 key가 동시에 유효한 시간을 짧게
   유지한다.
3. consumer canary를 실행한다. 성공 기준은 서비스별 절차의 정상 API/업로드/인증 한 번이며,
   secret·bearer token·key ID를 출력하지 않는다.
4. consumer가 새 key를 사용한 사실을 확인한 뒤에만 이전 key를 `Inactive`로 바꾸고,
   grace window가 지난 뒤 이전 key를 삭제한다. 삭제는 사람 승인과 해당 consumer 소유자의
   확인을 모두 요구한다.
5. 새 key 하나만 남았는지와 AWS-SEC-07 inventory의 다음 실행 결과를 확인한다.

두 번째 key 생성부터 이전 key 삭제까지 어느 단계에서든 실패하면 새 key를 먼저 폐기하고,
기존 key와 원본 보관소를 유지한다. 이전 key를 먼저 비활성화하지 않는다.

## 서비스별 consumer canary와 rollback

| 역할 | 원본·consumer | canary | 실패 시 rollback |
|---|---|---|---|
| `backup` | `object-01`의 `/etc/offsite-backup/offsite.env`, `offsite-backup.service` | `sudo systemctl start offsite-backup.service` 후 timer와 heartbeat 성공 확인 | 새 key를 폐기하고 기존 env를 유지·재실행; 원본 데이터와 AWS bucket은 삭제하지 않음 |
| `vault_auto_unseal` | 저장소 밖 `kms-01/env` → `vault/vault-awskms` Secret; KMS seal은 exact key만 사용 | Secret reconcile 후 Vault `sealed=false`와 새 로그의 성공 KMS 호출을 확인. Vault를 강제 seal하지 않음 | 기존 Secret/runtime copy를 유지하고 새 key를 폐기; 필요 시 기존 IAM key를 계속 사용 |
| `argocd_credential_issuer` | Vault `kv/aws-hr-01/argocd` → Argo controller memory credentials | `gitops/tools/aws-hr-01/provision-argocd-eks.sh check` 및 controller의 private EKS 인증 1회 | 새 key를 폐기하고 기존 Vault version·controller revision을 유지; rollout 실패 시 runbook의 `rollout undo` 경로 사용 |
| `harbor_ecr_replicator` | Vault `kv/harbor/ecr-replicator`와 Harbor encrypted ECR endpoint working copy | Harbor registry ping 후 `gitops/tools/supply-07/destination-verifier.sh` 1회 | 새 key를 폐기하고 기존 Vault version/Harbor endpoint를 유지; 기존 scheduled policy와 ECR artifact는 삭제하지 않음 |

각 consumer의 secret 원본과 runtime working copy가 동시에 갱신돼야 한다. 한 곳만 갱신된
상태에서 이전 key를 비활성화하지 않는다. 서비스가 사용하는 AWS 권한이나 다른 IAM user,
Vault path, Harbor policy, Argo cluster Secret은 이 작업에서 변경하지 않는다.

## read-only 확인

```bash
cd infra/aws/tofu-app-security
tofu init
tofu plan -var-file=/저장소_밖/app-security.tfvars
```

plan에는 service key의 create/disable/delete가 없어야 한다. inventory를 수동 실행할 때도
`aws iam list-users`, `list-access-keys`, `get-access-key-last-used`, `list-user-tags`만
사용하고, key ID 필드는 변수로 받아도 출력하지 않는다. 최종 OpenTofu plan은
`0 to add, 0 to change, 0 to destroy`여야 한다.

## 되돌리기

이 작업이 만든 것은 inventory Lambda, 월간 Scheduler schedule, read-only IAM role/policy,
log group, Lambda error alarm이다. 문제 시 schedule을 먼저 disable하고, 마지막 정상 main
revision으로 `tofu plan`을 확인한 뒤 이 작업의 선언만 revert한다. 네 consumer credential,
IAM user/key, Vault data, Harbor DB와 ECR artifact는 삭제·재생성하지 않는다.
