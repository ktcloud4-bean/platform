# ADR-0026: AWS 보안 통제의 계정·애플리케이션 경계

- 상태: `Accepted`
- 날짜: 2026-08-14
- 관련 작업: `AWS-SEC-DESIGN-01`, `AWS-CI-FIX-02`, `AWS-SEC-01`~`06`, `AWS-DB-SEC-01`

## 배경

닫힌 PR #53의 `feat/aws-security` 브랜치(`74cf782`)는 `tofu-security` 하나에 계정
전역 싱글턴과 HR 애플리케이션 통제를 함께 넣었다. 이 상태로는 이미 켜져 있을 수 있는
계정 서비스를 import할 경계, apply 순서, rollback 반경, 계정 단위 변경의 잠금을 분명히
할 수 없다.

원본을 읽어본 결과 세션 종료 Lambda가 NAT 없는 VPC에서 IAM·SNS를 호출하려 하고, RDS
점검 Lambda에는 Aurora ingress가 없으며, Slack callback signing secret이 코드 고정값이고,
CIEM access-key 점검은 `/service/` 경로의 정적 키 네 개도 삭제 후보로 판정한다.
또한 [ADR-0019](0019-private-aws-service-egress.md)는 앱 네트워크에 NAT Gateway가 없고
필요한 AWS 서비스 endpoint만 허용한다는 전제를 이미 확정했다.

## 결정

### root와 상태 경계

보안 선언을 다음 두 OpenTofu root로 나눈다. 디렉터리 이름과 backend key는 같은 root
식별자를 사용하며, 각 root는 다른 root의 resource를 선언하거나 import하지 않는다.

| root | 소유 범위 |
|---|---|
| `infra/aws/tofu-account-baseline/` | CloudTrail·KMS·CloudWatch Logs, Config recorder/delivery와 관리형 규칙 5개, Security Hub FSBP, GuardDuty, Access Analyzer, Security Lake, CIS alarm 12개, 보안 SNS·Chatbot, S3 Block Public Access·EBS 기본 암호화·공개 스냅샷 차단·암호 정책·보안 연락처, 예산·비용 이상 탐지 |
| `infra/aws/tofu-app-security/` | HR RDS 감사 로그 WORM, HR VPC와 default VPC의 `REJECT` Flow Log, 애플리케이션 S3 hardening, Managed Grafana SAML·Athena·Glue, CIEM 보고·승인 조치·권한 drift 감시, ASR 원복, 격리 데모 identity와 검증 시나리오 |

`tofu-account-baseline`을 먼저 적용하고, `tofu-app-security`은 그 remote state에서 SNS ARN,
CloudTrail ARN, CloudTrail log group 이름, Access Analyzer ARN 네 값만 읽는다. 이 방향을
역전하거나 순환 의존을 만들지 않는다. 기존 `tofu-app-network`, `tofu-app-db`,
`tofu-identity`의 resource 소유권은 바꾸지 않는다.

계정 전역 서비스가 preflight에서 이미 활성으로 나오면 새로 만들지 않고
`tofu-account-baseline` state로 import한다. 계정 전역 root의 plan/apply는
`AWS-ACCOUNT-SEC`과 해당 OpenTofu state 잠금을 함께 잡는다. OpenTofu root는 Argo CD가
적용하지 않으므로 이 작업 흐름에 `ARGO-ROOT` 잠금을 추가하지 않는다.

### 네트워크·CIEM 조치 경계

NAT Gateway나 `0.0.0.0/0` egress를 보안 편의 기능으로 추가하지 않는다. IAM·SNS를
호출하는 Slack callback 오케스트레이터는 VPC 밖에 두고, Keycloak 호출이 필요한 세션
종료 조치 Lambda만 VPC와 기존 VGW 사설 경로에 둔다. 따라서 AWS API 호출과 Keycloak
호출은 분리되며 [ADR-0019](0019-private-aws-service-egress.md)의 endpoint-only 앱
egress가 유지된다.

CIEM의 권한 사용 분석, Slack 승인 callback, 세션 종료, 권한 경계 drift 감시는 AWS 안에서
완결한다. Shuffle은 Wazuh 탐지의 로컬 read-only 보강과 사람 승인 기록 경계이므로 AWS IAM
실행자로 연결하지 않는다. 이를 연결하면 별도 egress·자격증명·승인면이 생기고 AWS
CloudTrail/Access Analyzer 근거와 조치 주체가 분리된다.

Slack 인터랙션은 유지하되 자동 권한 회수 통로로 쓰지 않는다. callback은 다음을 모두
만족해야 조치를 시작한다.

- Terraform은 Slack signing secret을 생성·기록하지 않으며, runtime secret이 없으면
  callback을 fail-closed로 거부한다.
