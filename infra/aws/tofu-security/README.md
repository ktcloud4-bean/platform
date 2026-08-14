# HR application security/CSPM root

이 root는 project-c(AWS 단독 PoC)에서 검증한 보안 통제 전체(CloudTrail, Security Hub
+ suppress, GuardDuty, Config 관리형 규칙, S3/CloudWatch 하드닝, VPC Flow Logs, ASR
자동 원복, CIEM 권한 드리프트 탐지+Slack 1-Click 잠금/축소, Amazon Managed Grafana
SOC 대시보드)를 실제 계정(`tofu-app-network`/`tofu-app-eks`가 이미 만든 HR 워크로드)
위에 적용하는 root다.

CIEM(권한 드리프트/세션 강제 종료)의 감시 대상은 project-c의 가상 8-Role이 아니라
**`tofu-identity`가 실제로 소유한 4개 읽기전용 SAML Role**
(`platform-saml-observer`/`observability-reader`/`security-reader`/`identity-reader`)
이다 - 실제로 사람이 Keycloak SSO로 assume하는 유일한 Role들이기 때문. `tofu-identity`는
`backend "local"`이라 이 root와 state를 공유하지 않으므로, Role 이름은 결정론적 규칙을
그대로 재현해서 계산한다(`locals.tf` 참고, 실제 정의는 `tofu-identity/iam.tf` 소유).

`tofu-app-network`/`tofu-app-eks` state가 먼저 존재해야 VPC/서브넷/EKS 정보를 참조할 수
있다. backend는 `platform/infra/aws/tofu-app-security/v1/terraform.tfstate`.

## project-c 대비 달라진 점

- Keycloak/Pomerium을 이 root가 직접 배포하지 않는다 - 이미 온프레미스 k3s에서 실제로
  운영 중(`gitops/` 소유).
- Slack App Bot Token/Signing Secret, `psycopg2_layer_arn`, `keycloak_test_users_password`는
  `terraform.tfvars`에 두지 않는다 - `tofu-identity`의 SAML metadata와 같은 이유로 apply
  직후 Secrets Manager 콘솔/CLI로 직접 채운다.
- Grafana 대시보드 JSON(`docs/grafana/*.json`)은 project-c 템플릿을 그대로 쓴다(요청사항).

## 시작하기 전에

**`합치기-전-체크리스트.md`부터 읽으세요.** 라이브 인프라 선행 작업(tofu-app-db의
IAM DB 인증 켜기 등), 수동으로 채워야 하는 시크릿/변수, 검증 안 된 가정, 스코프에서
뺀 것(03/07/12)이 정리되어 있습니다.

## 포함된 것

- CSPM 베이스라인: CloudTrail, Security Hub, GuardDuty, Config, CloudWatch CIS 알람,
  S3 하드닝, VPC Flow Logs, RDS 감사로그 WORM, 보안 알림(SNS+Slack+PagerDuty)
- CIEM: 월간 Unused Access 리포트, Access Key 예외 승인, 권한 드리프트+Slack 축소,
  IAM Boundary 위반 감시+세션 강제 종료, DB 마스킹 우회 자동 REVOKE
- ASR(자동 원복), Security Lake, Grafana(SAML+SOC 대시보드)
- 시나리오 검증 스크립트: `scripts/scenarios/05,06,08,09,10,11,13` (03/07/12는 제외)

## 아직 안 한 것

- 실제 `terraform.tfvars` 작성 (`variables.tf`의 필수 변수 참고 - 예시 파일은 따로
  안 만들어뒀음)
- AGENTS.md의 백로그 작업 절차(전용 브랜치+worktree, 백로그 ID)에 맞춰 이 root를
  `infra/aws/tofu-app-security/`로 옮기고 백로그 ID를 붙이는 작업은 사용자가 직접 진행
