# Jenkins CI GitOps 기준선

이 디렉터리는 `CI-01`의 Jenkins controller 배포, 동적 Kubernetes build agent 격리,
pipeline 기준선과 시크릿 경계를 소유한다. Docker-in-Docker, privileged container,
Docker socket 마운트, hostPath, Kubernetes Secret과 UI 수동 설정은 사용하지 않는다.
이미지 version·digest·license 근거는 [`release-metadata.env`](release-metadata.env),
플러그인 고정 집합은 [`plugins.txt`](plugins.txt)가 소유한다.

## 배치와 경계

```text
browser ── Traefik ── Pomerium claim/groups=/platform-users
        ── Jenkins local realm ── controller UI (executor 0)

controller ── Kubernetes API (namespace jenkins의 Pod만)
           └─ 동적 agent Pod ── jnlp  ── Gitea SSH clone
                              └─ buildah ── docker.io base pull
                                          └─ Harbor /v2/ push
```

controller는 `numExecutors: 0`이라 build를 직접 실행하지 않는다. 모든 build는
`ci01-buildah` label의 동적 Pod에서 돌고 `podRetention: never`로 build 종료와 함께
사라진다. agent Pod는 ServiceAccount token을 마운트하지 않으므로 Kubernetes API도
Vault도 직접 호출하지 못한다.

## 스스로 결정한 값과 근거

### 빌드 도구는 rootless Buildah

Kaniko는 2025-06-03 upstream이 저장소를 archive하고 유지보수를 중단했으므로 새 공급망
기준선에 채택하지 않는다. Buildah는 privileged 없이 다음 조합으로 동작한다.

| 설정 | 값 | 이유 |
|---|---|---|
| storage driver | `vfs` | overlay와 달리 `/dev/fuse`나 mount 권한이 필요 없다 |
| isolation | `chroot` | `RUN`이 별도 OCI runtime을 띄우지 않는다 |
| `ignore_chown_errors` | `true` | 단일 UID 매핑에서 base layer의 다른 UID chown을 무시한다 |
| capability | `drop: [ALL]` + `add: [SYS_CHROOT]` | copier subprocess가 build context를 chroot로 가둔다 |
| seccomp | `buildah` container만 `Unconfined` | rootless builder의 `unshare(CLONE_NEWUSER)` |

비특권 Pod에는 `newuidmap`/`newgidmap`을 쓸 권한이 없어 rootless buildah가 단일 UID
매핑으로 떨어진다. 그 상태에서 base layer를 풀 때 `lchown`이 실패하므로
[`agent-buildah-config.yaml`](agent-buildah-config.yaml)의 `storage.conf`가 vfs에서만
chown 오류를 무시한다. 빌드 대상 `Containerfile`도 root를 요구하는 `RUN`을 두지 않는다.

### seccomp를 `buildah` container 하나만 완화한 이유

rootless builder는 storage에 쓰기 위해 자기 user namespace를 만들어야 한다. 그런데
Kubernetes `RuntimeDefault` profile은 `CAP_SYS_ADMIN`이 없는 프로세스의
`unshare(CLONE_NEWUSER)`를 막는다. 라이브 노드에서 같은 UID·capability의 두 container를
붙여 확인했다.

| container securityContext | `unshare -U` |
|---|---|
| `runAsUser: 1000`, `drop: [ALL]`, `add: [SYS_CHROOT]`, `RuntimeDefault` | `Operation not permitted` |
| 같은 설정에 `Unconfined` | 성공 |

남은 선택지는 `CAP_SYS_ADMIN`을 주거나 seccomp를 푸는 것뿐이다. `CAP_SYS_ADMIN`은
mount·namespace·BPF를 함께 여는 사실상 root 권한이라 더 큰 확대다. 그래서 `buildah`
container 하나만 `Unconfined`로 두고 나머지는 모두 유지한다. `jnlp` container는
`RuntimeDefault`를 그대로 쓰며, 두 container 모두 `runAsNonRoot: true`,
`allowPrivilegeEscalation: false`, `privileged: false`, `capabilities.drop: [ALL]`이고
hostPath·Docker socket·ServiceAccount token은 없다. 검증기는 이 seccomp 값을 판정 대상에
넣어 `buildah` 밖의 완화나 `SYS_CHROOT` 밖의 capability를 실패로 처리한다.

**재검토 조건**: `RuntimeDefault`에 userns 계열 syscall만 더한 localhost seccomp profile을
`k3s_baseline`이 노드에 선언하면(QUALITY-01의 sysctl과 같은 방식) 이 완화를 없앨 수 있다.
Kubernetes user namespace(`hostUsers: false`)가 이 랩에서 검증되면 그때도 재검토한다.

