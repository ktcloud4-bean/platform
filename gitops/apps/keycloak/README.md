# Keycloak GitOps 기준선

이 디렉터리는 `KC-01`의 Keycloak server, 최초 bootstrap Job, ClusterIP Service와 표준
Ingress만 소유한다. realm·사용자 초기 입력은 Vault Agent init이 메모리에 렌더링하며 Git과
Kubernetes Secret에는 원문을 두지 않는다.

## 경계

- hostname·DNS 대상의 단일 원본은 [`docs/ip-plan.md`](../../../docs/ip-plan.md)다.
- PostgreSQL DB·role·TLS 기준선은
  [`docs/runbook/postgres-baseline.md`](../../../docs/runbook/postgres-baseline.md)가 소유한다.
- Vault 소비 선택은 [ADR-0013](../../../docs/adr/0013-keycloak-secret-consumption.md), 실제 적용과
  복구는 [Keycloak runbook](../../../docs/runbook/keycloak.md)을 따른다.
- 기존 packaged Traefik, 그 `HelmChartConfig`와 Pod는 수정하지 않는다. Ingress가 기존
  `websecure` entrypoint와 production DNS-01 resolver를 참조할 뿐이다.
- 관리 port 9000, NodePort, LoadBalancer, PVC와 Kubernetes Secret을 만들지 않는다.

## 동기화 순서

| wave | 리소스 | 성공 조건 |
|---|---|---|
| `-3` | Namespace | 전용 경계 생성 |
| `-2` | SA·ConfigMap·Service | 공개 설정·trust와 최소 identity 준비 |
| `-1` | `keycloak-bootstrap-v2` Job | realm·MFA·복구 ID 생성, 임시 admin client와 렌더링 파일 제거 |
| `0` | Deployment | Vault runtime 값으로 Ready |
| `1` | Ingress | 기존 Traefik을 통한 고정 issuer 제공 |

bootstrap Job은 기존 realm을 교정하는 controller가 아니다. import는 이미 존재하는 realm을
건너뛰므로 변경은 현재 Admin API 상태를 확인한 별도 작업이 소유한다. Job 이름을 바꿔
재실행하기 전에 DB와 임시 admin client 상태를 확인한다.

master realm 복구 ID는 public `kc-recovery` client의 Authorization Code + PKCE + TOTP만 쓴다.
password grant, implicit flow, client secret과 service account는 끈다. master `admin` role을
토큰에 싣는 `fullScopeAllowed=true`는 이 break-glass client 하나의 의도된 예외다.

## 공급망과 실행 권한

Keycloak과 Vault Agent image는 tag와 digest를 함께 고정한다. Keycloak version 근거는
[`release-metadata.env`](release-metadata.env)가 소유한다. 두 컨테이너 모두 non-root,
capability `ALL` drop, RuntimeDefault seccomp를 사용한다. 상시 Keycloak 컨테이너에는 projected
ServiceAccount token volume을 마운트하지 않는다.
