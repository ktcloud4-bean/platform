# ADR-0029: HR System 테스트와 SonarQube 릴리스 gate

- 상태: `Accepted`
- 날짜: 2026-08-15
- 관련 작업: `QUALITY-02`~`06`, `CI-01-FIX-01`, `SUPPLY-05-FIX-02`, `SUPPLY-07`

## 배경

`QUALITY-02`는 당시 제품 source와 CI에 SonarQube 사용이 없음을 확인하고 폐기를 후속 경로로
열었다. 이후 제품 소유자가 SonarQube를 유지하고 HR System에 실제 테스트와 80% 이상
커버리지 gate를 붙이는 방향을 명시적으로 선택했다. 따라서 미사용 판정은 당시 상태의 증거로
보존하되, 폐기 결론은 현재 의사결정으로 대체해야 한다.

HR System source의 단일 원본은 private GitHub 저장소 `ktcloud4-bean/hr-system`이다. Gitea의
동명 저장소는 내부 Jenkins가 읽는 pull-mirror일 뿐 source 변경 원본이 아니다. 현재 제품은
FastAPI 기반 `employee-service`·`hr-service`와 React/Vite 기반 `frontend` 세 컴포넌트로
구성되고, Jenkinsfile은 mirror의 `main`을 읽어 image build와 공급망 gate를 수행한다. 테스트
framework·test source·coverage report·JUnit report·Sonar project 설정은 아직 없다.

SonarQube Community Build는 main branch 자동 분석만 제공한다. 따라서 지원하지 않는 PR 분석을
merge gate로 약속할 수 없고, main에 들어온 exact source를 image build·승격 전에 막는 release
gate로 사용해야 한다. 또한 SonarQube는 커버리지를 직접 만들지 않으므로 테스트 도구가 먼저
Cobertura XML과 LCOV를 생성해야 한다. 최초 분석의 new-code 기준만으로 기존 source 전체가
80%임을 증명할 수 없으므로 초기 도입 gate와 이후 new-code gate를 분리한다.

## 결정

### 1. source와 실행 원본을 분리한다

- 코드·테스트·테스트 설정·제품 Jenkinsfile은 GitHub `ktcloud4-bean/hr-system`에서만 변경한다.
- Gitea는 read-only pull-mirror 역할을 유지한다. Jenkins는 실행 전에 GitHub `main`과 mirror
  `main`의 exact SHA 일치를 확인하고 그 SHA 하나만 분석·build한다.
- 플랫폼 저장소는 Jenkins agent·credential·SonarQube·GitOps 선언과 이 백로그 상태만 소유한다.

### 2. 테스트 계층의 책임을 다음처럼 고정한다

| 계층 | 대상과 도구 | 실행 시점 | 책임 |
|---|---|---|---|
| 단위·API component | Python `pytest`·FastAPI `TestClient`·dependency override, frontend Vitest·React Testing Library | 모든 제품 `main` build | 인증 header 정규화, 권한 분기, validation, UI 상태·오류 처리 |
| service integration | 임시 실제 PostgreSQL과 두 FastAPI service | 모든 제품 `main` build | migration 멱등성, DB role 최소권한, transaction·constraint, 실제 SQL 동작 |
| 배포 E2E | Playwright Chromium | 검증 digest가 배포된 뒤 별도 job | Pomerium·route·배포 앱을 통과하는 핵심 사용자 흐름 |

SQLite는 PostgreSQL role·grant·sequence·transaction 동작을 증명하지 못하므로 service integration
대체재로 쓰지 않는다. AWS·Aurora·Keycloak은 매 build의 단위·service integration에서 호출하지
않고 명시적 dependency override와 임시 PostgreSQL을 사용한다.

### 3. 80%를 컴포넌트별 실행 gate로 만든다

- `employee-service`와 `hr-service`는 branch coverage를 켠 coverage.py 결과가 각각 80% 미만이면
  실패한다. 각 service는 Cobertura XML과 JUnit XML을 생성한다.
- `frontend`는 Vitest의 lines·functions·branches·statements가 각각 80% 미만이면 실패하고,
  LCOV와 JUnit XML을 생성한다.
- 세 컴포넌트의 수치를 합산해 한 컴포넌트의 미검증 코드를 다른 컴포넌트가 가리는 방식은
  허용하지 않는다. vendor·build 산출물만 제외하고 migration·auth·오류 분기는 측정 대상이다.
- 배포 E2E는 커버리지 숫자에 합산하지 않는다. 80%는 빠르고 결정론적인 단위·service
  integration·component test가 소유한다.

SonarQube에는 제품 전체를 하나의 `hr-system` project로 분석한다. Python Cobertura XML 두 개와
frontend LCOV를 import하고, Sonar way의 new-code 조건(새 issue 0, 새 security hotspot 100%
review, new-code coverage 80% 이상, duplication 3% 이하)을 release gate로 사용한다. 최초
도입부터 각 컴포넌트 80% floor를 계속 유지하므로 new-code 기준의 초기 공백을 테스트 runner가
보완한다.

### 4. 품질 gate를 image 생산보다 앞에 둔다

제품 `main` pipeline 순서는 다음과 같다.

```text
GitHub main = Gitea mirror main SHA 확인
  → dependency 설치
  → 단위·API component·실제 PostgreSQL service integration
  → JUnit·coverage report 게시
  → Sonar scan과 quality gate 대기
  → frontend build·세 image build
  → Trivy·SBOM·Cosign·Harbor 승격과 ECR handoff
```

테스트 또는 Sonar gate가 실패하면 JUnit 결과는 남기되 image build·Harbor push·GitOps digest
변경은 0건이어야 한다. 합성 `quality01-pass` token을 재사용하지 않고 `hr-system` 전용 project
token을 Vault에서 Jenkins credential로 파생한다. `sonar.projectVersion`에는 build number나
commit SHA가 아니라 제품이 한 곳에서 소유하는 안정 release version을 넣고, release 기준을
바꿀 때만 version을 올린다.

