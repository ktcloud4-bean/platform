# QUALITY-04 완료 증거

검증일: 2026-08-15
플랫폼 브랜치: `task/quality-04`
권위 제품 저장소 반영: GitHub `ktcloud4-bean/hr-system` main `b73a48948c20cf40cd8b04e1ea9c992448fdd1e4`

## 결론

세 제품 컴포넌트에 지정된 테스트 계층과 coverage floor를 구현했다. 테스트가 재현한 HR
신규 직원·감사이력 partial commit과 frontend API 부분 성공 표시를 최소 범위로 보정했다.
제품 PR #1은 작업 커밋 `92f14afcadce4f21dab02602620ab32f9c7eba23`을 squash merge했다.

## 변경 범위

| 컴포넌트 | 구현·검증 |
|---|---|
| `employee-service` | pytest/TestClient, dependency override, 인증 header 누락·정규화·미등록 계정, 본인 정보·history만 조회, configuration branch coverage |
| `hr-service` | pytest/TestClient, HR/non-HR·대상 은닉·중복 email, position/salary 감사이력, 신규 직원과 감사이력 단일 transaction 및 rollback, migration unit test |
| `frontend` | Vitest·React Testing Library, exact `www`/`admin` route, 인증 실패, form/modal, salary/history, API 부분 실패 시 modal 유지 및 성공 후에만 닫힘 |

## 완료 증거

| 증거 | 결과 |
|---|---|
| `employee-service` pytest/JUnit | 4 passed; `coverage.xml` branch 포함 총 95% |
| `hr-service` pytest/JUnit | 11 passed; `coverage.xml` branch 포함 총 94% |
| 임시 PostgreSQL integration | migration 2회 멱등성, bootstrap 1건 유지, PUBLIC database/schema 제한, employee role SELECT-only, HR role DML 허용·schema CREATE 거부 PASS |
| transaction failure injection | API 500 재현 뒤 신규 employee row와 `employee_created` audit row 모두 0건 PASS |
| frontend Vitest/RTL | 10 passed; lines/statements 96.69%, branches 83.47%, functions 94.87% |
| frontend production build | Vite build PASS |

Python 결과는 각 service의 `coverage.xml`·`test-results/junit.xml`, frontend 결과는
`coverage/lcov.info`·`test-results/junit.xml`을 생성했으며 생성물은 커밋하지 않았다.

## 경계·복구

- 임시 PostgreSQL 컨테이너는 검증 후 제거했다. 제품 DB, EKS·Aurora·Keycloak·실사용자,
  Argo·Jenkins·SonarQube·Vault·credential에는 접근하거나 변경하지 않았다.
- 제품 source rollback 지점은 main의 `b73a48948c20cf40cd8b04e1ea9c992448fdd1e4`이며,
  필요 시 해당 squash commit을 revert한다. 라이브 rollback은 발생하지 않았다.
- 직접 후속 `QUALITY-05`는 모든 선행이 완료되어 `READY`로 열었다. `QUALITY-06`은
  `QUALITY-05` 완료 전까지 `BLOCKED`를 유지한다.
