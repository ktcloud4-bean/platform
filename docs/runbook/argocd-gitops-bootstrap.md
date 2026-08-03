# Argo CD private Git bootstrap

- 작업: `GITOPS-01`
- 상태: 적용·검증 완료 (main 전환은 병합 승인 뒤 수행)
- 잠금: `K3S-BOOTSTRAP`
- 주소 단일 원본: [`docs/ip-plan.md`](../ip-plan.md)
- 작업 상태 단일 원본: [`docs/backlog.md`](../backlog.md)

## 결정과 소유 경계

`k3s-01`의 Kubernetes `v1.36.2+k3s1`에는 Argo CD `v3.5.0-rc3`을 적용한다.
이 버전은 pre-release이지만 release-3.5의 공식 시험 표가 Kubernetes `v1.36`을
포함하며, 운영자가 그 위험을 명시적으로 수용했다. `latest`, release branch와
k3s downgrade는 사용하지 않는다. 정식 `v3.5` GA가 나오면 자동 추적하지 않고,
고정 tag·manifest·image digest·upgrade 결과를 다시 검증하는 별도 version update로
전환한다.

bootstrap은 Argo CD namespace·CRD·controller·최초 AppProject·repository credential
Secret·root Application을 직접 적용한다. 이것들은 Argo CD가 Git을 읽기 전에 있어야
하므로 GitOps가 소유하지 않는다. 최종 `gitops/root/`의 AppProject만 root Application이
관리한다. 검증용 ConfigMap은 drift와 prune을 증명한 뒤 Git과 클러스터에서 제거했다.
UI 외부 노출, Ingress, public DNS, NAT는 만들지 않으며 검증은 SSH를 통한 `k3s kubectl`과
localhost port-forward로 제한한다.

## 고정 release와 무결성

[`release-metadata.env`](../../gitops/bootstrap/argocd/release-metadata.env)가 고정값의
단일 원본이다.

| 항목 | 고정값 |
|---|---|
| Argo CD | `v3.5.0-rc3` |
| tag commit | `7660efb23b2d56bf01b0189ba5e2c2ab12badf71` |
| 공식 manifest | `https://raw.githubusercontent.com/argoproj/argo-cd/v3.5.0-rc3/manifests/install.yaml` |
| vendored manifest SHA-256 | `4f25b7f9669c5d6212d8a5fe1b31e2e47d3d8d84d0f436a7f68dcdd033f63dd7` |
| Argo CD image digest | `sha256:4e88d929195c9e1d224d046ad629e365dc60f8a5d65d88d6eee15810aac9dbad` |
| Dex image digest | `sha256:b8469881d3cb3a73001506f0d3aaefecb9c45d2311c1e0f405d8ac538316c59d` |
| Redis image digest | `sha256:08ad0b1d280850169a790dba1393ff7a90aef951fc19632cf4d3ce4f78e679ba` |

manifest는 공식 고정 tag에서 내려받아 SHA-256을 대조한 뒤 Git에 vendor한다.
bootstrap script는 적용 전에 같은 SHA-256을 재확인한다. image digest는
`skopeo inspect`로 확인했고, 적용 뒤 Pod의 `imageID`로 다시 대조한다.

## private Git과 SSH 신뢰

repository URL은 `ssh://git@ssh.github.com:443/ktcloud4-bean/platform.git`다. 공개
TCP 22를 열지 않는다. GitHub 공식 Ed25519 fingerprint
`SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`와 일치하는
`[ssh.github.com]:443` key는 official Argo CD manifest의
`argocd-ssh-known-hosts-cm`에 포함되어 있다. `StrictHostKeyChecking=no`,
`accept-new`, `ssh-keyscan` 단독 신뢰를 사용하지 않는다.

| 항목 | 값 |
|---|---|
| GitHub deploy key 제목 | `GITOPS-01-k3s-01-argo-readonly-20260731` |
| GitHub deploy key ID | `158868245` |
| 권한 | read-only |
| 공개 fingerprint | `SHA256:8mGR//dKQq5N7Z90wdazcMWzGBQspnZR7lF4ZC+3InE` |
| 장기 보관 | 사용자 Bitwarden |