Community Build 분석은 PR merge gate라고 부르지 않는다. PR 단계에서는 같은 test runner의
80% floor를 개발자가 실행하고, 자동 Sonar gate는 main release에만 적용한다. PR 분석이 필수가
되면 지원 edition 또는 다른 PR 분석 수단을 별도 결정한다.

### 5. 대시보드는 데이터 소유자별로 둘만 유지한다

- Jenkins JUnit 화면은 suite별 성공·실패·소요시간·추세를 소유한다. test command가 실패해도
  `finally` 경계에서 report를 게시하며 빈 report를 성공으로 허용하지 않는다.
- SonarQube project 화면은 overall/new-code coverage, issue, hotspot review와 duplication을
  소유한다.
- Playwright JUnit은 항상 게시하고 합성 화면의 실패 screenshot만 단기 보존한다. 인증
  cookie·network payload를 담을 수 있는 trace와 video는 초기 범위에서 만들지 않는다.

초기 범위에는 Allure, Grafana test dashboard, Jenkins Coverage plugin을 추가하지 않는다.
같은 test·coverage 숫자를 여러 제품에 복제하면 판정 원본과 보존 정책만 늘어나기 때문이다.

### 6. 배포 E2E는 작고 read-only로 제한한다

Playwright는 전용 합성 employee·HR identity와 합성 fixture만 사용해 다음 세 흐름만 Chromium
한 worker, retry 0으로 확인한다.

1. employee가 자신의 profile·history만 본다.
2. employee가 HR route/API에 접근하지 못한다.
3. HR identity가 HR 화면에 접근하고 HR 사용자가 관리 대상 목록에서 제외됨을 본다.

현재 제품에는 직원 삭제와 감사이력 rollback API가 없으므로 운영 DB에서 create/update E2E를
실행하면 완전한 원상복구를 증명할 수 없다. 쓰기 transaction은 임시 PostgreSQL integration
test가 담당한다. 향후 합성 데이터만 가진 폐기 가능한 배포 환경을 확보한 뒤에만 write E2E를
추가한다. 실패 screenshot에는 합성 데이터만 포함하고 trace·video·상시 screenshot은 만들지
않는다.

## 검토한 대안

1. **SonarQube 폐기**
   - 제품 owner가 실제 source quality gate로 채택했고 기존 설치를 재사용할 수 있으므로 현재
     요구와 맞지 않는다.
2. **unit test만 추가**
   - PostgreSQL migration·role·transaction과 HTTP/UI 결합 오류를 놓치므로 부족하다.
3. **배포 E2E만으로 80% 달성**
   - 느리고 불안정하며 실패 위치가 넓고 branch coverage를 결정론적으로 만들 수 없다.
4. **세 컴포넌트 합산 coverage 80%**
   - 큰 frontend 또는 한 service가 다른 service의 미검증 코드를 가릴 수 있다.
5. **Community Build를 PR 분석 gate로 표기**
   - 제품 edition 제약과 다르고 실행할 수 없는 완료 기준이 된다.
6. **Allure·Grafana·Coverage plugin을 함께 도입**
   - JUnit과 Sonar가 이미 소유하는 지표를 중복 저장하므로 초기 규모에 비해 운영비가 크다.

## 결과

- `QUALITY-02`의 미사용 판정은 당시 snapshot으로 유지되며 폐기 후속만 철회된다.
- `QUALITY-04`가 제품 source의 테스트와 컴포넌트별 80% floor를 먼저 만든다.
- `QUALITY-05`가 기존 Jenkins·SonarQube를 실제 release gate와 두 대시보드에 연결한다.
- `QUALITY-06`은 배포 뒤 최소 read-only E2E만 추가하며 80% 수치와 분리된다.
- SonarQube 자원·DB·PVC와 합성 E2E project는 당장 삭제하지 않는다. 제품 gate 전환과 기존
  합성 검증의 정리 여부는 구현 작업의 검증 뒤 판단한다.

## 재검토 조건

- PR·다중 branch Sonar 분석이 release 전에 의무가 될 때
- 세 컴포넌트가 독립 release cadence와 owner를 가져 Sonar project 분리가 필요할 때
- 실제 PostgreSQL integration 시간이 main build의 허용 시간을 지속적으로 넘을 때
- 합성 데이터만 가진 폐기 가능한 배포 환경이 생겨 write E2E를 안전하게 원복할 수 있을 때
- 테스트 이력·규제 보고 요구가 Jenkins JUnit과 SonarQube 보존 범위를 넘을 때

## 제품 제약 근거

- [SonarQube Community Build 분석 범위](https://docs.sonarsource.com/sonarqube-community-build/analyzing-source-code/analysis-overview)
- [Sonar way quality gate](https://docs.sonarsource.com/sonarqube-community-build/quality-standards-administration/managing-quality-gates/introduction-to-quality-gates)
- [SonarQube coverage report parameter](https://docs.sonarsource.com/sonarqube-community-build/analyzing-source-code/test-coverage/test-coverage-parameters)
- [SonarQube new-code 기준](https://docs.sonarsource.com/sonarqube-community-build/user-guide/about-new-code)
- [Jenkins JUnit 결과·추세](https://www.jenkins.io/doc/pipeline/steps/junit/)
- [FastAPI TestClient와 dependency override](https://fastapi.tiangolo.com/advanced/testing-dependencies/)
- [Vitest coverage threshold](https://vitest.dev/guide/cli.html#coverage-thresholds-lines)
- [Playwright JUnit reporter](https://playwright.dev/docs/test-reporters)
