# ADR-0004: 통합인증과 관리 접근

- 상태: `Accepted`
- 날짜: 2026-07-30
- 관련 작업: `KC-01`, `POM-01`, `HEADLAMP-01`, `HEADLAMP-02`, `NB-02`, `WG-02`, `AWS-ID-01`

## 배경

웹 애플리케이션 접근, 애플리케이션 내부 권한, Kubernetes API 권한과 장애 복구 권한은 서로 다른 통제다. 하나의 SSO 경로에 모두 의존하면 IdP 장애가 IdP 자체의 복구까지 막는 순환 의존이 생긴다. 단일 Kubernetes 클러스터에는 멀티클러스터 관리 플랫폼보다 가벼운 관리 UI가 적합하다.

## 결정

Keycloak을 팀 사용자, MFA, OIDC/SAML과 AWS 임시 콘솔 권한의 중앙 IdP로 사용한다. 그룹은 소속, client role은 애플리케이션 권한을 나타내며 사용자 직접 권한 부여는 예외로 한다. 일상 계정과 특권 계정을 분리하고 공유 관리자 계정을 만들지 않는다.

Pomerium은 보호된 웹 Route와 Routes Portal의 접근을 결정한다. Headlamp는 k3s의 일상 관리 UI로 사용하되 Pomerium 인증만으로 Kubernetes 권한을 부여하지 않는다. Kubernetes API가 Keycloak OIDC 토큰을 검증하고 Kubernetes RBAC가 조회·로그·exec·변경 권한을 결정한다. Argo CD가 소유한 선언 리소스는 Git에서 변경한다.

NetBird와 Warpgate는 일반 사용자를 Keycloak에 연동하되 IdP 장애용 로컬 복구 계정을 유지한다. AWS 콘솔은 `AssumeRoleWithSAML`의 임시 세션만 사용하고 사용자 지속 액세스 키를 발급하지 않는다. OPNsense, Proxmox, Keycloak, Pomerium과 k3s에는 IdP에 의존하지 않는 break-glass 경로를 유지한다.

## 검토한 대안

- **Rancher를 단일 k3s 관리 UI로 사용:** 기능은 충분하지만 멀티클러스터 관리면, 추가 controller와 별도 RBAC가 현재 규모에 과하다.
- **Authentik으로 IdP와 포털을 통합:** 포털 장점은 있으나 현재 필요한 SAML·역할 분리와 Pomerium Portal 조합에서는 Keycloak 유지가 일관적이다.
- **Pomerium 로그인만으로 Headlamp 권한 부여:** 웹 진입과 Kubernetes API 인가가 섞이고 공용 특권 ServiceAccount 위험이 생긴다.
- **모든 관리 경로를 SSO로 강제:** IdP 장애 시 복구 순환 의존이 생긴다.

## 결과

- 사용자 생명주기와 MFA는 중앙화하면서 실제 리소스 권한은 각 계층 RBAC가 소유한다.
- Headlamp에는 공유 `cluster-admin` ServiceAccount를 두지 않는다.
- 로컬 복구 자격증명과 특권 계정 운영 부담이 남는다.
- 직접 UI 변경은 GitOps drift를 만들 수 있으므로 복구 상황으로 제한한다.

## 재검토 조건

- 독립 Kubernetes 클러스터가 여러 개가 되어 중앙 cluster lifecycle 관리가 필요하다.
- 운영자와 팀 역할이 늘어 별도 privileged access governance가 필요하다.
- 선택한 제품의 OIDC/SAML 또는 복구 계정 지원이 변경된다.