private key는 Git·문서·일반 로그에 넣지 않는다. bootstrap 때만 Bitwarden에서 mode
`0600` 작업 파일로 내보내며 script가 Kubernetes Secret에 stdin으로 주입한다.
Secret 원문 manifest, PAT, 개인 계정 SSH key는 저장소에 넣지 않는다.

## 적용 전 gate

1. `GITOPS-01 READY`, `K3S-01 DONE`, `K3S-BOOTSTRAP` 비점유와 S3-01의 독립 lock.
2. k3s service active, Node Ready, DiskPressure=False, CoreDNS·Traefik·ServiceLB·
   metrics-server·local-path-provisioner 정상, SELinux Enforcing, swap 0,
   failed unit 0, guest root 여유가 `capacity-plan.md` 정지 기준 밖.
3. `argocd` namespace, `argoproj.io` CRD, Application, AppProject와 관련
   ServiceAccount·Secret이 모두 없다. 하나라도 있으면 인수·삭제하지 않고 중단한다.
4. GitHub 저장소 private/default branch, deploy key read-only, strict host-key SSH
   443 private Git read, manifest SHA-256·tag commit·image digest를 확인한다.

## bootstrap과 fresh clone

fresh clone은 저장소 밖의 trusted k3s `known_hosts`, GitHub 공식 Ed25519 host key만 든
`known_hosts`, Bitwarden에서 내보낸 mode `0600` deploy key 파일만 전제한다. 기존
worktree·숨은 파일·kubeconfig를 복사하지 않는다.

```bash
export K3S_SSH_TARGET=rocky@k3s-01.imcherry5778.xyz
export K3S_SSH_KNOWN_HOSTS=<저장소-밖-trusted-known_hosts>
export GITHUB_SSH_KNOWN_HOSTS=<GitHub-공식-Ed25519-key만-든-known_hosts>
export DEPLOY_KEY=<Bitwarden에서-내보낸-mode-0600-deploy-key>
test "$(stat -c %a "$DEPLOY_KEY")" = 600
GIT_SSH_COMMAND="ssh -o BatchMode=yes -o IdentitiesOnly=yes \
  -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$GITHUB_SSH_KNOWN_HOSTS \
  -o HostKeyAlgorithms=ssh-ed25519 -i $DEPLOY_KEY" \
  git clone ssh://git@ssh.github.com:443/ktcloud4-bean/platform.git platform
cd platform
git checkout <검증할-고정-commit-SHA>
./gitops/bootstrap/argocd/bootstrap.sh \
  --target-revision <검증할-고정-commit-SHA> \
  --private-key "$DEPLOY_KEY"
```

script는 vendored manifest를 server-side apply하고 controller·server·repo-server가
Ready일 때까지 기다린다. 그 뒤 repository Secret, AppProject와 root Application을
적용한다. 초기 root Application은 mutable branch가 아니라 task branch의 signed commit
SHA를 `targetRevision`으로 쓴다. main merge 뒤에만 `targetRevision=main`으로 바꾸고
remote main SHA와 `Synced`·`Healthy`를 다시 증명한다.

## 검증과 rollback

controller·repo-server·application-controller Ready, runtime imageID digest,
repository connection, `platform-root`의 `Synced`·`Healthy`를 확인한다. 임시
`gitops-01-verification` ConfigMap으로 data drift 자동 복구와 Git 제거 뒤 prune을
증명하고, 최종 선언에는 남기지 않는다. Argo CD Pod 하나만 재시작해 Application 상태
유지와 두 번째 bootstrap 선언 diff를 확인한다. 마지막에 Node·기본 구성요소·
DiskPressure·SELinux·failed unit·용량, AVC·restart loop·orphan 리소스를 재확인한다.

실패 시 기존 Argo CD가 없었다는 사전 증거가 있을 때만 이 작업이 만든 `argocd`
namespace, vendored manifest의 정확한 Argo resource, `argocd-repo-platform` Secret,
GitHub deploy key ID `158868245`를 개별 대상으로 rollback한다. 다른 namespace,
기존 CRD consumer, GitHub key, wildcard resource를 삭제하지 않는다. k3s uninstall,
cluster reset, 노드 재부팅, VM·OpenTofu·OPNsense 변경은 금지다.

