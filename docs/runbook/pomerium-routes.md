# Pomerium Core·Dashy Portal 적용과 복구 런북

- 작업: `POM-01`
- Route/Portal: `https://access.imcherry5778.xyz`
- Keycloak issuer: `https://sso.imcherry5778.xyz/realms/platform`
- 독립 복구: trusted SSH host key + k3s 관리자 kubeconfig
- 인증·권한 결정: [ADR-0004](../adr/0004-zero-trust-identity-and-management-access.md)
- 시크릿 소비 결정: [ADR-0013](../adr/0013-keycloak-secret-consumption.md)
- 포털 분리 결정: [ADR-0014](../adr/0014-dashy-access-portal.md)

## 소유 경계

`gitops/apps/pomerium`은 Pomerium Core all-in-one과 Dashy 각 한 replica, 선언형 Route,
ClusterIP Services와 표준 Kubernetes Ingress를 선언한다. Enterprise/Zero control plane,
Pomerium Ingress Controller CRD, PVC, Kubernetes Secret과 cluster-wide injector는 만들지 않는다.

기존 packaged Traefik이 TLS와 hostname routing을 소유한다. Pomerium은 Traefik 뒤의
ClusterIP HTTP upstream이며 `insecure_server`는 이 Pod network 구간에만 적용한다.
`HelmChartConfig`, 정적 entrypoint/plugin과 Traefik Pod를 수정·재기동하지 않는다.

Pomerium self-hosted authenticate URL은 보호 Route URL과 달라야 한다. 승인된 DNS 변경을
`access` alias 한 건으로 제한하기 위해 기존 canonical 이름을 callback에 사용한다.

| URL | 역할 |
|---|---|
| `https://access.imcherry5778.xyz` | Pomerium 보호 Dashy Portal |
| `https://access.imcherry5778.xyz/pom01-platform-user-check` | `/platform-users` 보호 검증 Route |
| `https://k3s-01.imcherry5778.xyz` | Pomerium authenticate service와 OIDC callback 전용 |
| `https://sso.imcherry5778.xyz` | Keycloak issuer; Pomerium 뒤에 두지 않음 |

Pomerium의 로그인 성공은 upstream 권한이 아니다. 검증 Route policy는 OIDC
`claim/groups=/platform-users`를 명시적으로 요구한다. Dashy Portal 진입은
`/platform-users` 또는 `/platform-privileged`를 요구하고, 타일은 `showForGroups`로 다시
선별한다. 타일 숨김은 실제 인가가 아니며 `HEADLAMP-02`는 이 진입 판정 위에 사용자 OIDC
token과 Kubernetes RBAC를 별도로 얹는다.

## 적용 전 gate

다음을 모두 확인하고 전제가 다르면 변경하지 않는다.

1. `POM-01 READY`, 선행 `KC-01`·`INGRESS-01`·`VAULT-02 DONE`.
2. 최신 `origin/main` 전용 `task/pom-01` branch/worktree이며 작업 범위가 깨끗하다.
3. Node `Ready`, `DiskPressure=False`, Vault `initialized=true`·`sealed=false`, Keycloak과
   Argo root/child가 `Synced/Healthy`, `targetRevision=main`이다.
4. packaged Traefik `3.7.4` 하나와 ServiceLB 하나가 정상이다. Traefik Pod UID,
   restart count와 `HelmChartConfig/traefik` resourceVersion을 적용 전 기록한다.
5. `pomerium` namespace·Application·AppProject, `pomerium`·`dashy-portal` Keycloak clients,
   Vault auth role·KV path가 없거나 이 선언과 정확히 일치한다. 기존 객체가 다르면
   인수·교정하지 않는다.
6. 내부 `access` A/AAAA와 공개 resolver의 A/AAAA가 모두 없고, 기존 `k3s-01` A와 `sso`
   내부 A만 `10.10.20.10`이다.
7. 현재 host RAM·guest disk·Node memory가 `capacity-plan.md` 정지 기준 밖이다.

읽기 전용 realm/Vault 분류는 다음처럼 먼저 실행한다. 토큰과 secret 원문을 출력하지 않는다.

