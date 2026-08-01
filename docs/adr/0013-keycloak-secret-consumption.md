# ADR-0013: Keycloak 시크릿 소비 경계

- 상태: `Accepted`
- 날짜: 2026-08-01
- 관련 작업: `VAULT-02`, `KC-01`

## 배경

VAULT-02는 Kubernetes auth와 앱별 policy를 만들었지만 앱이 Vault 값을 받아가는 구현은
결정하지 않았다. Keycloak은 기동 때 PostgreSQL 암호가 필요하고 최초 realm import에는
사용자 암호·TOTP seed·검증 client secret이 필요하다. 이 값을 Git, Kubernetes Secret,
컨테이너 로그에 남기지 않으면서 단일 k3s 노드의 운영 복잡도를 제한해야 한다.

## 결정

Keycloak Pod 안의 명시적 Vault Agent **init container**가 projected ServiceAccount token으로
Kubernetes auth를 수행하고, 필요한 값만 메모리 `emptyDir`에 렌더링한 뒤 종료한다. injector
webhook은 설치하지 않는다. 상시 Keycloak 컨테이너에는 ServiceAccount token을 마운트하지
않고 런타임 DB 암호 파일만 읽힌다. 최초 bootstrap Job은 추가 값을 사용해 realm과 개인별
복구 관리자를 만든 뒤 임시 관리 client와 렌더링 파일을 제거한다.

PostgreSQL은 PG-01의 고정 `keycloak_user`를 유지하고 암호를 Vault KV v2에 저장한다.
회전은 Vault 값과 role 암호를 함께 갱신한 뒤 Keycloak Pod를 재생성하는 승인 작업이다.
Keycloak의 장기 connection pool에 만료되는 동적 계정을 바로 주입하지 않는다.

## 검토한 대안

- **Vault Agent Injector:** 공식 webhook이 annotation으로 sidecar/init 주입을 자동화하지만,
  현재 소비 앱 하나를 위해 cluster-wide mutating webhook과 controller를 추가한다. 앱 수가
  늘거나 지속 렌더링·자동 회전 수요가 생기면 재검토한다.
- **Vault CSI Provider:** sidecar 자원은 줄지만 노드마다 privileged DaemonSet과 hostPath가
  필요하고 템플릿 변환이 없다. 단일 앱의 기동 시점 값에는 권한면이 더 크다.
- **Vault Secrets Operator:** 앱 사용은 단순하지만 기본 경로가 Kubernetes Secret 동기화라
  원문이 etcd와 Kubernetes API에 남는다. 이 작업의 Secret 0건 경계와 맞지 않는다.
- **Vault Database 동적 자격증명:** 짧은 TTL과 자동 폐기 장점이 있으나 Keycloak connection
  pool이 바뀐 사용자·암호를 무중단으로 다시 읽는 검증 경로가 없다. lease 만료 전 이중
  계정 전환과 다중 replica 회전 절차가 검증되면 재검토한다.

## 결과

- Git과 Kubernetes Secret은 원문 값을 소유하지 않고, Pod 파일은 메모리에만 존재한다.
- 새 Pod 기동은 Vault가 unsealed이고 Kubernetes auth가 정상이어야 한다. 이미 기동한
  Keycloak은 Vault가 일시 중단돼도 현재 DB 연결을 계속 쓸 수 있지만 재기동은 실패한다.
- init Agent가 종료되므로 상시 sidecar 자원과 갱신 실패 상태가 없다. 대신 모든 회전은
  승인된 Pod rollout과 양성·음성 회귀 검증을 요구한다.
- 같은 ServiceAccount가 bootstrap과 runtime policy를 사용하지만 상시 컨테이너에는 token이
  없어 bootstrap 경로를 다시 읽을 수 없다.

## 재검토 조건

- Vault 소비 앱이 3개 이상이거나 공통 주입 정책의 편익이 webhook 운영 비용을 넘는다.
- Keycloak 다중 replica와 무중단 DB 자격증명 회전 절차가 도입된다.
- CSI provider가 privileged·hostPath 없이 현재 보안 경계를 충족한다.
- Kubernetes Secret의 별도 암호화·접근 통제가 원문 비저장 요구를 대체하기로 결정된다.

## 근거

- HashiCorp의 [Kubernetes 방식 비교](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/comparisons)는
  Agent의 메모리 렌더링·템플릿, CSI의 privileged DaemonSet/hostPath와 템플릿 부재,
  Operator의 Kubernetes Secret 동기화 차이를 설명한다.
- HashiCorp의 [Agent Injector와 CSI 비교](https://developer.hashicorp.com/vault/docs/deploy/kubernetes/injector-csi)는
  Agent가 sidecar 자원을 쓰는 대신 privileged Pod가 필요 없다는 경계를 명시한다.
- Keycloak의 [Database 설정](https://www.keycloak.org/server/db)은 `verify-server`가 서버 인증서와
  신원을 검증하며 trust store가 필요함을 정의한다.
- Keycloak의 [bootstrap admin 복구](https://www.keycloak.org/server/bootstrap-admin-recovery)는
  모든 node가 중지된 offline bootstrap과 임시 계정 제거 경계를 설명한다.
