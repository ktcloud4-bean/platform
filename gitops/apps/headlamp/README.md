# Headlamp 내부 bootstrap 기준선

이 디렉터리는 `HEADLAMP-01`의 Headlamp 서버와 임시 reader identity만 소유한다.
OIDC·Keycloak·Pomerium·Ingress는 `HEADLAMP-02` 범위이며 여기에는 선언하지 않는다.

## 배포 경계

| 대상 | 관계와 권한 |
|---|---|
| `Service/headlamp` | `ClusterIP:80`만 사용한다. Ingress·NodePort·LoadBalancer는 없다. |
| `ServiceAccount/headlamp` | 서버 Pod identity다. RoleBinding·ClusterRoleBinding을 연결하지 않는다. |
| 서버 Pod의 API token | 자동 mount를 끄고 `expirationSeconds: 600`인 projected token만 명시적으로 mount한다. Kubernetes Secret이 아니다. |
| `ServiceAccount/headlamp-reader` | TokenRequest 대상이다. 자동 mount와 장기 token Secret은 없다. |
| `ClusterRole/headlamp-reader` | namespace·node·Pod·Service·Event·기본 workload·Job의 `get/list/watch`와 `pods/log get`만 허용한다. Secret·ConfigMap·RBAC·스토리지·CRD는 제외한다. |
| `ClusterRoleBinding/headlamp-reader` | 위 reader role을 `headlamp/headlamp-reader` 하나에만 연결한다. |

Headlamp `v0.44.0`의 공식 image와 digest는
[`release-metadata.env`](release-metadata.env)가 소유한다. 공식 Helm chart는 기본값으로
`cluster-admin` ClusterRoleBinding을 생성하므로 사용하지 않고, 이 디렉터리의 원시
manifest(Kustomize)를 적용한다. `-enable-helm`과
`-unsafe-use-service-account-token`도 사용하지 않는다.

## 승인 gate

다음을 모두 보고하고 승인받기 전에는 commit·push, `platform-root` revision 전환,
Argo sync와 TokenRequest를 실행하지 않는다.

1. `GITOPS-01 DONE`, `HEADLAMP-01 READY`, 잠금 충돌 없음과 최신 main을 재확인한다.
2. Node `Ready`, Argo `platform-root` `Synced/Healthy`, 기존 `headlamp` namespace 부재를 확인한다.
3. 이 디렉터리와 `gitops/root/headlamp-*.yaml`의 전체 render를 제시한다.
4. reader token TTL 600초, loopback 전용 port-forward, allow/deny 항목과 rollback을 제시한다.

## immutable GitOps 검증

라이브 검증 동안 mutable branch 이름을 child Application에 넣지 않는다.

1. manifest 설정 commit을 만들고 push한다.
2. 다음 signed pointer commit에서 `headlamp` Application의 `targetRevision`을 설정 commit SHA로 바꾼다.
3. `platform-root`도 pointer commit SHA를 읽게 전환한다.
4. `platform-root`와 `headlamp`가 각각 pointer/settings SHA에서 `Synced/Healthy`인지 확인한다.
5. 검증 후 최종 선언의 child `targetRevision`을 `main`으로 되돌려 squash merge한다.
6. `platform-root`를 최신 main SHA로 전환하고 재동기화 뒤 같은 리소스·권한 경계를 다시 확인한다.

## 관리자 로컬 접근

관리자 PC와 k3s VM 양쪽에서 loopback만 bind한다. 관리자 kubeconfig는 VM 밖으로 복사하지
않는다.

```bash
ssh -tt -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:8446:127.0.0.1:18446 \
  rocky@k3s-01.imcherry5778.xyz \
  'sudo -n /usr/local/bin/k3s kubectl -n headlamp port-forward \
    --address=127.0.0.1 service/headlamp 18446:80'
```

브라우저는 `http://127.0.0.1:8446`만 연다. 외부 DNS·NAT·Ingress를 만들지 않는다.
`-tt`는 `Ctrl-C`와 터미널 종료를 원격 `kubectl`까지 전달해 k3s 노드의
`127.0.0.1:18446` listener가 남지 않게 한다.

## 단기 reader token 검증

[`verify-reader-access.sh`](../../tools/headlamp-01/verify-reader-access.sh)는 TokenRequest
출력을 mode `0600` 임시 파일로만 받고, token 원문을 stdout·stderr·shell 인자에 넣지
않는다. token과 Authorization header 파일은 종료 trap에서 지운다. 검증 전 원격
loopback port가 비어 있는지 확인하고, 종료 trap에서 이 검증이 시작한 원격
`kubectl port-forward`도 종료한 뒤 listener 0건을 확인한다.

```bash
K3S_SSH_TARGET=rocky@k3s-01.imcherry5778.xyz \
K3S_SSH_KNOWN_HOSTS="$HOME/.ssh/known_hosts" \
./gitops/tools/headlamp-01/verify-reader-access.sh
```

검증 항목은 다음과 같다.

| 판정 | Headlamp proxy 요청 |
|---|---|
| 허용 | namespace 목록, `headlamp` Pod 목록, Headlamp Pod log 조회 |
| 거부 | Secret 조회, ConfigMap create, reader의 추가 TokenRequest, Service update/delete, Pod exec |

create/update/delete 요청에는 `dryRun=All`을 붙인다. 권한이 잘못 열려도 검증 객체나 변경이
남지 않는다. exec는 허용됐을 때도 `true`만 실행하도록 제한하지만 기대 결과는 HTTP 403이다.
검증 뒤 `kubernetes.io/service-account-token` Secret 0개와 런타임 `headlamp` SA의
리소스 조회·변경 권한 부재를 다시 확인한다.

## rollback

merge 전 실패하면 `platform-root`의 `targetRevision`을 시작 시 기록한 main SHA로 되돌린다.
root prune이 child `Application/headlamp`를 지우면 finalizer가 이 작업의 namespace,
ClusterRole, ClusterRoleBinding을 제거한다. 다른 Application·namespace·k3s 구성은 대상이
아니다.

merge 뒤 rollback은 main에 직접 고쳐 쓰지 않고 전용 revert branch에서 HEADLAMP-01 squash
commit 하나를 `git revert`한다. 그 revert를 main에 반영하면 Argo prune으로 같은 리소스만
제거되는지 확인한다.

```bash
git switch -c revert/headlamp-01 origin/main
git revert <HEADLAMP-01-squash-commit>
```

긴급 복구에서도 `cluster-admin` ServiceAccount/ClusterRoleBinding 추가, k3s uninstall,
OPNsense·Proxmox·Ingress 변경은 rollback이 아니다.
