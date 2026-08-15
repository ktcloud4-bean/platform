# QUALITY-06 완료 증거

## 판정

`QUALITY-06`은 배포 뒤 별도 Jenkins Playwright E2E를 합성 identity·fixture로 한 번
성공시켰다. 제품 release gate와 분리했으며, E2E는 배포 데이터에 쓰기 요청을 보내지 않는다.

| 항목 | 증거 | 결과 |
|---|---|---|
| 제품 source/mirror | GitHub·Gitea `main` SHA `5e6cc104119821044136dbf5fabb119b44eee331` 일치 | PASS |
| 합성 fixture | `provision-synthetic.py --mode=--apply`가 synthetic employee·HR identity, employee/HR fixture 수렴 | PASS |
| Jenkins E2E | `hr-system-e2e` build #26, `DEPLOYED_SOURCE_SHA=5e6cc104119821044136dbf5fabb119b44eee331` | SUCCESS |
| JUnit | pass 3, fail 0, skip 0 | PASS |
| 실행 경계 | Chromium worker 1, retry 0, JUnit 게시, trace/video off, failure screenshot만 보관 | PASS |

## 검증한 세 read-only 흐름

1. synthetic employee가 `www`에서 자기 profile 하나를 보고, 같은 인증 browser context로
   `/api/employee/me/history`만 HTTP 200으로 조회한다.
2. 같은 employee가 `admin` route와 `/api/hr/me`에 HTTP 302 또는 403만 받는다.
3. synthetic HR identity가 `admin` HR 화면에 접근하고, HR identity는 관리 employee 목록에
   나타나지 않는다.

배포된 frontend에는 history UI action이 없으므로, 첫 흐름의 history는 배포된 employee-service의
본인 전용 API contract로 확인했다. 임의 employee ID를 받는 history 경로는 사용하지 않았다.

## 선언·비밀 경계

- Jenkins JCasC는 Vault Agent가 제공하는 네 개의 string credential만 참조한다. password·TOTP
  원문은 Git·Jenkins parameter·build log에 넣지 않는다.
- 합성 Keycloak identity는 `/hr-users`, `/hr-admins` 각각 한 개와 전용 fixture만 수렴한다.
  기존 사람 identity·group은 변경하지 않는다.
- 합성 identity의 first/last name을 선언해 Keycloak `Update Account Information` 필수 action이
  E2E를 가로막지 않게 했다.
- immutable 검증에서 `platform-root`와 `jenkins`는 task SHA `d99e8a1f801a5d2a3f47586525316046aaee3416`
  로 `Synced/Healthy`였고, main 통합 뒤 두 Application을 literal `main`으로 복구한다.
