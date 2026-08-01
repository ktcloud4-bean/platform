# ADR-0014: 애플리케이션 포털을 Dashy로 분리

- 상태: `Accepted`
- 날짜: 2026-08-01
- 관련 작업: `POM-01`, `HEADLAMP-02`
- 부분 대체: [ADR-0004](0004-zero-trust-identity-and-management-access.md)의 Pomerium Routes Portal 선택

## 배경

Keycloak은 신원·MFA·OIDC claim을 발급하지만 애플리케이션 탐색용 포털의 사용성이 제한적이다.
Pomerium Core는 웹 Route의 실제 접근 정책과 프록시에는 적합하지만, 내장 Routes Portal은
Route 중심 목록이며 원하는 대시보드 구성·그룹별 타일 표현을 주목적으로 하지 않는다.
포털 편의 때문에 신원 발급과 접근 인가의 책임을 한 제품에 다시 합치면 복구 경계가 흐려진다.

## 결정

`access` 진입점에서 Pomerium Core가 Keycloak `groups` claim을 `claim/groups` policy로
판정하고, 허용된 요청만 Dashy로 프록시한다. Dashy는 애플리케이션 카탈로그와 그룹별 타일
표시만 담당한다. Dashy도 Keycloak 공개 client의 Authorization Code + PKCE로 로그인하며
`showForGroups`에는 같은 full-path `groups` claim을 사용한다.

Dashy의 타일 숨김은 탐색 편의이지 보안 경계가 아니다. 각 타일 URL은 별도 Pomerium Route의
명시적 group policy를 다시 통과해야 하며, 후속 서비스는 자체 RBAC도 유지한다. Dashy 설정은
인증 사용자에게 전달될 수 있으므로 비밀·복구 URL·권한을 숨김 타일 안에 넣지 않는다.

## 검토한 대안

- **Pomerium 내장 Routes Portal:** 추가 workload가 없지만 포털 구성과 표현의 자유도가 현재
  요구에 맞지 않는다. Pomerium은 접근 정책 역할에 집중한다.
- **Keycloak 애플리케이션 목록:** IdP 관리면과 사용자 탐색면이 섞이고 사용자가 겪은 포털
  불편을 해결하지 못한다.
- **Homarr:** 풍부한 홈랩 통합이 장점이지만 POM-01은 정적 카탈로그와 groups claim 표시만
  필요해 더 작은 Dashy 구성이 적합하다.
- **Pomerium 없이 Dashy만 사용:** 타일 숨김은 실제 Route 인가가 아니므로 채택하지 않는다.

## 결과

- Keycloak, Pomerium, Dashy의 책임이 각각 신원, Route 인가, 탐색 UI로 분리된다.
- Dashy용 공개 PKCE client와 상시 Pod 하나가 추가되지만 client secret·PVC는 추가되지 않는다.
- Dashy 장애는 포털 탐색에 영향을 주지만 Pomerium의 직접 Route와 break-glass 관리 경로는
  독립적으로 유지된다.
- 그룹 이름 또는 타일을 바꿀 때 Pomerium policy와 Dashy 표시 조건의 정합성을 함께 검증한다.

## 재검토 조건

- Dashy의 OIDC/groups 지원 또는 유지보수가 중단된다.
- 애플리케이션 수가 늘어 사용자별 동적 카탈로그 API나 감사 가능한 포털 관리가 필요해진다.
- Pomerium 내장 Portal이 필요한 대시보드 기능을 제공해 추가 workload의 이점이 사라진다.