## 적용·검증 결과 (2026-07-31)

- 사전 gate에서 k3s `v1.36.2+k3s1`, Node `Ready=True`·`DiskPressure=False`, SELinux
  `Enforcing`, swap 0, failed systemd unit 0, 기존 Argo CD namespace·CRD·Application·
  AppProject·관련 Secret 0을 확인했다. guest root는 199 GiB 중 194 GiB 여유(사용 3%)로
  guest 여유 경고 25%·정지 20% 기준 밖이며, CoreDNS·Traefik·ServiceLB·metrics-server·
  local-path-provisioner도 Running/Ready였다.
- vendored manifest SHA-256은 위 고정값과 일치했다. 실행 Pod의 Argo CD, Dex, Redis
  imageID digest도 각각 고정 digest와 일치했다. Service는 전부 ClusterIP이고 Argo CD
  Ingress는 0개다.
- root Application은 SSH 443 private repository에서 task branch의 signed commit
  `50383d78fcbba357a724d03c6e6f450569296a69`을 읽어 `Synced/Healthy`가 됐다. repository
  Secret은 `argocd.argoproj.io/secret-type=repository` label만 확인했고 데이터 원문은
  출력하지 않았다.
- 임시 ConfigMap의 `managed-by` 값을 `drift`로 한 번만 바꾸자 두 번째 5초 관찰 주기에
  `gitops`로 self-heal됐다. 이어 Git에서 그 ConfigMap을 제거하고 동일 signed commit으로
  root Application을 전환하자 클러스터에서도 정확히 prune됐으며 Application은
  `Synced/Healthy`를 유지했다.
- `argocd-repo-server-54dc495f7d-7ztt5` Pod 한 개만 삭제해 Deployment 복구를 확인했고,
  Application은 같은 revision에서 `Synced/Healthy`를 유지했다. 두 번째 bootstrap과
  fresh clone bootstrap도 완료됐다. bootstrap과 같은 `--server-side --force-conflicts`
  조건의 manifest·namespace·AppProject·Application diff는 모두 exit 0이었다. 일반
  server-side diff는 upstream manifest field 하나의 기존 `kubectl` manager 충돌로
  중단되므로 무변경 판정에는 실제 bootstrap 조건을 사용했다.
- 별도 `/tmp` fresh clone은 GitHub SSH 443, 저장소 밖 deploy key·host key·k3s known_hosts만
  사용해 같은 commit을 checkout하고 bootstrap했다. 기존 worktree·숨은 파일·kubeconfig는
  사용하지 않았고, 검증 후 그 임시 clone은 제거했다.
- 최종 점검에서 Argo CD Pod 7개는 Running/Ready, restart loop 0, Argo CD Job 0,
  `argocd` namespace Active, 오늘의 AVC 0줄이었다. 잘못된 최초 manifest 적용이 잠시
  `default` namespace에 만든 manifest 정의 resource 50개와 자동 생성 Secret 2개는
  기존 Argo CD가 없던 것을 확인한 뒤 정확한 이름으로만 제거했고, 최종 `default`에는
  이름이 `argocd`인 namespaced resource가 0개다.

`v3.5.0-rc3`은 pre-release다. 정식 `v3.5` GA 전환은 이 결과를 승계하지 않으며,
새 fixed tag·manifest SHA-256·image digest·Kubernetes 호환성·upgrade 및 rollback
검증을 갖춘 별도 작업으로 수행한다. deploy key의 장기 복구본은 Bitwarden에 있고,
Vault 이관은 `VAULT-01` 이후 별도 credential migration으로 재검토한다.

## GITOPS-02: 자체 OIDC·RBAC

- 작업: `GITOPS-02`
- 상태: 적용·검증 완료
- 잠금: `OPNSENSE-LIVE`(merge 전 라이브 검증에서 `ARGO-ROOT` 추가)
- Route: `https://argo.imcherry5778.xyz` (Pomerium, `gitops/apps/pomerium`가 소유)

### 결정과 소유 경계

