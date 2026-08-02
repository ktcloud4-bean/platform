# Pomerium Core·Dashy Portal GitOps 기준선

이 디렉터리는 `POM-01`의 Pomerium Core all-in-one Pod, 선언형 Route, Dashy 애플리케이션
포털과 표준 Kubernetes Ingress를 소유한다. Pomerium Enterprise·Zero control plane,
Pomerium Ingress Controller CRD, Kubernetes Secret과 PVC는 만들지 않는다.

## 요청 경로와 Traefik 경계

```text
Client
  -> Traefik websecure (TLS와 hostname route)
  -> Service/pomerium:80
  -> Pomerium Core :8080 (insecure_server, Pod network 안에서만 사용)
       ├─ /pom01-platform-user-check -> 선언형 direct response
       └─ /                           -> Service/dashy:8080
       └─ headlamp.imcherry5778.xyz -> Service/headlamp:80
       └─ sonar.imcherry5778.xyz    -> Service/sonarqube:9000
       └─ harbor.imcherry5778.xyz / -> Service/harbor:80
```

기존 packaged Traefik이 유일한 ingress controller다. 이 앱은 동적 `Ingress` 객체만
추가하며 `HelmChartConfig`, 정적 entrypoint/plugin과 Traefik Pod를 수정하거나 재기동하지
않는다. HTTP→HTTPS는 기존 전역 `web`→`websecure` 영구 redirect를 그대로 사용하고,
`access.imcherry5778.xyz` 인증서는 기존 production DNS-01 resolver가 발급한다. 공개
A/AAAA, NAT와 Cloudflare proxy는 `EDGE-01` 전까지 만들지 않는다.

Pomerium 공식 경계상 `authenticate_service_url`은 보호 Route URL과 달라야 한다. 이 작업이
승인받아 추가할 Unbound alias는 `access` 하나뿐이므로 다음처럼 분리한다.

| 이름 | 역할 | DNS 변경 |
|---|---|---|
| `access.imcherry5778.xyz` | Pomerium 보호 Dashy Portal과 검증 Route | POM-01 승인 뒤 내부 alias 1건 |
| `k3s-01.imcherry5778.xyz` | Pomerium self-hosted authenticate/OIDC callback | 기존 canonical A와 인증서 재사용 |
| `sso.imcherry5778.xyz` | Keycloak `platform` realm issuer | KC-01 상태 불변 |

`k3s-01` 이름의 Pomerium endpoint는 OIDC callback과 Pomerium authenticate handler만
소유한다. k3s API·SSH·관리 kubeconfig를 Pomerium으로 프록시하지 않는다.

## 권한 모델과 후속 Route 계약

Pomerium Core에서는 Enterprise Directory Sync용 `groups` criterion을 쓰지 않고 Keycloak
OIDC claim을 직접 확인하는 `claim/groups`를 쓴다.

| 경로 | Pomerium 허용 claim | Dashy 표시 |
|---|---|---|
| `/pom01-platform-user-check` | `/platform-users` | 같은 그룹에만 타일 표시 |
| `/` Dashy Portal | `/platform-users` 또는 `/platform-privileged` | 로그인한 그룹별 타일 선별 |
| `https://headlamp.imcherry5778.xyz` | `/platform-users` 또는 `/platform-privileged` | 두 group에 Headlamp 타일 표시 |
| `https://git.imcherry5778.xyz` | `/platform-users` | 같은 그룹에만 Gitea 타일 표시 |
| `https://sonar.imcherry5778.xyz` | `/platform-users` | 같은 group에만 SonarQube 타일 표시 |
| `https://harbor.imcherry5778.xyz` UI | `/platform-users` 또는 `/platform-privileged` | 두 group에 Harbor 타일 표시 |

로그인 성공, email 또는 `authenticated_user`만으로 허용하는 fallback은 없다.
`/platform-privileged`만 가진 사용자는 Portal에는 들어가지만 검증 Route는 403이고 해당 타일도
보이지 않는다. Dashy `showForGroups`는 탐색 편의일 뿐 보안 통제가 아니므로 각 후속 타일 URL은
별도 Pomerium Route policy를 가져야 한다.

`HEADLAMP-02` Route는 두 group 모두 웹 진입을 허용하지만, Pomerium은 웹 진입만 판정하며
upstream의 실제 권한을 대신하지 않는다. Headlamp는 사용자별 Keycloak OIDC ID token과
Kubernetes RBAC가 API 권한을 계속 소유하고 Pomerium의 token/header를 Kubernetes API token으로
전달하지 않는다. 이 Route만 `allow_websockets: true`로 Kubernetes exec upgrade를 전달하고,
실제 exec 허용 여부는 계속 Kubernetes RBAC가 판정한다. 공유 `cluster-admin` ServiceAccount는
만들지 않는다.