```bash
export POM01_SECRET_DIR=/home/imcherry/secrets/ktcloud4-bean/pomerium
export KC01_SECRET_DIR=/home/imcherry/secrets/ktcloud4-bean/keycloak
export VAULT_ROOT_TOKEN_FILE=/home/imcherry/secrets/ktcloud4-bean/vault-root.token
export K3S_SSH_KNOWN_HOSTS=/home/imcherry/.ssh/known_hosts
gitops/tools/pom-01/provision.sh --check
```

Git bootstrap은 기존 `kc-verify`만 소유한다. POM 선언은 기존 realm/group/user/client를
바꾸지 않고 `pomerium` confidential client와 `dashy-portal` public PKCE client만 추가한다.
기존 객체가 이미 있으면 비밀 제외 선언이 정확히 일치할 때만 계속한다.

## DNS 승인 gate

백로그 표의 `POM-01` 잠금은 “없음”이지만 `access` alias는 실제로
`OPNSENSE-LIVE`를 요구한다. 이 차이, 정확한 대상, 영향과 rollback을 사용자에게 보고하고
승인받기 전에는 `apply`를 실행하지 않는다.

읽기 전용 확인:

```bash
OPN_ENV="$HOME/secrets/ktcloud4-bean/opnsense/env"
gitops/tools/pom-01/opnsense-alias.py --env-file "$OPN_ENV" check
infra/opnsense/scripts/check-drift.sh --env-file "$OPN_ENV"
```

승인 뒤에만 기존 `k3s-01` host UUID를 live API에서 다시 식별하고 alias 한 건을 추가한다.

```bash
gitops/tools/pom-01/opnsense-alias.py --env-file "$OPN_ENV" apply
dig +short @10.10.20.1 access.imcherry5778.xyz A
dig +short @10.10.20.1 access.imcherry5778.xyz AAAA
dig +short @1.1.1.1 access.imcherry5778.xyz A
dig +short @1.1.1.1 access.imcherry5778.xyz AAAA
infra/opnsense/scripts/check-drift.sh --env-file "$OPN_ENV" --update
infra/opnsense/scripts/check-drift.sh --env-file "$OPN_ENV"
```

기대값은 내부 A `10.10.20.10`, 내부 AAAA 0건, 공개 A/AAAA 0건과 drift 없음이다.
스크립트는 `search_host_override`·`search_host_alias`로 precondition을 다시 읽고,
`add_host_alias`·`service/reconfigure` 지원 API만 쓴다. PF·NAT·Cloudflare·Dnsmasq와 다른
Unbound row는 대상이 아니다.

## Keycloak clients와 Vault 적용

`keycloak-client.json`은 Pomerium confidential client,
`dashy-keycloak-client.json`은 Dashy public client의 secret 제외 선언이다.

- 두 client 모두 Authorization Code만 허용하고 implicit/direct grant/service account 비활성
- 두 client 모두 `fullScopeAllowed=false`, ID/access/userinfo full-path `groups` mapper 하나
- Pomerium은 exact callback·exact `https://access.imcherry5778.xyz/` post-logout URI와
  Vault 보관 confidential secret
- Dashy는 `access` origin의 public client, PKCE `S256`, client secret 없음

client secret, shared/cookie secret과 EC P-256 signing private key는 저장소 밖 mode `0600`
파일로 생성하고 `kv/pomerium/runtime`에 쓴다. Pomerium ServiceAccount에만 묶인
`auth/kubernetes/role/pomerium`은 `pomerium` policy 하나, TTL 15분·max TTL 1시간과
default policy 없음, projected token과 같은 `audience=vault`로 구성한다.

```bash
gitops/tools/pom-01/provision.sh --apply
gitops/tools/pom-01/provision.sh --check
```

스크립트는 기존 `pomerium` 또는 `dashy-portal` client가 다르면 중단한다. Job/import로 realm을
덮어쓰지 않고 Vault seal/init/Raft, Keycloak 기존 객체, PostgreSQL과 Kubernetes Secret을
건드리지 않는다.

## GitOps 적용

검증 중 mutable branch 이름을 child Application에 넣지 않는다.

1. 앱·도구·문서 설정 commit을 서명해 push한다.
2. 다음 서명 commit에서 `pomerium` child `targetRevision`을 설정 commit SHA로 바꾼다.
3. `platform-root`를 pointer commit SHA로 전환한다.
4. root와 child가 각각 pointer/settings SHA에서 `Synced/Healthy`인지 확인한다.
5. Pomerium·Dashy imageID가 Deployment에 고정한 release metadata의 multi-arch index
   digest와 일치하는지 확인한다. 선택된 linux/amd64 manifest digest도 metadata에 별도로 기록한다.