### `JENKINS_HOME` PVC는 20 GiB

선언 시점의 PVC 요청 합계는 45.125 GiB이고 `capacity-plan.md`의 경고는 96 GiB,
정지는 120 GiB다. 20 GiB를 더하면 65.125 GiB로 경고선 아래에 남고 후속
`SCAN-01`·`SIGN-01`·`E2E-01`에 30 GiB 이상 여유를 남긴다. 이 PVC는 job 설정, build
기록과 고정 플러그인만 보관한다. build workspace는 agent Pod의 `emptyDir`이고
image layer는 Harbor가 소유하므로 이 PVC로 들어오지 않는다. build 기록은
`buildDiscarders`와 job의 `logRotator(20)`으로 상한을 둔다.

### 플러그인은 전이 의존성까지 고정

[`plugins.txt`](plugins.txt)는 최상위 11개(`configuration-as-code`, `kubernetes`,
`workflow-job`, `workflow-cps`, `workflow-basic-steps`, `workflow-durable-task-step`,
`workflow-scm-step`, `pipeline-stage-step`, `git`, `credentials-binding`, `job-dsl`)와
그 전이 의존성을 합쳐 58개 전부를 정확한 버전으로 고정한다. 버전은
`https://updates.jenkins.io/stable/update-center.actual.json`의 core `2.568.1` 기준선에서
해석했고 모든 항목의 `requiredCore`가 2.568.1 이하다. init container가
`jenkins-plugin-cli --latest=false`로 이 목록만 설치하므로 전이 의존성이 조용히
올라가지 않는다. 권한 모델은 core 전략으로 충분해 `matrix-auth`를 넣지 않았다.

## 시크릿 경계

사람이 보관하는 입력은 저장소 밖 `$KTC_SECRET_ROOT/jenkins/env` mode `0600` 하나이며
`JENKINS_ADMIN_PASSWORD` 한 key만 담는다. Gitea deploy key, Harbor robot credential과
pinned host key는 `provision.sh`가 만들어 Vault로 직접 옮기고 이 파일에 남기지 않는다.
저장소 안 `.env`, Kubernetes Secret, cluster-wide injector, CSI와 Secret 동기화 operator는
사용하지 않는다. 패턴과 재검토 조건은 [ADR-0013](../../../docs/adr/0013-keycloak-secret-consumption.md)을 따른다.

controller Pod의 명시적 Vault Agent init container가 `audience=vault` projected token으로
`jenkins` role에 로그인해 `kv/jenkins/runtime`의 다섯 값을 memory `emptyDir`에 mode `0400`
파일로 렌더링하고 종료한다. 파일 이름이 곧 JCasC 변수 이름이며 controller는
`SECRETS=/vault/secrets`로 이를 읽는다.

| 파일 = JCasC 변수 | 쓰임 |
|---|---|
| `jenkins_admin_password` | local 복구 admin |
| `gitea_ssh_private_key` | read-only deploy key |
| `gitea_known_hosts` | Gitea SSH host key 고정 |
| `harbor_robot_name` / `harbor_robot_secret` | project-scoped push robot |

상시 Jenkins container에는 Vault용 token이 없다. kubernetes plugin이 쓰는 API token은
kubelet 자동 마운트가 아니라 별도 projected volume이며 기본 audience라 `audience=vault`인
Vault role이 거부한다. 그 RBAC는 `jenkins` namespace의 Pod·pods/exec·pods/log·events뿐이고
Secret, ServiceAccount, cluster 범위 자원은 없다.

## 기존 경계를 되돌리지 않는 접근 경로

- **Gitea**: `SCM-01`이 HTTP Git을 껐다. clone은 cluster 내부
  `ssh://git@gitea-ssh.gitea.svc.cluster.local:2222/...`만 쓰고 repo 하나에만 붙은
  read-only deploy key로 인증한다. 경로 분리 방식은
  [`../renovate/README.md`](../renovate/README.md)를 따른다. host key는 Gitea Pod가 이미
  소유한 공개키를 JCasC `manuallyProvidedKeyVerificationStrategy`로 고정하며
  `known_hosts` 파일에 의존하지 않는다.
- **Harbor**: `REG-01`이 만든 경계 그대로 `/v2/`는 Pomerium을 우회해 Harbor가 직접
  인증한다([`../harbor/README.md`](../harbor/README.md)). push는 `ci01-evidence` 하나에만
  pull/push 권한이 있는 project-scoped robot만 쓴다. Harbor local admin, 다른 project
  권한과 system robot은 사용하지 않는다.
