# ADR-0015: Vault seal을 AWS KMS auto-unseal로 전환

- 상태: `Accepted`
- 날짜: 2026-08-03
- 대체: [ADR-0006](0006-vault-seal-and-bootstrap-boundary.md)의 Day 1 Shamir 운영 결정
- 관련 작업: `BKP-03`, `BKP-05`, `CAP-03`, `KMS-01`

## 배경

ADR-0006은 Vault와 S3 복구 drill, AWS IAM·KMS 최소권한과 비용·감사 기준, 반복되는 수동
unseal 비용을 재검토 조건으로 두었다. `BKP-03`과 `BKP-05`가 snapshot restore와 통합 재해복구를
실증했다. `CAP-03` cold start에서는 3/3 Shamir 입력이 실제로 필요했고, Vault 가용성에 의존하는
workload가 늘어 사람 개입이 부팅 복구시간의 고정 병목이 됐다. 남은 IAM·KMS 조건은 KMS-01에서
live policy, 장애 시험, 가격 계산과 CloudTrail event로 닫는다.

auto-unseal은 편의를 얻는 대신 AWS 인증·KMS·공인 API egress를 Vault 부팅 경로에 넣는다.
따라서 AWS가 없을 때의 거동과 KMS에서 다시 Shamir로 돌아오는 절차가 함께 검증돼야 한다.

## 결정

**Vault Community의 AWS KMS auto-unseal을 사용한다.** 서울 region의 대칭 single-Region customer
managed key 한 개를 고정 alias로 참조한다. endpoint override나 Site-to-Site VPN을 두지 않고
공인 AWS KMS API endpoint를 사용한다.

**KMS는 별도 OpenTofu state가 소유한다.** `infra/aws/tofu-kms`는 KMS key·alias와 Vault 전용
service IAM user·inline policy·access key만 가진다. 삭제 방지 backup bucket, 비용 gate가 있는
VPN, 사람용 SAML role과 수명주기·rollback을 섞지 않는다. 오프사이트 S3는 SSE-S3를 유지해
Vault의 KMS 장애가 백업 복호화까지 동시에 막지 않게 한다.

**Vault identity에는 exact key의 `kms:Encrypt`, `kms:Decrypt`, `kms:DescribeKey`만 허용한다.**
온프레미스 Pod에는 AWS instance profile이 없으므로 전용 long-lived access key를 사용한다.
원본은 저장소 밖 `$KTC_SECRET_ROOT/kms-01/env`, runtime copy는 `vault` namespace의
`vault-awskms` Secret 한 곳이다. GitOps는 Secret 원문을 소유하지 않는다.

**Shamir 복귀 능력을 계속 보존한다.** migration 전 Raft snapshot을 만들고 기존 Shamir share로
KMS migration한 뒤, 그 share가 recovery share가 된 상태에서 auto-unseal→Shamir→auto-unseal
rollback drill을 수행한다. 마지막에는 recovery key를 5 shares/threshold 3으로 재생성·검증해
클러스터 밖에 보관한다. 새 recovery share 3개가 `disabled=true` KMS seal migration을 승인하므로
KMS가 가용한 동안 Shamir로 되돌릴 수 있다. recovery key 자체로 KMS 장애 중 Vault를 unseal할
수는 없다.

## 검토한 대안

- **수동 Shamir 유지:** AWS 장애와 독립적이지만 모든 cold start가 3개 share의 사람 입력을
  요구하고 Vault Agent init·Issuer 등 직접 소비자가 늘수록 복구 병목이 커진다.
- **VPN/VPC endpoint를 KMS 선행으로 사용:** 공인 인터넷을 피하지만 비용과 VPN 장애를 부팅
  경로에 더한다. 기존 정책이 공인 S3·STS·KMS endpoint를 허용하므로 얻는 복구 이점이 없다.
- **오프사이트 S3도 같은 KMS key로 SSE-KMS 전환:** key 수는 줄지만 KMS 장애가 Vault 부팅과
  최종 backup 복호화를 함께 막는다. backup root의 SSE-S3 결정을 유지한다.
- **IAM Roles Anywhere:** long-lived access key를 없앨 수 있지만 별도 CA·trust anchor·주기적
  자격증명 helper가 Vault 부팅 전에 동작해야 한다. 단일 on-prem Pod의 현재 범위보다 bootstrap
  구성과 장애면이 크므로 채택하지 않는다.

## 결과

- 정상 재부팅은 AWS KMS `Decrypt`가 성공하면 사람 입력 없이 unseal된다.
- KMS 권한이나 public endpoint가 unavailable인 동안 재기동한 Vault는 sealed로 남는다. 권한이
  복구되면 auto-unseal retry가 다시 성공할 수 있다.
- KMS customer managed key 고정비와 API 요청비가 생기며, 사용·거부 호출은 CloudTrail
  management event로 감사한다. 가격 산정은 `infra/aws/tofu-kms/README.md`가 소유한다.
- access key, recovery share, root token과 KMS state는 Git 밖의 사용자 보관 자산이다.
- rollback은 data/PVC나 KMS key 삭제가 아니라 seal migration이다. KMS key 폐기는 Shamir
  재부팅까지 확인한 별도 작업에서만 가능하다.

2026-08-03 `KMS-01`에서 위 결과를 라이브로 확인했다. 완료 증거는
[`docs/evidence/kms-01`](../evidence/kms-01/README.md)에 기록하며, seal 외 KV·auth·PKI 경계는
`VAULT-02` 판정을 재사용한다.

## 재검토 조건

- long-lived AWS access key의 회전 비용이나 위험이 허용 범위를 넘으면 Roles Anywhere를
  독립 bootstrap 경로로 검증한다.
- KMS public API 장애가 허용 복구시간을 반복해 넘으면 서로 다른 실패 도메인의 두 번째 seal
  또는 수동 Shamir 운영 복귀를 검토한다.
- Vault replica와 물리 장애 도메인이 늘면 single-Region key와 단일 Pod migration 절차를 다시
  설계한다.
