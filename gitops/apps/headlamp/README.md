# Headlamp 사용자 OIDC·Kubernetes RBAC 경계

이 디렉터리는 `HEADLAMP-02`의 Headlamp `v0.44.0`, Keycloak OIDC 수신 설정과
사용자 group 기반 Kubernetes RBAC 선언을 소유한다. 원시 Kustomize만 사용하며,
공식 Helm chart가 만드는 `cluster-admin` binding은 사용하지 않는다.

## 인증과 인가 경계

```text
Browser -> Traefik -> Pomerium Route -> Headlamp OIDC -> Keycloak
        -> 사용자 ID token -> Headlamp Kubernetes proxy -> Kubernetes API -> RBAC
```

Pomerium은 `claim/groups`로 Headlamp **웹 Route 입장만** 허용한다. Pomerium cookie와
Pomerium client token은 Kubernetes API에 전달하거나 API 권한에 쓰지 않는다. Headlamp는
Keycloak `headlamp` public PKCE client의 ID token을 per-cluster HttpOnly cookie에서 읽어
Kubernetes proxy 요청의 Bearer token으로 쓴다.

`ServiceAccount/headlamp`에는 RoleBinding·ClusterRoleBinding이 없다.
`-unsafe-use-service-account-token`도 사용하지 않는다. Pod의 600초 projected token은
Headlamp가 in-cluster endpoint와 CA를 초기화하는 데만 필요하고, workload resource 권한은
부여하지 않는다. `kubernetes.io/service-account-token` Secret은 만들지 않는다.

## OIDC client 계약

`gitops/tools/headlamp-02/keycloak-client.json`은 비밀 없는 선언이다.

| 항목 | 고정값 |
|---|---|
| client | `headlamp`, public client, Authorization Code만, PKCE `S256` |
| callback | `https://headlamp.imcherry5778.xyz/oidc-callback` 정확히 한 건 |
| issuer | `https://sso.imcherry5778.xyz/realms/platform` |
| Headlamp 전달 token | ID token 기본값 (`-oidc-use-access-token` 미사용) |
| Kubernetes audience | `headlamp` (`--oidc-client-id=headlamp`) |
| username | `preferred_username` -> `oidc:<name>` |
| groups | 문자열 배열 `groups` -> `oidc:/<group>` |
| client secret | 없음; Kubernetes Secret·Vault KV·manifest·명령 인자에 저장하지 않음 |

`provision-keycloak-client.sh --check`은 기존 `headlamp` client가 없거나 정확히 이
비밀 제외 선언과 일치하는지만 판단한다. 기존 realm·group·user·client를 자동 보정하지
않는다.

## 승인된 최소 RBAC

| Keycloak group | Kubernetes group | 허용 | 거부 |
|---|---|---|---|
| `/platform-users` | `oidc:/platform-users` | namespace·node·Pod·Service·Event·workload·Job `get/list/watch`, `pods/log get` | exec, 모든 create/update/patch/delete, Secret·RBAC·TokenRequest·CSR·webhook·CRD·node write |
| `/platform-privileged` | `oidc:/platform-privileged` | 위 조회·로그 + `pods/exec create`; `headlamp-rbac-test` namespace의 ConfigMap `get/create/update/patch/delete` | 그 밖의 namespace 변경과 모든 특권 API |

`headlamp-rbac-test`는 권한 검증 전용 namespace다. 운영 resource, 특히 Argo가 소유한
resource는 위 API 권한이 있어도 Git 변경으로만 관리한다.

## GitOps와 bootstrap 폐기

정상 상태의 root/child Application은 `targetRevision: main`을 사용한다. merge 전 live
검증 중에만 `AGENTS.md`의 `ARGO-ROOT` 잠금을 잡고 mutable branch 대신 설정 commit SHA와
pointer commit SHA를 사용한다. 검증 종료 시 root/child를 `main`으로 복귀한다. final 선언에는
`headlamp-reader` ServiceAccount·ClusterRole·ClusterRoleBinding을 포함하지 않아 Argo가
정확한 bootstrap resource만 prune한다.

이 제거는 실제 Keycloak OIDC·Pomerium·Kubernetes RBAC 검증과 rollback 준비가 끝난
`HEADLAMP-02` live gate에서만 진행한다. merge 전 검증 실패 시 기록한 시작 main SHA로
root/child와 라이브 경계를 복구하고 같은 작업 브랜치에서 보정한다.

## 검증과 복구

- Keycloak client: `gitops/tools/headlamp-02/provision-keycloak-client.sh --check`
- OPNsense alias: `gitops/tools/headlamp-02/opnsense-alias.py --env-file <0600 env> check`
- 전체 절차·allow/deny·IdP 장애 drill·rollback: [HEADLAMP-02 runbook](../../../docs/runbook/headlamp-oidc-rbac.md)

Headlamp, Pomerium 또는 Keycloak 장애 때도 trusted SSH와 k3s 노드의 root-only
break-glass kubeconfig는 Pomerium·Headlamp·Keycloak과 독립되어 있다. k3s uninstall,
datastore reset/restore, kubeconfig 권한 완화, cluster-admin ServiceAccount 추가는
rollback이 아니다.