- **Pomerium**: browser UI만 정확한 `claim/groups=/platform-users` Route 뒤에 둔다.
  로그인 성공·email fallback은 없다. agent의 inbound JNLP는 이 Route를 쓰지 않고 cluster
  내부 `Service/jenkins-agent:50000`만 쓴다.
- **NetworkPolicy**: `POL-01` 기준선은 `pomerium` namespace에만 default-deny를 둔다.
  이 작업은 [`../pomerium/jenkins-egress.yaml`](../pomerium/jenkins-egress.yaml)의 필요한
  egress(TCP 8080) 한 건만 추가하고 다른 namespace 정책은 만들지 않는다.
- **OPNsense**: 내부 Unbound alias 한 건만 별도 승인 뒤 지원 API로 추가한다. 공개 DNS,
  NAT와 새 방화벽 규칙은 이 작업에 없다.

## 준비와 적용

```bash
export KTC_SECRET_ROOT=/home/imcherry/secrets/ktcloud4-bean
python3 gitops/tools/ci-01/prepare-secret-input.py --output "$KTC_SECRET_ROOT/jenkins/env"
gitops/tools/ci-01/provision.sh --check
gitops/tools/ci-01/provision.sh --apply
```

`provision.sh`는 저장소 밖 동적 객체만 소유하며 absent 상태에서만 만든다.

1. Gitea `scm-recovery/ci01-build-smoke` private repo와 `Jenkinsfile`·`Containerfile`·`app.sh` seed.
2. 그 repo 한 곳에만 붙는 read-only deploy key와 Gitea가 이미 소유한 SSH host key 고정.
3. Harbor `ci01-evidence`·`ci01-denied` private project와 `ci01-evidence` 전용 push/pull robot.
4. Vault `jenkins` policy, `audience=vault` Kubernetes auth role, `kv/jenkins/runtime`.

중간에 실패하면 그 실행이 만든 것만 되돌린다. `--destroy`는 위 네 가지만 제거하고
다른 repo·project·Vault 경로는 건드리지 않는다.

승인된 `OPNSENSE-LIVE` 변경은 alias 한 건뿐이다.

```bash
python3 gitops/tools/ci-01/opnsense-alias.py --env-file "$KTC_SECRET_ROOT/opnsense/env" check
# 승인 뒤
python3 gitops/tools/ci-01/opnsense-alias.py --env-file "$KTC_SECRET_ROOT/opnsense/env" apply
infra/opnsense/scripts/check-drift.sh --update
```

## 동기화 순서

| wave | 리소스 | 성공 조건 |
|---|---|---|
| `-3` | Namespace | 전용 namespace 생성 |
| `-2` | ServiceAccount·Role/RoleBinding·trust/Vault/JCasC/plugin/agent ConfigMap | 비밀 없는 identity와 선언 준비 |
| `-1` | ClusterIP Service 2개 | UI upstream과 agent JNLP 경계 분리 |
| `0` | PVC·Deployment | Vault init 종료, 고정 플러그인 설치, JCasC 적용 후 controller Ready |

정상 `platform-root`와 child Application은 `targetRevision: main`이다. merge 전에는
`AGENTS.md`의 `ARGO-ROOT` 잠금 아래 최신 `origin/main`에 rebase한 설정 commit과, child만
그 SHA로 고정하는 pointer commit을 나눈다. `platform-root`는 pointer commit을 가리키고,
검증이 끝나면 성공·실패와 무관하게 시작 main SHA로 되돌린다. 최종 선언의 child
`targetRevision`은 `main`이다.

## 완료 증거

```bash
gitops/tools/ci-01/verify-live.sh
gitops/tools/ci-01/check-capacity.sh
```

`verify-live.sh`는 `ci01-image-build` pipeline을 한 번 실행해 백로그의 세 항목만 판정한다.

1. **비밀 마스킹** — pipeline이 robot secret을 일부러 stdout으로 흘린다. 콘솔 로그에
   마스킹 표기가 있고, 콘솔·controller·agent 각 container 로그 전체에서 robot secret,
   local admin 암호, deploy key 본문의 평문이 0건이어야 한다.
2. **비특권 agent** — 실행 중인 agent Pod spec을 한 번 조회해 `runAsNonRoot=true`,
   비-0 `runAsUser`, 모든 container의 `allowPrivilegeEscalation=false`,
   `privileged` 부재, `capabilities.drop=[ALL]`과 `SYS_CHROOT` 외 add 없음,
   hostPath·Docker socket·ServiceAccount token 부재를 확인한다. 같은 경계를 두 번째
   방법으로 다시 확인하지 않는다.