`SCM-01` Gitea UI Route의 upstream은 `gitea` namespace의 server Pod TCP 3000만 허용하는
전용 egress NetworkPolicy를 함께 둔다. POL-01의 Pomerium 기본 거부를 우회하는 광역 namespace나
port 허용은 추가하지 않는다.

`QUALITY-01` SonarQube Route는 browser UI만 소유하고 `/platform-users` 한 group에만
허용한다. scanner/Web API는 대화형 Pomerium OIDC와 맞지 않으므로 이 Route를 우회하는
외부 예외를 만들지 않고 cluster 내부 Service와 project-scoped Sonar token을 사용한다.
upstream은 `sonarqube` namespace의 server Pod TCP 9000만 허용하는 전용 egress
NetworkPolicy로 제한한다.
세부 경계는 [`gitops/apps/sonarqube/README.md`](../sonarqube/README.md)가 소유한다.

`REG-01`의 Harbor route는 browser UI `/`만 보호한다. 더 구체적인 `/v2/`와 `/service/`
Ingress는 Harbor 자체 OCI 인증을 위해 Pomerium을 우회하며, 상세 경계는
[`gitops/apps/harbor/README.md`](../harbor/README.md)가 소유한다.
POL-01의 Pomerium default-deny 아래에서는 Harbor nginx Pod TCP 8080 한 egress만 허용한다.

## Keycloak clients와 시크릿

[`keycloak-client.json`](../../tools/pom-01/keycloak-client.json)은 Pomerium confidential client,
[`dashy-keycloak-client.json`](../../tools/pom-01/dashy-keycloak-client.json)은 Dashy 공개 PKCE
client의 비밀 제외 선언이다.

- 둘 다 Authorization Code 표준 flow만 켜고 implicit, direct grant, service account와
  authorization service는 끈다.
- 둘 다 `fullScopeAllowed=false`이며 client 자체 `groups` mapper를 ID/access/userinfo token에
  full path로 싣는다.
- Pomerium redirect URI는 callback 하나이며 confidential secret을 Vault에서만 소비한다.
- Dashy는 공개 client, PKCE `S256`, `access` origin만 허용하며 client secret이 없다.
- 기존 realm/client/group/user를 자동 교정하지 않는다. 라이브 차이가 있으면 적용을 중단한다.

Pomerium client secret, shared/cookie secret과 signing private key는 저장소 밖 mode `0600`
파일에서 `kv/pomerium/runtime`으로만 쓴다. Pod 안의 명시적 Vault Agent init container가
projected ServiceAccount token으로 `pomerium` role에 로그인하고 메모리 `emptyDir`에 렌더링한
뒤 종료한다. projected token과 Vault role은 `audience=vault`로 서로 고정한다. 상시 Pomerium
container에는 ServiceAccount token이 없다. cluster-wide injector,
privileged CSI DaemonSet, Secret 동기화 operator는 추가하지 않는다.

적용 전에는 반드시 차이를 먼저 분류한다.

```bash
export POM01_SECRET_DIR=/home/imcherry/secrets/ktcloud4-bean/pomerium
export KC01_SECRET_DIR=/home/imcherry/secrets/ktcloud4-bean/keycloak
export VAULT_ROOT_TOKEN_FILE=/home/imcherry/secrets/ktcloud4-bean/vault-root.token
gitops/tools/pom-01/provision.sh --check
gitops/tools/pom-01/provision.sh --apply
```

## 동기화 순서와 실행 경계

| wave | 리소스 | 성공 조건 |
|---|---|---|
| `-3` | Namespace | 전용 namespace 생성 |
| `-2` | ServiceAccount·공개 ConfigMap·Vault trust | 비밀 없는 선언과 최소 identity 준비 |
| `-1` | ClusterIP Services | Pomerium과 Dashy 내부 HTTP만 노출 |
| `0` | Pomerium·Dashy Deployments | Vault init과 두 workload health Ready |
| `1` | Ingress | 기존 Traefik과 production resolver만 사용 |

Pomerium all-in-one Databroker는 메모리 저장소이며 replica는 하나다. Pod 재생성은 세션을 지워
재인증을 요구하지만 구성과 권한은 Git/Vault/Keycloak에서 재구축된다. Dashy도 설정 ConfigMap과
무상태 `emptyDir`만 사용한다. PVC가 없으므로 이 배포는 HA나 세션 지속성을 주장하지 않는다.

Pomerium Core `v0.33.0`과 Dashy `4.5.0`의 공식 image tag, multi-arch index digest, 현재 node의
amd64 manifest digest, tag commit, license 출처와 hash는
[`release-metadata.env`](release-metadata.env)가 소유한다. 두 main container와 Vault Agent는
non-root, capability `ALL` drop, RuntimeDefault seccomp를 사용하며 root filesystem은 read-only다.

상세 적용·검증·rollback과 독립 복구는
[Pomerium·Dashy runbook](../../../docs/runbook/pomerium-routes.md)이 소유한다.