Argo CD 본체(`argocd-cm`, `argocd-rbac-cm` 포함)는 `gitops/apps/*` child Application이
아니라 이 문서와 `gitops/bootstrap/argocd/`가 계속 소유한다. vendored
`install.yaml`의 `argocd-cm`은 Cilium·Kyverno·cert-manager 등 기본 UI clutter
축소용 `resource.customizations.*`·`resource.exclusions` 키를 이미 채운 채
SHA-256으로 고정되어 있다. 이 키를 보존하면서 `url`·`oidc.config`만 추가하려면
전체 object apply(교체)가 아니라 JSON merge patch가 필요하다. 같은 이유로
`argocd-rbac-cm`도 patch로 적용한다. 두 patch 파일
([`argocd-cm.patch.yaml`](../../gitops/bootstrap/argocd/argocd-cm.patch.yaml),
[`argocd-rbac-cm.patch.yaml`](../../gitops/bootstrap/argocd/argocd-rbac-cm.patch.yaml))은
vendored manifest 밖에 두어 `ARGOCD_MANIFEST_SHA256` 무결성 검증 대상에서 제외했고,
`bootstrap.sh`는 주 manifest 적용 뒤 이 두 patch를 `kubectl patch --type merge`로
이어서 적용해 fresh bootstrap도 같은 최종 상태를 재현한다.

Argo CD는 Dex를 거치지 않는 직접 `oidc.config`를 쓴다. Keycloak `argocd` client는
`headlamp`와 같은 public Authorization Code + PKCE(`enablePKCEAuthentication: true`)이며
`clientSecret`이 없다. ID token의 `aud`는 스펙상 항상 요청 client와 같으므로 Argo API의
Bearer 검증이 이 값을 신뢰할 수 있지만, access token의 기본 `aud`(`account`)는 그렇지
않아 반드시 **id_token**을 Bearer로 써야 한다. `groups` protocol mapper는 scope에
묶이지 않고 client에 직접 붙어 있어 `requestedScopes`에 `groups`를 넣지 않아도 항상
포함된다.

`argocd-rbac-cm`은 내장 `role:readonly`를 재사용하지 않고 더 좁은 `role:gitops-viewer`를
새로 정의한다. 내장 `role:readonly`는 `repositories, get`을 포함해 repository 연결
목록을 볼 수 있게 하지만, `role:gitops-viewer`는 `applications, get`과 `projects, get`만
허용해 repository·cluster·account·gpgkey 경로를 아예 부여하지 않는다. `policy.default`는
빈 문자열로 고정해 어떤 group에도 매핑되지 않은 로그인은 role이 전혀 없다. `g, /platform-users,
role:gitops-viewer` 한 줄만 두고 `/platform-privileged`는 매핑하지 않는다. `gitea`·`sonarqube`
Route가 이미 `/platform-users`만 허용하는 것과 같은 이유로, 이 Route도 조회 전용 그룹
하나에만 연다([Pomerium README](../../gitops/apps/pomerium/README.md)).

### 적용 전 gate

1. `GITOPS-01`·`POM-01 DONE`, `OPNSENSE-LIVE` 비점유.
2. 최신 `origin/main` 전용 `gitops-02` branch/worktree.
3. Argo root/child가 `Synced/Healthy`, `targetRevision=main`. Traefik Pod UID·restart
   count·`HelmChartConfig/traefik` resourceVersion을 적용 전 기록(변경 대상이 아니므로
   불변 확인용).
4. `argocd-cm`·`argocd-rbac-cm` 라이브 `data`를 미리 백업해 rollback 시 정확히 되돌릴
   키 집합을 안다.
5. `pomerium` namespace의 `argocd` route·`argocd-egress` NetworkPolicy, Keycloak
   `argocd` client가 없거나 이 선언과 정확히 일치한다.
6. 내부 `argo` A/AAAA와 공개 resolver의 A/AAAA가 모두 없다.

### 적용

