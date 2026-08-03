# KMS-01 Vault AWS KMS auto-unseal 증거

이 문서는 2026-08-03 `VAULT-INIT` 단독 창에서 Vault의 **seal 경계만** 검증한 결과다.
KV·auth·PKI는 `VAULT-02` 판정을 재사용했고, Vault Agent init workload 재생성과
`CERTMGR-01` Issuer 검증은 같은 창에서 실행하지 않았다.

## 시작점과 비밀 경계

- 최신 시작 main: `a8b67a023df37ebb6722181eb563ab6bb3d05c91`
- 라이브 시작점: `platform-root`·`vault` 모두 위 main에서 `Synced/Healthy`, Vault는
  initialized/unsealed Shamir 5-of-3 Raft였다.
- AWS 자격증명은 `${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}/kms-01/env`, Vault root
  token과 share는 같은 저장소 밖 사용자 보관 경계의 mode `0600` 파일만 사용했다.
- `vault/vault-awskms`에는 AWS SDK 표준 key 두 개만 reconcile했고 외부 원본과 exact match를
  확인했다. 값은 Git, stdout, 명령 인자와 Pod log에 출력하지 않았다.
- migration 전 Raft snapshot은 저장소 밖
  `kms-01/vault-raft-pre-kms-01.snap`, 175,605 bytes이며 SHA-256은
  `1edd1ae64a28787069e53656a7691e5ee8580647a5315c70ea4f616242e7d7b7`이다.

## AWS state·최소권한·비용

`infra/aws/tofu-kms` 별도 state의 최초 plan은 create 5, change 0, destroy 0이었다. 적용 뒤
plan은 무변경이며 다음 다섯 자원만 소유한다.

- 대칭 single-Region customer managed KMS key 1개와 alias 1개
- Vault 전용 IAM user, exact-key inline policy, access key 각 1개

KMS key는 `Enabled`, `ENCRYPT_DECRYPT`, `SYMMETRIC_DEFAULT`, multi-Region false, rotation off다.
key policy는 account root의 IAM 위임만 두고 service 권한은 inline policy의
`kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey` 세 action과 생성한 key 하나로 한정했다.
managed policy와 group membership은 0개다. KMS state·plan·output은 저장소 밖 mode `0600`,
상위 디렉터리는 mode `0700`이다.

2026-08-03 공식 가격 기준 customer managed key 고정비는 월 USD 1이다. 대칭 API request는
계정 월 20,000건 free tier 이후 10,000건당 USD 0.03이므로, 일 1회 재기동의 `Decrypt` 31건은
free tier가 이미 소진돼도 `31 / 10,000 × 0.03 = USD 0.000093/월`이다. 실측 과금을 기다리지
않고 이 계산으로 비용 gate를 닫았다.

## migration·무인 재기동·장애 시험

정상 KMS 선언 commit `3960b111bdb2fcd2c684bfac59b8d96b885f6cc2`를 child에 고정하고
기존 Shamir share 3개를 `migrate=true` request body로 제출했다. 최종 상태는
`sealed=false`, `seal_type=awskms`, `migration=false`, `recovery_seal=true`, 5-of-3이었다.

정상 auto-unseal 재기동은 migration 뒤 새 Vault Pod가 recovery share 입력 없이
`sealed=false`, `seal_type=awskms`에 도달해 한 번 통과했다. 이 실행은 IAM 철회 전파보다 Pod
기동이 먼저 끝났으므로 **무인 재기동 증거로만** 사용하고 장애 증거로 세지 않았다.

장애 시험은 endpoint 차단 없이 IAM inline policy 회수 한 방법만 사용했다.

1. `enable_vault_kms_access=false` plan이 inline policy 한 개의 delete뿐임을 확인해 적용했다.
2. Vault service credential의 `DescribeKey`가 `AccessDenied`가 될 때까지 기다려 IAM 전파를
   결정론적으로 확인했다.
3. Vault Pod를 한 번 재생성했다. KMS `AccessDenied` log와 Pod NotReady를 함께 확인했다.
4. `true` plan이 같은 policy 한 개의 create뿐임을 확인해 적용했다.
5. 별도 share 입력 없이 **같은 Pod UID**가 `sealed=false`, `seal_type=awskms`, Ready로
   복구됐다. 최종 OpenTofu plan은 무변경이다.