6. 최종 검증 뒤 child `targetRevision`을 `main`으로 되돌려 최신 `origin/main`에 rebase한다.
7. clean main worktree에서 한 번만 squash merge하고 push한 뒤 root를 `main`으로 돌린다.

적용 전후 render와 server-side dry-run을 검사한다.

```bash
kubectl kustomize gitops/apps/pomerium
kubectl kustomize gitops/root
shellcheck gitops/tools/pom-01/*.sh
python3 -m py_compile gitops/tools/pom-01/*.py
node --check gitops/tools/pom-01/dashy-browser.js
git diff --check
```

## 라이브 검증

기본 검증기는 같은 실행에서 일상 ID allow와 특권 ID deny를 대조하고, token·cookie 원문을
출력하지 않는다.

```bash
export POM01_CONNECT_IP=10.10.20.10
gitops/tools/pom-01/verify-live.sh
```

merge 전 immutable revision 검증에서는 `POM01_EXPECTED_ROOT_REVISION`과
`POM01_EXPECTED_APP_REVISION`에 각각 현재 root pointer SHA와 settings SHA를 넣는다. 두 값을
생략하면 최종 완료 조건인 `main`을 요구한다.

검증 항목은 다음과 같다.

- Keycloak issuer 고정, `kc-verify`의 MFA 누락 `400 invalid_grant`, 올바른 TOTP 성공과
  실제 groups claim
- `imcherry`의 검증 Route exact marker HTTP 200과 실제 Dashy 보호 타일 표시
- `/platform-users`가 없는 `imcherry-admin`의 Route 403과 실제 Dashy 타일 미표시
- logout 뒤 첫 Route 요청이 Pomerium authentication path로 redirect
- exact `access` TLS hostname 성공, 잘못된 hostname의 TLS 검증 실패, HTTP 301
- root·child `Synced/Healthy`, `targetRevision=main`, namespace Secret 0건
- 상시 containers SA token 비마운트, Pomerium·Dashy health와 고정 image digest
- Git 추적 파일과 전체 Pomerium/Dashy init/main log의 secret/JWT 원문 0건

5분 session cookie의 실제 만료도 별도 새 로그인으로 기다려 검증한다. 검증기는 30초마다
남은 상한만 출력하며 cookie/token을 출력하지 않는다.

```bash
wait_seconds=$((31 - $(date +%s) % 30)); sleep "$wait_seconds"
python3 gitops/tools/pom-01/browser-session.py \
  --connect-ip 10.10.20.10 \
  --username imcherry \
  --password-file "$KC01_SECRET_DIR/daily-password" \
  --totp-file "$KC01_SECRET_DIR/daily-totp" \
  --expect allow \
  --check-expiry \
  --maximum-expiry-wait 360
```

만료 뒤 첫 요청은 route body가 아니라 Pomerium authentication path의 302/303이어야 한다.

### Pods 재생성

Vault가 unsealed인지 먼저 확인하고 Pomerium과 Dashy Pod를 label로 각각 정확히 한 건 식별해
삭제한다. Vault, Keycloak과 Traefik Pod는 삭제하지 않는다.

```bash
old_pomerium_uid=$(sudo /usr/local/bin/k3s kubectl -n pomerium get pod \
  -l app.kubernetes.io/name=pomerium -o jsonpath='{.items[0].metadata.uid}')
old_dashy_uid=$(sudo /usr/local/bin/k3s kubectl -n pomerium get pod \
  -l app.kubernetes.io/name=dashy -o jsonpath='{.items[0].metadata.uid}')
pomerium_pod=$(sudo /usr/local/bin/k3s kubectl -n pomerium get pod \
  -l app.kubernetes.io/name=pomerium -o jsonpath='{.items[0].metadata.name}')
dashy_pod=$(sudo /usr/local/bin/k3s kubectl -n pomerium get pod \
  -l app.kubernetes.io/name=dashy -o jsonpath='{.items[0].metadata.name}')
sudo /usr/local/bin/k3s kubectl -n pomerium delete pod "$pomerium_pod" "$dashy_pod"
sudo /usr/local/bin/k3s kubectl -n pomerium rollout status deployment/pomerium --timeout=180s
sudo /usr/local/bin/k3s kubectl -n pomerium rollout status deployment/dashy --timeout=180s
new_pomerium_uid=$(sudo /usr/local/bin/k3s kubectl -n pomerium get pod \
  -l app.kubernetes.io/name=pomerium -o jsonpath='{.items[0].metadata.uid}')
new_dashy_uid=$(sudo /usr/local/bin/k3s kubectl -n pomerium get pod \
  -l app.kubernetes.io/name=dashy -o jsonpath='{.items[0].metadata.uid}')
test "$old_pomerium_uid" != "$new_pomerium_uid"
test "$old_dashy_uid" != "$new_dashy_uid"
```

