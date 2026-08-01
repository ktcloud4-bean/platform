# Headlamp Keycloak OIDC·Kubernetes RBAC 전환 runbook

- 작업: `HEADLAMP-02`
- 대상 URL: `https://headlamp.imcherry5778.xyz`
- Keycloak issuer: `https://sso.imcherry5778.xyz/realms/platform`
- k3s API OIDC audience: `headlamp`
- 독립 복구: trusted SSH host key + k3s 노드 root-only break-glass kubeconfig

이 runbook의 명령은 live 검증 절차다. `HEADLAMP-02` 완료 전의 예상값이나 계획을
검증 완료 사실로 바꾸지 않는다. token, cookie, kubeconfig, Keycloak/Vault/OPNsense 원문은
Git·shell 인자·stdout/stderr·Pod log에 두지 않는다.

## 고정 구현 근거

Headlamp `v0.44.0`의 고정 source와 [공식 in-cluster OIDC 문서](https://headlamp.dev/docs/latest/installation/in-cluster/oidc/)를 대조했다. 이 버전은 기본적으로 ID token을 Kubernetes proxy에 전달하며, `-oidc-use-access-token`은 사용하지 않는다. `-oidc-use-pkce=true`는 Authorization Code PKCE를 강제하고, `-unsafe-use-service-account-token`을 쓰지 않으면 runtime ServiceAccount token을 workload API 권한에 사용하지 않는다. Kubernetes API의 issuer·audience·claim/prefix 계약은 [공식 OIDC 인증 문서](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#openid-connect-tokens)를 따른다.

## 책임 경계

```text
Browser -> Traefik -> Pomerium Route -> Headlamp OIDC -> Keycloak
        -> 사용자 ID token -> Headlamp proxy -> Kubernetes API -> RBAC
```

| 계층 | 책임 | 하지 않는 일 |
|---|---|---|
| Pomerium | `/platform-users` 또는 `/platform-privileged` groups claim으로 Headlamp 웹 Route만 허용 | Kubernetes API token 발급·전달·인가 |
| Headlamp·Keycloak | public client Authorization Code + PKCE(S256), 정확한 callback, ID token 획득 | 공유 ServiceAccount 권한 사용 |
| Kubernetes API | issuer·`aud=headlamp`·`preferred_username`·문자열 배열 groups 검증과 `oidc:` prefix 적용 | Pomerium cookie 신뢰 |
| Kubernetes RBAC | 실제 리소스·log·exec·변경 allow/deny | Argo 소유 resource 직접 운영 변경 |
| break-glass kubeconfig | IdP/Pomerium/Headlamp 장애 중 API 상태 조회·복구 | 브라우저 OIDC 대체 일상 경로 |

## 승인된 identity → RBAC

검증기는 raw JWT 대신 아래 safe claim 판정만 출력한다. TTL은 `iat`, `exp`, 현재시각으로
계산한 초수만 출력하며 token 원문은 임시 메모리 밖에 쓰지 않는다.

| Keycloak 사용자·group | Pomerium Route | safe claim 판정 | Kubernetes username/groups | 조회·log | exec | 변경 | 특권 API |
|---|---|---|---|---|---|---|---|
| `imcherry`, `/platform-users` | allow | 정확한 issuer, `aud`에 `headlamp`, username=`imcherry`, groups 문자열 배열, TTL 양수 | `oidc:imcherry`, `oidc:/platform-users` | namespace·node·Pod·Service·Event·workload·Job 조회와 `pods/log` allow | deny | 모든 namespace에서 deny | Secret·RBAC·TokenRequest·CSR 승인·webhook·CRD·node write deny |
| `imcherry-admin`, `/platform-privileged` | allow | 위와 동일, username=`imcherry-admin`, 특권 group 포함 | `oidc:imcherry-admin`, `oidc:/platform-privileged` | 위와 동일 | `pods/exec create` allow; `node -e process.exit(0)`만 사용 | `headlamp-rbac-test`의 ConfigMap만 create/update/patch/delete allow | 위와 동일 deny |
| 무인증·잘못된 issuer/audience | deny | token 원문 미출력, 불일치 이유만 출력 | 해당 없음 또는 RBAC binding 없음 | deny | deny | deny | deny |
| `headlamp-no-group` task 전용 platform realm identity | Pomerium Route 403 | `kc-verify`의 안전한 판정으로 groups 문자열 배열이 비었음을 확인한 뒤 Pomerium policy 판정 | Headlamp에 도달하지 않음 | deny | deny | deny | deny |

특권 사용자의 허용 변경은 verifier가 생성한 `headlamp-02-verify-*` ConfigMap 하나뿐이다.
성공·실패·INT·TERM 모두 cleanup으로 삭제를 시도하고 잔류 0건을 확인한다. Argo가 소유한
resource의 변경은 user가 API 권한을 가져도 Git으로만 한다.

## 적용 전 중단 조건

다음 중 하나라도 다르면 변경하지 않고 차이·영향·복구 가능 여부를 기록한다.

1. `HEADLAMP-02=READY`, `HEADLAMP-01`·`POM-01`·`WG-02=DONE`, `K3S-BOOTSTRAP` 실제 점유 없음.
2. `origin/main`과 전용 branch/worktree 상태가 깨끗하고, 다른 platform-root/main 통합이 진행 중이지 않음.
3. k3s `active`, `/readyz=ok`, Node `Ready=True`, `DiskPressure=False`; capacity stop 기준 통과.
4. Vault `initialized=true`, `sealed=false`; Argo root·headlamp·pomerium·keycloak·vault와 기존 앱이 `main`, `Synced/Healthy`.
5. trusted SSH와 root-only `/etc/rancher/k3s/k3s.yaml`을 사용한 `/readyz`·Node 조회가 실제 성공.
6. `headlamp` Keycloak client와 Unbound headlamp alias가 없거나 이 선언과 정확히 일치. 기존 객체가 다르면 자동 보정하지 않음.
7. `provision-no-group-user.sh --check`이 task 전용 `headlamp-no-group` identity의 enabled·no-group·password+TOTP 계약과 저장소 밖 0600 입력을 확인함. 이 도구는 task 전용 user 외 기존 realm user·group을 변경하지 않는다.
7. 내부/공개 `headlamp.imcherry5778.xyz` A/AAAA가 모두 없거나, 승인 뒤 기대한 내부 A 하나·나머지 0건.

```bash
export KC01_SECRET_DIR=/home/imcherry/secrets/ktcloud4-bean/keycloak
export K3S_SSH_KNOWN_HOSTS=/home/imcherry/.ssh/known_hosts
export OPN_ENV=/home/imcherry/secrets/ktcloud4-bean/opnsense/env
# 기본 입력: ${KC01_SECRET_DIR}/headlamp-no-group-password 및 -totp (mode 0600)

gitops/tools/headlamp-02/provision-keycloak-client.sh --check
gitops/tools/headlamp-02/provision-no-group-user.sh --check
gitops/tools/headlamp-02/opnsense-alias.py --env-file "$OPN_ENV" check
infra/opnsense/scripts/check-drift.sh --env-file "$OPN_ENV"
gitops/tools/headlamp-02/check-break-glass.sh
gitops/tools/headlamp-02/check-capacity.sh
```

## k3s OIDC 선언과 rollback

`/etc/rancher/k3s/config.yaml`은 수동 편집하지 않는다. Ansible role이 아래 값만
`kube-apiserver-arg`로 렌더링한다.

```text
oidc-issuer-url=https://sso.imcherry5778.xyz/realms/platform
oidc-client-id=headlamp
oidc-username-claim=preferred_username
oidc-username-prefix=oidc:
oidc-groups-claim=groups
oidc-groups-prefix=oidc:
```

config 변경은 role의 기존 조건에 따라 k3s service 재시작 한 번을 유발한다. 제어면 API는
role의 180초 ready 대기 안에서 일시 중단될 수 있고, 기존 Pod workload는 재기동 대상이 아니다.
시작 전 config SHA-256과 이전 Ansible 선언을 기록한다.

```bash
cd infra/ansible
ansible-playbook -i <저장소-밖-0600-inventory> playbooks/k3s-baseline.yml --syntax-check
ansible-playbook -i <저장소-밖-0600-inventory> playbooks/k3s-baseline.yml --check --diff
```

실패 rollback은 시작 시 기록한 이전 Ansible 선언으로 되돌리고 k3s를 한 번 재시작한 뒤
`/readyz`, Node, CoreDNS, Traefik, ServiceLB, storage, Argo, Vault, Keycloak, Pomerium,
Headlamp와 기존 앱을 재검증하는 것뿐이다. uninstall, datastore reset/restore와 kubeconfig
권한 완화는 rollback이 아니다.

## Keycloak·GitOps·DNS 적용 순서

1. `provision-keycloak-client.sh --check`으로 `headlamp` public PKCE client의 차이를 분류한다.
2. client가 없을 때만 `--apply`로 추가하고 같은 `--check`를 재실행한다. client secret·Vault role·KV·Kubernetes Secret은 만들지 않는다.
3. k3s Ansible 적용과 `/readyz`·Node 회복을 확인한다.
4. main을 읽는 Argo root/child가 Headlamp RBAC·Pomerium Route·Dashy tile을 동기화하도록 하고, root/child revision은 계속 `main`으로 유지한다.
5. **별도 `OPNSENSE-LIVE` 승인 뒤에만** `headlamp` alias 한 건을 지원 API로 추가하고 Unbound만 reconfigure한다.
6. 내부 A=`10.10.20.10`, 내부 AAAA=0, public A/AAAA=0, TLS·OIDC·RBAC를 검증한다.
7. OIDC 전체 증거 뒤 정확한 `headlamp-reader` bootstrap resource의 prune, 장기 SA token Secret 0, runtime SA 권한 0, 임시 파일·listener 0을 확인한다.

OPNsense alias 대상은 기존 `k3s-01` host override의 live UUID에 연결되는
`headlamp.imcherry5778.xyz` 한 건이다. PF, NAT, Cloudflare, public DNS, Dnsmasq와 다른
Unbound row는 대상이 아니다.

```bash
gitops/tools/headlamp-02/opnsense-alias.py --env-file "$OPN_ENV" apply
dig +short @10.10.20.1 headlamp.imcherry5778.xyz A
dig +short @10.10.20.1 headlamp.imcherry5778.xyz AAAA
dig +short @1.1.1.1 headlamp.imcherry5778.xyz A
dig +short @1.1.1.1 headlamp.imcherry5778.xyz AAAA
infra/opnsense/scripts/check-drift.sh --env-file "$OPN_ENV" --update
infra/opnsense/scripts/check-drift.sh --env-file "$OPN_ENV"
```

DNS rollback은 exact `HEADLAMP-02` description·host UUID가 일치하는 headlamp alias만
`opnsense-alias.py ... rollback`으로 제거하고 reconfigure·drift 검증한다.

## 필수 live 검증

`verify-live.sh`는 Playwright의 실제 browser flow로 Pomerium→Headlamp→Keycloak callback과
Headlamp proxy API를 확인한다. HTTP-only OIDC cookie와 JWT는 process memory 외에 저장하지
않고, remote API exec도 SSH stdin의 mode 0600 임시 header만 사용한 뒤 trap에서 지운다.

```bash
export KC01_CONNECT_IP=10.10.20.10
export K3S_HOST=rocky@k3s-01.imcherry5778.xyz
export K3S_SSH_KNOWN_HOSTS=/home/imcherry/.ssh/known_hosts
gitops/tools/headlamp-02/verify-live.sh
```

같은 실행은 다음을 판정한다.

- HTTPS exact hostname 성공, 잘못된 hostname TLS 실패, HTTP→HTTPS 301
- Pomerium group allow와 무인증 Route redirect/deny, callback이 정확한 HTTPS URL
- Keycloak MFA 누락 거부, Authorization Code + PKCE 정상 login, issuer/aud/username/groups/TTL safe 판정
- Headlamp proxy를 통한 namespace·Pod·log allow, Secret·RBAC·TokenRequest·CSR·webhook·CRD·node write deny
- daily exec deny, privileged `node -e process.exit(0)` exec allow
- privileged ConfigMap create/update/patch/delete와 daily 변경 deny; test object 잔류 0
- API가 보고한 `oidc:<username>`·`oidc:/...` group과 runtime `headlamp` SA 권한 0
- Headlamp session 실제 만료 후 재인증, 잘못된 audience API deny, task 전용 무group identity의 Pomerium Route 403
- Git 추적 파일·Headlamp/Pomerium Pod log의 secret/JWT/token 원문 0

## Pod 재생성 및 IdP 장애 drill

Headlamp/Pomerium Pod 삭제는 Vault unsealed와 exact Pod UID를 먼저 확인한 뒤 별도 승인으로만
진행한다. Vault가 sealed면 Pod를 건드리지 않고 사용자에게 unseal을 요청한다. Pod마다 UID
변경·Ready·health 뒤 전체 `verify-live.sh`를 반복한다. Traefik과 Keycloak Pod는 이 drill의
삭제 대상이 아니다.

`check-break-glass.sh`는 Pomerium·Headlamp·Keycloak을 경유하지 않고 trusted SSH host key,
root:root mode 0600 `/etc/rancher/k3s/k3s.yaml`, `/readyz`, Node, Headlamp/Pomerium Deployment
Ready를 점검한다. IdP outage 전·중·후에 같은 명령을 실행해 browser 경로와 독립된 복구 경계를
기록한다.

`check-capacity.sh`는 Proxmox host의 RAM available·swap·15분 load·root·thin data/metadata와
k3s guest root·PVC 요청량을 `capacity-plan.md`의 정지 기준(8 GiB, swap 0, load 30, 80%,
70%, 120 GiB)에 대조한다. 어느 하나라도 정지 구간이면 HEADLAMP-02 live apply를 시작하지
않는다.

IdP 장애 drill은 `platform` realm만 최대 90초 비활성화하고 master recovery identity로
복구한다. `EXIT`·`INT`·`TERM` trap으로 realm enable을 보장하며, 영향과 복구 ID를 다시
제시한 별도 승인 뒤에만 실행한다. realm 중단 중에도 trusted SSH + root-only break-glass
kubeconfig로 `/readyz`, Node, Headlamp/Pomerium Ready·UID를 조회하고 필요한 Pod를 복구할 수
있어야 한다. realm 복구 뒤 모든 OIDC·Pomerium·RBAC 검증을 재실행한다.

## GitOps rollback과 완료

main 반영 전에는 기록한 `origin/main` 기준점으로 branch를 rebase하고 전체 로컬·live
사전검증을 반복한다. root/child `targetRevision`은 항상 `main`이다. main 반영 직후 필수
live 검증이 실패하면 public main을 재작성하지 않고 해당 단일 squash commit을 즉시 revert해
HEADLAMP-01 bootstrap 기준선을 복구한다. Keycloak client와 외부 secret 객체는 앱 rollback
직전에 자동 삭제하지 않는다.

DONE은 root·child `main Synced/Healthy`, OIDC/Pomerium/RBAC positive·negative evidence,
bootstrap prune, DNS drift 없음, break-glass recovery, secret/JWT/temp/listener 0, rollback
지점과 실제 복구 evidence가 모두 있을 때만 `docs/backlog.md`에서 갱신한다. `CAP-02`는
`BKP-05`와 `HEADLAMP-02`가 모두 DONE일 때만 READY로 연다.
