# QUALITY-03 완료 증거

검증일: 2026-08-15
브랜치: `feat/quality-03`

## 결론

SonarQube 폐기 경로를 철회하고 HR System의 실제 제품 품질 gate로 채택한다. 구현은 source
test·초기 80%를 만드는 `QUALITY-04`, Jenkins·Sonar release gate를 연결하는 `QUALITY-05`,
배포 read-only E2E를 추가하는 `QUALITY-06` 순서로 분리했다. 이번 작업은 현재 선언과 제품
제약을 확정한 문서 작업이며 라이브 자원은 변경하지 않았다.

## 현재 source·CI 판정

권위 source는 private GitHub `ktcloud4-bean/hr-system`이고, 2026-08-15 `main` tree
`29ae41d42cb6dc30d53d31a37e22643b6fec5ec7`을 read-only로 확인했다.

| 항목 | 확인 결과 |
|---|---|
| 제품 구성 | `employee-service`·`hr-service`는 FastAPI/SQLAlchemy/PostgreSQL, `frontend`는 React/Vite다. |
| 기존 test | tree 전체에 test source·pytest/Vitest/Playwright·coverage·Sonar 설정이 0건이다. frontend script는 `dev`·`build`·`preview`뿐이고 Python requirements에는 test dependency가 없다. |
| 제품 pipeline | Gitea pull-mirror `main` checkout 뒤 frontend dependency/build, Python dependency, 세 image build, Trivy/SBOM, Harbor push, Cosign, release handoff 순서다. test·JUnit·coverage·Sonar stage는 0개다. |
| 기존 Jenkins | Node·Python·Sonar scanner sidecar는 있으나 JUnit plugin과 PostgreSQL test sidecar가 없다. 합성 `quality01-pass` token만 파생한다. |
| edition 제약 | SonarQube Community Build 자동 분석은 main branch 범위다. coverage는 외부 runner가 Python Cobertura XML과 JavaScript LCOV를 먼저 만들어 import해야 한다. |

## source에서 우선 검증할 위험

- Pomerium email header 누락·공백·대소문자 정규화, 미등록 사용자와 비HR 사용자의 401/404/403
  경계가 분기돼 있다.
- employee API는 본인 profile/history만, HR API는 HR 사용자를 목록·조회·수정 대상에서 숨겨야
  한다.
- 신규 직원 저장 뒤 감사이력을 별도 commit하고 있어 두 번째 commit 실패 시 partial data가
  남을 수 있다.
- frontend의 HR 수정은 position과 salary API를 순차 호출하고 각 HTTP 실패를 확인하지 않아
  부분 실패를 성공처럼 닫을 수 있다.
- migration은 role 생성·grant·PUBLIC revoke와 bootstrap HR identity를 함께 수행하므로 SQLite나
  mock SQL만으로 완료를 판정할 수 없다.

따라서 `QUALITY-04`는 실제 임시 PostgreSQL의 migration 2회, role별 허용·거부, transaction
failure injection과 frontend 부분 실패를 포함한다. 제품 DB와 실사용 identity를 테스트 fixture로
사용하지 않는다.

## 채택 경계

| 판정 | 결정 |
|---|---|
| 초기·지속 coverage | Python service 각각 branch 측정 총계 80% 이상, frontend lines·functions·branches·statements 각각 80% 이상 |
| Sonar gate | 한 `hr-system` project, Community Build main release gate, Sonar way new-code coverage 80% 이상 |
| 실행 순서 | test·JUnit/coverage·Sonar gate가 image build와 Harbor push보다 먼저 |
| test dashboard | Jenkins JUnit이 성공·실패·시간·추세 소유 |
| code quality dashboard | SonarQube가 coverage·issue·hotspot·duplication 소유 |
| 배포 E2E | 전용 합성 identity·fixture의 read-only 3개 흐름, JUnit·합성 실패 screenshot만 보존, coverage 제외 |
| 초기 제외 | Allure, Grafana test dashboard, Jenkins Coverage plugin, 운영 DB write E2E |

구체적인 선택 이유·대안·재검토 조건은
[ADR-0029](../../adr/0029-hr-system-testing-and-sonarqube-release-gate.md)이 소유한다.

## 변경 없음 증거

- SonarQube Application·Deployment·PVC·PostgreSQL DB/role 변경 0건
- Vault path·policy·role와 Jenkins credential 변경 0건
- GitHub/Gitea HR System source write 0건
- Argo `targetRevision`, EKS·Aurora·Keycloak·OPNsense 변경 0건
- Secret·token·cookie·개인정보 출력·Git 기록 0건