새 Pods에서 전체 `verify-live.sh`와 session 만료 검증을 반복한다. Pomerium init이 실패하면서 Vault가
sealed라면 Vault Pod를 건드리지 말고 사용자에게 직접 unseal을 요청한다.

## Keycloak 장애와 독립된 복구 drill

이 시험은 `platform` realm 로그인을 잠시 막고 Pomerium Pod를 재생성한다. 정확한 영향,
90초 timeout, master 복구 ID와 EXIT/INT/TERM 원복 trap을 보고해 **사용자 승인을 받은 뒤에만**
실행한다.

```bash
KC01_CONNECT_IP=10.10.20.10 \
gitops/tools/pom-01/verify-recovery.sh
```

검증기는 다음 순서로 동작한다.

1. Vault unsealed, root/child main, Pomerium health와 Traefik UID를 기록한다.
2. master realm의 개인 복구 ID로 `platform` realm만 비활성화한다.
3. platform token `403 access_denied`를 확인한다.
4. Keycloak/Pomerium을 거치지 않는 trusted SSH + root-only k3s kubeconfig로 Pomerium health를
   조회하고 정확한 Pomerium Pod 하나만 재생성한다.
5. 새 UID·Ready·health와 Traefik UID 불변을 확인한다.
6. 같은 master 복구 경로로 realm을 즉시 활성화하고 platform token 200을 확인한다.

Pomerium 자체가 유일한 관리 경로가 아니다. 전체 Keycloak이 기동하지 않는 경우에는
[`keycloak.md`](keycloak.md)의 offline bootstrap 조건을 따르고, Pomerium 복구 때문에
Keycloak client/group/user를 우회 수정하지 않는다. drill 뒤 전체 `verify-live.sh`를 다시
통과해야 한다.

## OBS-02 운영 UI Route

`OBS-02`는 Pomerium Core의 선언형 Route와 기존 단일 표준 `Ingress`에 Grafana·Prometheus·
Alertmanager hostname을 추가한다. `HelmChartConfig`, Traefik static entrypoint/plugin, Traefik
Pod는 수정하거나 재기동하지 않는다. `pomerium` namespace default-deny 아래에서 Route와 같은
commit의 `obs-egress.yaml`은 Grafana Pod TCP 3000, Prometheus Pod TCP 9090, Alertmanager Pod
TCP 9093만 연다. `obs-default-deny`의 반대편도 막혀 있으므로 `obs-02-*-pomerium-ingress`는
같은 Pomerium source Pod와 세 대상 Pod·port만 다시 명시한다.

Unbound alias 세 건은 `OPNSENSE-LIVE` 잠금에서 먼저 live host override를 exact match로 확인한
뒤에만 적용한다. API credential은 출력하지 않는다.

```bash
OPN_ENV="$KTC_SECRET_ROOT/opnsense/env"
gitops/tools/obs-02/opnsense-alias.py --env-file "$OPN_ENV" check
gitops/tools/obs-02/opnsense-alias.py --env-file "$OPN_ENV" apply
dig +short @10.10.20.1 grafana.imcherry5778.xyz A
dig +short @10.10.20.1 prometheus.imcherry5778.xyz A
dig +short @10.10.20.1 alertmanager.imcherry5778.xyz A
infra/opnsense/scripts/check-drift.sh --env-file "$OPN_ENV" --update
infra/opnsense/scripts/check-drift.sh --env-file "$OPN_ENV"
```

각 내부 A는 `10.10.20.10` 하나, 내부 AAAA와 공개 A/AAAA는 0건이어야 한다. Grafana는
`Platform` folder의 node·PVC·Loki 세 패널을 native dashboard provider로 mount하고, Loki
datasource egress만 추가한다. Grafana local admin password는 기존 Vault Agent file input을
그대로 쓴다.