3. **이미지 build/push** — Gitea SSH clone → rootless buildah build → `ci01-evidence`
   push 성공을 Harbor API의 artifact digest 일치로 확인하고, 같은 robot의 `ci01-denied`
   push 거부와 그 project의 repository 0건을 대조한다.

Vault Agent 패턴 자체, Pomerium claim 동작, Harbor robot 권한 모델과 Gitea SSH 경로는
`VAULT-02`·`POM-01`·`REG-01`·`SCM-01`이 이미 판정한 경계라 다시 시험하지 않는다.

### 2026-08-02 라이브 검증 (build 6)

- **비밀 마스킹**: pipeline이 robot secret을 stdout으로 흘렸고 콘솔에는 `printf %s ****`만
  남았다. 콘솔, controller 로그, agent `jnlp`/`buildah` 두 container 로그를 포함한 6개 파일
  전체에서 robot secret·local admin 암호·deploy key 본문의 평문은 **0건**이었다.
- **비특권 agent**: 실행 중 Pod `ci01-buildah-g772m`을 한 번 조회했다.
  `runAsNonRoot=True`, `runAsUser=1000`이고 volume은
  `buildah-config:configMap`, `buildah-home:emptyDir`, `workspace-volume:emptyDir`뿐이다.
  `jnlp`는 `allowPrivilegeEscalation=False`·`privileged=False`·`drop=[ALL]`·`add=[]`·
  `seccomp=RuntimeDefault`, `buildah`는 같은 값에 `add=[SYS_CHROOT]`·`seccomp=Unconfined`다.
  build 셸의 실제 uid는 `1000`이고 Docker socket은 `absent`였다.
- **이미지 build/push**: Gitea SSH clone 뒤 `ci01-evidence/ci01-app:b6`을 push해 digest
  `sha256:85c4777e135cc1015e12c4bdda37771d752f8b31df4dad276da3dfe0b7e67dc0`가 Harbor
  artifact와 일치했다. 같은 robot의 `ci01-denied` push는 `authentication required`로
  거부됐고 그 project의 repository는 0건이다.
- **capacity**: `k3s-01` available `11,603MiB`·swap 0·root `13%`, PVC 요청 합계
  `65.125GiB`, Proxmox available `28,845MiB`·swap 0, thin `5.10%/0.40%`,
  DiskPressure `False`로 모든 정지 기준 밖이라 **GO**다. RAM은 12 GiB 경고선 아래이므로
  다음 배포 전에 이 값을 먼저 본다.
- **경로**: `jenkins.imcherry5778.xyz`는 Unbound alias로 `10.10.20.10`을 반환하고 Traefik이
  Let's Encrypt 인증서(`CN=jenkins.imcherry5778.xyz`, 만료 2026-10-31)를 제공하며 Pomerium
  sign-in `302`로 막는다.
- **Argo**: 검증 설정 SHA `f58b0b30a7c2bbcf7ac3412ad83dbe340ffc6107`와 root pointer
  `4e47edb00e5d160b7afaaebe62344046c2a90112`에서 root·Jenkins·Pomerium이 `Synced/Healthy`였다.
  시작 main은 `58459932387eb9b72470f55904b1aeeded19015b`이고 최종 child 선언은 `main`이다.

## rollback

검증이 실패하면 먼저 Pod 로그, pipeline 콘솔과 API 응답에서 실패 지점을 특정한다.
추정으로 securityContext, capability나 storage 설정을 바꾸지 않는다.

1. `platform-root`를 기록한 시작 main SHA로 되돌린다.
2. root의 reconcile을 잠시 멈추고 AppProject가 있는 상태에서 `Application/jenkins`를
   foreground 삭제한다. child와 `jenkins` namespace 부재를 확인한 뒤 reconcile을 재개한다.
   `AppProject/jenkins`는 `Prune=false`라 이 시점의 root는 `OutOfSync/Healthy`가 정상이다.
3. root가 더 이상 선언하지 않는 `AppProject/jenkins`만 명시적으로 삭제하고 hard refresh해
   root의 `Synced/Healthy`를 확인한다.
4. `provision.sh --destroy`로 Gitea repo/deploy key, Harbor project 2개와 robot,
   Vault policy/role/KV만 제거한다.
5. alias를 적용했다면 `opnsense-alias.py ... rollback`으로 이 작업의 exact UUID만 지우고
   Unbound를 재구성한 뒤 `check-drift.sh --update`를 실행한다.

`jenkins` PVC 삭제와 live DNS rollback은 이 작업이 만든 정확한 대상에만 수행한다. 다른
Application, Gitea repository, Harbor project, Vault path와 DNS record는 건드리지 않는다.
Traefik·Vault seal/Raft·방화벽은 rollback 대상이 아니다.