- 허용목록 밖 사용자는 거부하고, 동일 버튼 재클릭은 멱등으로 처리한다.
- Slack에는 3초 안에 응답하고 최종 결과는 `response_url`로 돌려준다.
- 조치 Lambda 실패는 성공으로 보고하지 않는다. `errorCode`가 있는
  `AttachRolePolicy` 이벤트는 drift가 아닌 실패 이벤트로 제외한다.
- `/service/` 경로 IAM 사용자 네 개는 access-key 삭제 후보에서 제외하고, 마지막 사용
  시점을 기준으로 사람 검토 대상만 만든다.

세션 종료와 권한 축소 실증은 `AWS-SEC-04`의 격리 테스트 사용자·데모 SAML Role만
대상으로 한다. 운영 SAML Role의 정책·membership은 이 설계의 조치 대상이 아니다.

### RDS 감사 로그 보존

RDS 감사 로그 전용 bucket은 Object Lock을 켠 새 bucket으로 만들고, versioning과
`COMPLIANCE` retention 4일을 사용한다. 4일은 랩에서 보존 불변성과 만료 뒤의 destroy
경로를 모두 검증할 수 있는 최소 기간이며, `GOVERNANCE` 모드처럼 특권 주체가 보존을
우회할 수 있는 선택은 쓰지 않는다. 전용 audit 자산이므로 오프사이트 백업 bucket의
보존 정책과 섞지 않는다. 보존 뒤 transition은 30일, expiration은 210일로 선언한다.

COMPLIANCE 객체는 4일 전에는 일반 관리자도 삭제할 수 없으므로, 검증·폐기는 만료 후에만
진행한다. 더 긴 법정 보존 기간이나 감사 대상 확대가 확정되면 이 기간을 새 결정으로
재검토한다.

### 원본 브랜치 처리와 구현 순서

`feat/aws-security`의 `74cf782`은 `AWS-SEC-01`~`AWS-SEC-06`과
`AWS-DB-SEC-01` 구현 파일의 **원본**으로만 사용한다. 159개 resource를 가진 기존
`tofu-security`를 통째로 cherry-pick하거나 apply하지 않고, 후속 작업이 위 소유 경계에
맞춰 두 root로 이식·보정한다. `AWS-SEC-06`의 검증이 끝날 때까지 이 원격 브랜치를
삭제하지 않는다.

구현 순서는 Jenkins가 두 root를 plan-only로 실행할 수 있게 하는 `AWS-CI-FIX-02`, 계정
기준선을 만드는 `AWS-SEC-01`, 앱 통제를 만드는 `AWS-SEC-02`, 그 뒤 CIEM·데모·DB·ASR
검증 작업 순서다.

## 검토한 대안

1. **기존 `tofu-security` 단일 root 유지**: 계정 싱글턴 import와 HR 변경의 state·rollback
   반경이 섞이고, 계정 단위 승인과 앱 검증을 분리할 수 없어 채택하지 않는다.
2. **CIEM 조치를 Shuffle에 통합**: AWS IAM 실행 권한과 외부 callback egress를 Shuffle에
   추가하고, 현재 Wazuh의 read-only 사람 승인 경계를 무너뜨리므로 채택하지 않는다.
3. **NAT Gateway로 Lambda egress 허용**: endpoint-only 최소 egress라는 ADR-0019를
   우회하고 비용·공격면을 늘리므로 채택하지 않는다.
4. **Object Lock `GOVERNANCE` 또는 보존 없음**: 전자는 보존 우회 주체를 남기고 후자는
   WORM 증거가 없으므로 채택하지 않는다.
5. **Slack 자동 조치 또는 비서명 callback**: 사람 승인·서명 검증·대상 제한이 사라지므로
   채택하지 않는다.

## 결과

계정 전역 변경은 import 가능한 단일 baseline state와 명시적 계정 잠금으로 수렴하고,
HR 보안 기능은 그 출력만 소비한다. AWS IAM 조치는 CloudTrail·Access Analyzer 근거와 같은
경계에서 추적되며, 운영자 판단은 Slack의 서명된 인터랙션으로 남는다. 이 ADR 자체는
문서 결정만 확정하며 AWS 계정·OpenTofu state·Slack·Keycloak에 변경을 가하지 않는다.

## 재검토 조건

- 멀티 계정·멀티 리전 또는 Security Lake/Config 집계 계정이 도입될 때
- NAT, egress proxy, 추가 AWS API 또는 VPC endpoint 요구가 확정될 때
- 법정 감사 보존 기간·Object Lock 모드·RDS 감사 대상이 바뀔 때
- Slack의 signing/callback 모델, 사람 승인 절차, 또는 Shuffle의 권한 경계가 바뀔 때
- `AWS-SEC-06` 결과가 두 root의 소유 경계나 원본 이식 계획의 결함을 보일 때
