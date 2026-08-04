# ADR-0017: 팀 신원 이름과 Shuffle 권한 수명주기

- 상태: `Accepted`
- 날짜: 2026-08-04
- 관련 작업: `IAM-01`, `IAM-MIG-01`, `SOAR-01`
- 구체화하는 결정: [ADR-0004](0004-zero-trust-identity-and-management-access.md)

## 배경

Keycloak에는 초기 구축자의 일상·특권 ID가 있고 Shuffle에는 배포 bootstrap용 local admin과
기본 조직만 있다. 팀원이 늘어난 상태에서 이 구성을 그대로 확장하면 사람 이름, GitHub ID,
OIDC shadow user와 서비스 local user가 서로 달라지고, 웹 Route 통과와 서비스 내부 권한도
쉽게 혼동된다. 반대로 기존 ID를 즉시 rename하거나 삭제하면 OIDC subject, 소유 리소스와
유일 Owner 참조를 잃을 수 있다.

팀은 평소 가능한 범위에서 넓은 조회 권한이 필요하지만, 워크플로 실행·권한 관리·계정 복구는
조회와 다른 위험을 가진다. Keycloak이나 OIDC 장애 때 Shuffle 자체를 복구할 경로도 중앙
인증과 독립적으로 남아야 한다. 이 결정은 ADR-0004의 중앙 IdP, 일상·특권 분리, 서비스 자체
인가와 break-glass 원칙을 Shuffle과 팀 계정 수명주기에 맞게 구체화하며 대체하지 않는다.

## 결정

GitHub username을 사람 계정의 canonical username으로 사용하되 GitHub를 새 IdP로 추가하지
않는다. 인증과 MFA는 Keycloak이 계속 소유한다. OIDC 연결에 필요한 실제 email은 검증된
보호 입력으로만 받고 Git, 문서, 채팅과 검증 로그에는 저장하지 않는다. 직무명은 설명 정보일
뿐 권한 부여 근거가 아니다.

모든 팀원에게 MFA를 요구하는 일상 계정을 하나씩 만들고 `/platform-users`에 둔다. 총괄
운영자만 별도의 특권 계정을 가지며 일상 계정에 admin 권한을 겹쳐 주지 않는다. 팀원용 local
계정과 공유 관리자 계정은 만들지 않는다. 서비스마다 IdP 장애와 독립적인 local break-glass
계정은 하나만 유지하고 MFA, 비공유, API key 미발급과 정기 복구 검증을 적용한다.

Shuffle은 단일 팀 조직을 사용한다. Keycloak 그룹과 Shuffle 전용 client role은 다음처럼
매핑하고 한 계정에는 세 애플리케이션 role 중 정확히 하나만 발급한다.

| Keycloak 그룹 | Shuffle client role | 용도 |
|---|---|---|
| `/soar-readers` | `shuffle-org-reader` | 조직 리소스 조회, 쓰기·실행 금지 |
| `/soar-operators` | `shuffle-user` | 승인된 워크플로 작성·실행 |
| `/platform-privileged` | `shuffle-admin` | 조직·사용자·권한 관리 |

팀 일상 계정은 reader로 시작한다. 운영자 권한은 실제 워크플로 작업이 시작될 때 reader
membership을 제거한 뒤 부여한다. 특권 계정은 admin만 가진다. Pomerium은 위 세 그룹의
Shuffle Route 진입만 결정하며, Shuffle은 OIDC role claim으로 내부 인가를 다시 결정한다.
일반 `/platform-users` membership만으로는 Shuffle에 들어갈 수 없다.

Shuffle OIDC는 비밀 없는 public Authorization Code + PKCE client로 구성하고 implicit,
password grant와 service account를 사용하지 않는다. role claim 없는 로그인을 거부한다.
자동 프로비저닝은 팀원이 직접 MFA 로그인하는 통제된 등록 창에서만 허용하고 canonical
username을 확인한 뒤 끈다. local break-glass 로그인을 보존하기 위해 SSO-only로 강제하지
않는다.

기존 ID는 직접 rename하거나 즉시 삭제하지 않는다. 새 계정을 먼저 만들고 client·서비스별
OIDC 연결, 영속 사용자, 소유 리소스와 유일 Owner를 조사해 이전한다. 새 계정의 권한을 증명한
뒤 기존 session을 revoke하고 계정을 disable한다. 비활성 계정은 최소 90일의 감사 보존과
rollback 기간 동안 유지하며, 참조가 없다는 별도 판정과 삭제 승인이 있을 때만 제거한다.

## 검토한 대안

- **GitHub를 추가 IdP로 사용:** username 원본과 인증 원본을 불필요하게 결합하고 Keycloak의
  MFA·그룹 수명주기를 우회하므로 채택하지 않는다.
- **일상 계정에 admin을 추가하거나 공유 admin 사용:** 피싱·오조작의 영향과 책임 추적 범위를
  키우므로 채택하지 않는다.
- **reader·operator·admin role을 함께 발급:** 애플리케이션의 role 우선순위에 권한이 암묵적으로
  달라지고 최소권한 검증이 불명확해져 채택하지 않는다.
- **모든 로그인을 OIDC로 강제:** IdP 장애가 Shuffle 복구를 막으므로 local break-glass를
  유지한다.
- **기존 ID를 바로 rename 또는 delete:** OIDC subject와 서비스 ownership을 잃을 수 있어
  단계적 이전·disable·보존을 선택한다.
- **팀원별 Shuffle local 계정 생성:** 비밀번호·MFA·회수 지점이 서비스마다 늘어나므로 만들지
  않는다.

## 결과

- 팀원이 동일한 이름으로 로그인하고 넓은 조회 권한을 받되 쓰기·실행·관리는 명시적으로
  분리된다.
- Pomerium 접근과 Shuffle 인가를 각각 검증할 수 있어 한 계층의 허용을 최종 권한으로 오해하지
  않는다.
- 일상, 특권과 복구 계정이 분리되어 사고 영향과 복구 순환 의존을 줄인다.
- 초기 등록에는 팀원별 MFA 로그인 조율이 필요하고, legacy ownership 전수 조사와 비활성 계정
  보존이라는 운영 비용이 남는다.

## 재검토 조건

- GitHub 조직 lifecycle을 자동화된 입·퇴사 원본으로 채택한다.
- Shuffle이 local break-glass와 OIDC role을 안전하게 함께 지원하지 않게 된다.
- 여러 보안팀·테넌트가 생겨 단일 조직과 세 role로 격리할 수 없다.
- 운영자가 늘어 JIT elevation이나 별도 privileged access governance가 필요하다.
