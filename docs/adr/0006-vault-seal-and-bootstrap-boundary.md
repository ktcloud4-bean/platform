# ADR-0006: Vault Shamir Day 1과 bootstrap 경계

- 상태: `Superseded` ([ADR-0015](0015-vault-aws-kms-auto-unseal.md))
- 날짜: 2026-07-30
- 관련 작업: `VAULT-01`, `VAULT-02`, `BKP-03`, `BKP-05`, `KMS-01`

## 배경

Vault가 시작되기 전에도 Vault 초기화 출력, k3s 복구 자격증명과 S3 복구 권한이 필요하다. 이 값을 Vault에만 저장하면 전체 장애 시 Vault를 열기 위해 Vault가 필요한 순환 의존이 생긴다. AWS KMS auto-unseal은 편리하지만 Day 1부터 AWS 권한과 네트워크를 Vault 부팅 경로에 추가한다.

## 결정

Day 1은 Vault Community Edition, Integrated Storage와 수동 Shamir unseal을 사용한다. Shamir share와 초기 root token은 Git과 클러스터 밖에서 사용자가 암호화해 보관한다. root token은 초기화와 복구에만 사용한다.

Vault 기능은 KV v2, Kubernetes auth, 지원 서비스의 Database secrets engine, 내부 PKI, audit device와 Raft snapshot으로 제한한다. 애플리케이션별 policy와 auth role을 분리하고 GitOps는 시크릿 원문을 소유하지 않는다.

AWS KMS auto-unseal은 Vault 백업·복구와 수동 unseal 운영을 검증한 뒤 별도 migration으로 수행한다. AWS Site-to-Site VPN은 KMS, S3와 STS 사용의 필수 선행조건으로 만들지 않고 공인 AWS API endpoint 사용을 허용한다.

## 검토한 대안

- **AWS KMS auto-unseal을 Day 1부터 사용:** 운영은 편하지만 초기 구축과 복구가 AWS IAM·KMS 상태에 바로 의존한다.
- **모든 복구 값을 Vault에 저장:** 전체 장애에서 순환 의존으로 복구할 수 없다.
- **정적 시크릿만 파일로 관리:** 초기 구성은 단순하지만 회전, 단기 DB 자격증명과 감사 경계를 잃는다.

## 결과

- 재부팅 후 수동 unseal과 share 보관 책임이 남는다.
- AWS 장애와 무관하게 Day 1 Vault를 복구할 수 있다.
- 클러스터 밖 break-glass 사본이 별도 보안 자산이 된다.
- KMS migration에는 snapshot, 장애 시험과 rollback drill이 필요하다.

## 재검토 조건

- Vault와 S3 복구 drill을 완료한다.
- AWS IAM·KMS 최소권한과 비용·감사 기준을 검증한다.
- 수동 unseal이 허용 가능한 운영시간을 반복해서 초과한다.

## 2026-08-03 재검토 결과

`BKP-03`·`BKP-05`가 첫 조건을, `KMS-01`의 exact-key 3-action IAM policy·고정비/API 단가
계산·CloudTrail 성공/거부 event가 둘째 조건을 충족했다. 셋째 조건은 반복 초과 전이라도
`CAP-03` cold start의 실제 3/3 입력과 Vault Agent·Issuer 의존 증가를 근거로 전환 비용이
이미 고정 병목이라고 판정했다. 사전 snapshot, KMS 장애, Shamir rollback과 무인 재기동을
실증했으므로 Day 1 결정을 [ADR-0015](0015-vault-aws-kms-auto-unseal.md)가 대체한다.