```bash
export KC01_SECRET_DIR=/home/imcherry/secrets/ktcloud4-bean/keycloak
gitops/tools/gitops-02/provision-keycloak-client.sh --check
gitops/tools/gitops-02/provision-keycloak-client.sh --apply

K3S_HOST=rocky@k3s-01.imcherry5778.xyz
ssh "$K3S_HOST" 'sudo -n /usr/local/bin/k3s kubectl -n argocd patch configmap argocd-cm \
  --type merge --patch-file=/dev/stdin' < gitops/bootstrap/argocd/argocd-cm.patch.yaml
ssh "$K3S_HOST" 'sudo -n /usr/local/bin/k3s kubectl -n argocd patch configmap argocd-rbac-cm \
  --type merge --patch-file=/dev/stdin' < gitops/bootstrap/argocd/argocd-rbac-cm.patch.yaml
# oidc.config는 argocd-server 시작 시 초기화되는 provider라 hot-reload를 신뢰하지 않고
# 단일 재기동으로 반영을 확정한다. RBAC(policy.csv)는 이미 hot-reload된다.
ssh "$K3S_HOST" 'sudo -n /usr/local/bin/k3s kubectl -n argocd rollout restart deployment/argocd-server'
ssh "$K3S_HOST" 'sudo -n /usr/local/bin/k3s kubectl -n argocd rollout status deployment/argocd-server --timeout=180s'
```

Pomerium Route·NetworkPolicy egress·`argo` alias는 merge 전 `ARGO-ROOT` 라이브 검증
절차를 따라 `platform-root`를 설정 commit SHA로 전환한 뒤 적용한다
([Pomerium 런북](pomerium-routes.md), `AGENTS.md`의 merge 전 라이브 검증 절차).

### 라이브 검증

```bash
export OPN_ENV=/home/imcherry/secrets/ktcloud4-bean/opnsense/env
gitops/tools/gitops-02/opnsense-alias.py --env-file "$OPN_ENV" check
GITOPS02_ROOT_TARGET_REVISION=<pointer-SHA> GITOPS02_POMERIUM_TARGET_REVISION=<settings-SHA> \
  gitops/tools/gitops-02/verify-live.sh
```

검증기는 다음을 같은 실행에서 순서대로 판정한다.

1. Pomerium: `imcherry`(`/platform-users`) 브라우저 OIDC 로그인이
   `https://argo.imcherry5778.xyz/`를 통과(200, upstream 응답)하고, `headlamp-no-group`
   계정은 403으로 거부된다. 같은 통과 세션에서 별도 Argo Bearer 없이 `/api/v1/applications`를
   호출하면 Argo CD 자신이 401을 반환해, Pomerium 통과가 Argo 인증을 대신하지 않음을
   실증한다.
2. Argo 자체 OIDC: Keycloak `argocd` client로 `imcherry`의 id_token을 PKCE로 직접
   발급받아(Pomerium을 거치지 않고 k3s-01 loopback port-forward로 argocd-server에 직접
   접속) 같은 token으로 연속 호출한다. `GET /api/v1/applications` 200과 `platform-root`
   및 대표 child의 `Synced/Healthy`, `POST .../sync` 403, `DELETE
   /api/v1/applications/<child>` 403, `GET /api/v1/repositories` 403(repo credential
   조회 거부)을 모두 같은 세션에서 확인한다.
3. `HelmChartConfig/traefik` resourceVersion과 Traefik Pod UID·restart count 불변,
   `argo` 내부 A 1건·내부 AAAA 0건·공개 A/AAAA 0건, drift 없음.
4. root·child `Synced/Healthy`.

### Rollback

```bash
ssh "$K3S_HOST" "sudo -n /usr/local/bin/k3s kubectl -n argocd patch configmap argocd-cm \
  --type merge -p '{\"data\":{\"url\":null,\"oidc.config\":null}}'"
ssh "$K3S_HOST" "sudo -n /usr/local/bin/k3s kubectl -n argocd patch configmap argocd-rbac-cm \
  --type merge -p '{\"data\":{\"policy.default\":null,\"policy.csv\":null,\"scopes\":null}}'"
ssh "$K3S_HOST" 'sudo -n /usr/local/bin/k3s kubectl -n argocd rollout restart deployment/argocd-server'
```

merge 전에는 `platform-root`를 시작 시 기록한 main SHA로 되돌린다. Pomerium `argocd`
route·`gitops-02-pomerium-to-argocd` NetworkPolicy·`argo` alias rollback은
[Pomerium 런북](pomerium-routes.md)의 배포·DNS rollback 절차를 그대로 따른다. merge 뒤
결함은 main을 재작성하지 않고 별도 FIX 작업에서 GITOPS-02 squash commit을 `git revert`한다.
