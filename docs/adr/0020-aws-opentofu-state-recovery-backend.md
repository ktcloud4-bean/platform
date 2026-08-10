# ADR-0020: AWS legacy OpenTofu state를 분리 S3 backend로 복구

- 상태: `Accepted`
- 날짜: 2026-08-10
- 관련 작업: `AWS-STATE-RECOVERY-01`, `AWS-NET-01`, `BKP-04`, `AWS-CI-FIX-01`

## 배경

오프사이트 백업 root와 Site-to-Site VPN root는 각각 IAM access key와 IPsec pre-shared key가
포함될 수 있는 local state를 사용했다. 두 state가 유실된 뒤 기존 AWS 리소스는 살아 있었지만
state S3 bucket에는 해당 객체와 이전 version이 없었다. 빈 state에서 apply하면 같은 bucket·VPN
리소스를 중복 생성하거나 충돌시키므로, 실제 리소스를 먼저 import해야 했다.

기존 state bucket과 DynamoDB lock table은 이미 versioning·암호화·전송 TLS 정책을 갖춘 별도
착지점이다. Jenkins의 plan 전용 IAM policy는 app network·ECR key로 제한되어 있어, legacy
root의 비밀 포함 state를 Jenkins에 노출하지 않고도 administrator 전용 backend를 둘 수 있다.

## 결정

**오프사이트와 VPN root를 서로 다른 S3 state key로 이전한다.** 두 root는 수명주기와
`destroy` 위험이 다르므로 state를 합치지 않는다. key마다 S3 backend encryption과 DynamoDB
lock table을 사용하며, bucket의 versioning·public access 차단·TLS 이외 접근 거부를 그대로
보안 경계로 쓴다.

**복구는 별도 mode `0600` 임시 state에서만 한다.** 실물 식별 → import → 무변경 plan →
`init -migrate-state` 순서를 강제한다. raw state·plan·PSK·access key는 Git과 Jenkins log에
남기지 않는다.

**Jenkins 권한은 넓히지 않는다.** Jenkins는 app network·ECR의 plan 전용 `v1` key만 계속
접근한다. legacy root의 import·plan·apply·state migration은 `TOFU-STATE`를 소유한
administrator가 수행한다.

AWS provider가 static VPN route import를 지원하지 않아, 해당 route 하나는 승인 아래 삭제한
뒤 동일 선언으로 즉시 재생성했다. 이후에는 remote state가 이 주소를 보존하므로 이 절차를
반복하지 않는다.

## 검토한 대안

- **local state를 계속 사용:** 비밀의 원격 보관을 피하지만 유실·동시 실행·복구 시점의
  중복 생성 위험이 다시 남는다.
- **두 root를 하나의 state로 합치기:** 관리 파일은 줄지만 백업 bucket과 비용성 VPN의
  수명주기·destroy 범위가 서로 얽힌다.
- **Jenkins에 legacy key 권한 추가:** 계획은 편해지지만 controller 밖 CI job에 PSK·access key
  state를 읽을 수 있는 권한을 준다.
- **raw state 수동 편집:** provider schema와 민감 필드를 임의로 재구성하게 되어 import보다
  검증 가능성이 낮다.

## 결과

- 두 root의 현재 소유권과 lock이 원격 backend에 보존된다.
- state bucket이나 lock table이 접근 불능이면 legacy root 변경도 중단된다.
- S3 state는 민감 정보를 포함할 수 있으므로 administrator credential과 제한된 bucket policy가
  복구 경로의 일부가 된다.
- VPN 터널 가동성은 state 복구와 별도 운영 증거다. 이번 복구 시점에는 활성 터널이 없어
  state 재구성의 완료 증거에 포함하지 않는다.

## 재검토 조건

- S3 state bucket·DynamoDB lock의 접근 경계나 암호화 정책이 바뀐다.
- Jenkins가 legacy root를 실행해야 하는 실제 요구가 생긴다.
- provider가 static VPN route import를 지원해 재생성 없는 복구가 가능해진다.
- AWS 계정·region 또는 VPN 토폴로지가 바뀐다.