merge 전 immutable 검증은 먼저 `capacity-pre`가 출력한 six values를 고정 입력으로 사용한다.
`OBS02_DENY_*`는 `/platform-users`와 `/platform-privileged` 모두 없는 기존 검증 계정의
0600 password/TOTP file을 명시한다. verifier는 허용·미소속 로그인 session pair로 세 UI를
연속 확인하고, 별도 `/platform-privileged` session에서만 임시 silence를 생성·조회·만료한다.
silence ID, cookie, token, password는 출력하지 않는다.

```bash
gitops/tools/obs-02/verify-live.sh capacity-pre
OBS02_EXPECTED_ROOT_REVISION=<root-pointer-sha> \
OBS02_EXPECTED_OBS_REVISION=<settings-sha> \
OBS02_EXPECTED_POMERIUM_REVISION=<settings-sha> \
OBS02_PRE_AVAILABLE_BYTES=<pre-available> \
OBS02_PRE_PVC_REQUEST_BYTES=<pre-pvc> \
OBS02_PRE_HELMCHARTCONFIG_GENERATION=<pre-generation> \
OBS02_PRE_TRAEFIK_POD_UID=<pre-uid> \
OBS02_PRE_TRAEFIK_RESTARTS=<pre-restarts> \
OBS02_DENY_USERNAME=<unaffiliated-user> \
OBS02_DENY_PASSWORD_FILE=<mode-0600-password-file> \
OBS02_DENY_TOTP_FILE=<mode-0600-totp-file> \
gitops/tools/obs-02/verify-live.sh
```

실패·성공 모두 `platform-root`를 기록한 literal `main` SHA로 복구한다. 실패 후 alias를
삭제해야 하면 exact OBS-02 alias만 rollback하고 `check-drift.sh --update` 뒤 일반 drift 검사를
다시 실행한다. 기존 Pomerium Route, Prometheus·Alertmanager PVC와 OBS-01의 경보 전달 설정은
rollback 대상이 아니다.

## Rollback

### 배포 rollback

merge 전에는 `platform-root`를 시작 시 기록한 main SHA로 되돌린다. finalizer가 child
`Application/pomerium`과 정확히 `pomerium` namespace의 Pomerium·Dashy를 foreground prune하게 한다.
Traefik, Keycloak, Vault와 다른 namespace는 삭제하지 않는다.

merge 뒤 결함은 main을 재작성하지 않고 별도 FIX/revert 작업에서 POM-01 squash commit을
`git revert`한다. Pomerium에 PVC가 없으므로 삭제할 사용자 데이터는 없지만 외부 secret과
Keycloak/Vault 객체는 재배포 복구를 위해 자동 삭제하지 않는다.

### DNS rollback

정확히 POM-01 description·host UUID와 일치하는 `access` alias만 제거한다.

```bash
gitops/tools/pom-01/opnsense-alias.py --env-file "$OPN_ENV" rollback
dig +short @10.10.20.1 access.imcherry5778.xyz A
infra/opnsense/scripts/check-drift.sh --env-file "$OPN_ENV" --update
infra/opnsense/scripts/check-drift.sh --env-file "$OPN_ENV"
```

내부 A/AAAA 0건과 drift 없음을 확인한다. 공개 DNS/NAT·PF·다른 alias는 rollback 대상이 아니다.

### Keycloak/Vault 최종 폐기

Pomerium namespace와 Application이 제거되고 재배포하지 않기로 승인된 경우에만 master 복구
ID로 선언과 정확히 일치하는 `pomerium`과 `dashy-portal` client UUID를 각각 삭제한다. 이어
root token으로 `kv/pomerium/runtime`, `auth/kubernetes/role/pomerium`, `pomerium` policy만
개별 삭제한다.
기존 client/group/user, Kubernetes auth method, KV mount, audit, seal과 Raft는 유지한다.

## 남기면 안 되는 출력과 임시 자원

- client/shared/cookie secret과 signing private key
- Keycloak access/refresh/ID token, Pomerium session cookie와 CSRF 값
- Vault root·child token과 Kubernetes ServiceAccount token
- 원본 OPNsense backup과 API credential

검증이 만든 임시 token/header/form/log 파일은 종료 trap으로 제거한다. port-forward, 임시
namespace·Pod·계정·Route는 최종 0건이어야 한다.