완료 증거로 쓰지 않은 진단도 남긴다. 실행 중 Vault의 API seal은 재기동 전 KMS를 호출하지
않아 첫 시도가 장애를 만들지 못했다. IAM 거부 뒤 실행 중 내부 data encryption key 회전도
예상과 달리 성공해 key term이 1에서 2로 증가했다. 이는 unsealed process가 보유한 barrier
key로 처리되므로 startup 장애 시험이 아니라는 원인을 확인한 것이며, IAM policy를 즉시
복구했다. 이후 위 절차처럼 **거부 전파 뒤 startup**을 판정 지점으로 고정했다.

## seal rollback과 recovery share

transient 정상/rollback 선언은 다음 immutable SHA로 검증했다.

| 단계 | child 선언 | root pointer | 결과 |
|---|---|---|---|
| KMS 정상 | `3960b111bdb2fcd2c684bfac59b8d96b885f6cc2` | `6b0b9b1126d413cf6f33931daf4f12105ba20c7f` | Shamir→awskms migration |
| Shamir rollback | `cd8a0f56f910cbdb1d8f2099412e5ce08745d92c` | `6b3624b04218852d470a1dc1ddd2191403383dd3` | `disabled=true`, awskms→Shamir migration |
| KMS 복원 | `b920a8b389b7cdef76722648c2bc378fbfb6d65d` | `d709b520f35da3e2b1b5d76ac7ab3c5286a665d2` | Shamir→awskms migration |

rollback 단계는 `sealed=false`, `seal_type=shamir`, `migration=false`,
`recovery_seal=false`, 5-of-3과 Pod Ready를 확인했다. KMS 복원 뒤에는 다시
`sealed=false`, `seal_type=awskms`, `migration=false`, `recovery_seal=true`, 5-of-3이었다.

최종 recovery key는 새 5 shares/threshold 3으로 생성하고 verification을 끝냈다. 새 파일은
저장소 밖 mode `0600`으로 보존하며, 더 이상 유효하지 않은 기존
`vault-unseal-keys.b64`는 정확한 경로를 확인한 뒤 삭제했다. recovery share는 KMS 장애 중
Vault를 직접 unseal하지 못하지만, KMS가 가용한 동안 `disabled=true` migration을 승인해
Shamir로 돌아가는 경로를 보존한다. branch 검증 종료 때도 새 recovery share 3개로 Shamir
migration을 완료하고 시작 main의 Shamir 선언에서 일반 unseal까지 성공해 새 자산으로 같은
복귀 경로가 동작함을 확인했다.

## CloudTrail 감사 결과

기존 trail 1개와 CloudTrail Event History의 `EventSource=kms.amazonaws.com` 첫 50건에서
이번 창의 다음 event를 확인했다. 식별자·ARN·credential 원문은 증거 문서에 복제하지 않는다.

| event | 결과 | 확인 건수 |
|---|---|---:|
| `Decrypt` | Success | 9 |
| `Encrypt` | Success | 7 |
| `DescribeKey` | Success | 10 |
| `DescribeKey` | AccessDenied | 8 |
| `Encrypt` | AccessDenied | 1 |

따라서 정상 migration/restart와 장애 주입의 성공·거부 호출이 모두 CloudTrail management
event로 남는다는 감사 기준을 충족했다. 원본 lookup JSON은 Git이 아니라 저장소 밖 mode
`0600` 증거 파일로만 보관한다.

## 판정

사전 snapshot, IAM 회수 한 방법의 KMS 장애, seal rollback, exact-key 3-action 최소권한,
공식 단가 계산과 CloudTrail 기록, migration 뒤 무인 auto-unseal, 새 recovery share 기반
Shamir 복귀 경로를 모두 확인했다. VPN/VPC endpoint는 추가하지 않고 서울 region 공인 AWS
KMS API endpoint를 사용한다. `KMS-01`을 `DONE`으로 판정하며 직접 후속은 없다.
