# Jenkins CI GitOps 기준선

이 디렉터리는 `CI-01`의 Jenkins controller 배포·동적 Kubernetes build agent 격리,
`SCAN-01`의 Trivy image/config gate·SBOM 저장과 `SIGN-01`의 Cosign 서명·검증을 소유한다.
Docker-in-Docker, privileged container,
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
                              └─ node ── production npm install·test
                              └─ trivy ── read-only DB/checks PVC
                              └─ oras  ── Harbor image digest에 CycloneDX 첨부
                              └─ cosign ── 현재 image/SBOM digest 서명·공개키 검증
                              └─ sonar ── SonarQube ClusterIP quality gate

Trivy DB bootstrap Job/CronJob ── public HTTPS ── 공식 DB/checks OCI repository
                             └─ 1 GiB cache PVC
```

controller는 `numExecutors: 0`이라 build를 직접 실행하지 않는다. 모든 build는
`ci01-buildah` label의 동적 Pod에서 돌고 `podRetention: never`로 build 종료와 함께
사라진다. agent Pod는 ServiceAccount token을 마운트하지 않으므로 Kubernetes API도
Vault도 직접 호출하지 못한다.

## BOARD-DEMO-01 source mirror build

`board-demo-image-build`는 Gitea `ktcloud4-bean/board-app` pull-mirror의 `main`만
read-only deploy key로 checkout한다. 전용 Harbor `board-demo` project robot은 image push·SBOM
첨부·Cosign registry login에만 사용하고, GitHub/Gitea write credential과 Kubernetes deploy
credential은 job에 주지 않는다. 전용 key와 robot credential은 기존 `kv/jenkins/runtime`이 아닌
`kv/board-demo/jenkins`에서 controller Vault Agent가 memory `emptyDir` 파일로만 렌더링한다.
Jenkins Vault role에는 이 path를 읽는 `board-demo-jenkins` policy만 추가한다.

Buildah `1.43.1`은 비특권 단일 UID/GID mapping에서 Dockerfile `RUN`이 보조 그룹을 설정하면
실패한다. 그래서 같은 agent의 digest-pinned Node `22.23.2-alpine` container가 workspace에
`npm ci --omit=dev --ignore-scripts`와 test를 먼저 실행한다. Buildah는 검증된 `node_modules`와
소스 파일을 복사만 하며, privileged·capability·Docker socket을 추가하지 않는다.

## SCAN-01 결정과 근거

### Trivy와 ORAS는 같은 동적 agent의 별도 container

Trivy `0.72.0`과 ORAS `1.3.3`은 각각 공식 image index digest로 고정한다. 2026-03 Trivy
공급망 사고에서 mutable tag가 실제 공격 경로였으므로 version tag만 쓰지 않는다. 근거는
[upstream advisory](https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23)와
[`release-metadata.env`](release-metadata.env)가 소유한다.

scanner를 별도 상시 Deployment로 두지 않고 기존 `ci01-buildah` agent Pod에 `trivy`와
`oras` container를 추가한다. image tar·SBOM은 같은 build workspace로 전달하되 Buildah
storage는 공유하지 않는다. Trivy는 `RuntimeDefault`, capability `drop: [ALL]`, read-only
root filesystem이고 DB PVC도 read-only로 마운트한다. ORAS도 같은 경계이며 Harbor
credential은 gate 통과 뒤 image push와 SBOM 첨부 때만 받는다. 상시 Pod와 새 Service
없이 build가 끝나면 두 container도 함께 사라지는 선택이다.

별도 pipeline stage에서 새 Pod를 만들면 controller RBAC에 Job 생성 권한과 별도 workspace
전달 경로가 필요하다. 같은 agent container는 기존 namespace-scoped scheduler와 workspace를
그대로 쓰므로 권한과 실패 지점이 더 작다.

### 취약 DB는 build와 분리한 6시간 cache refresh

최초 `trivy-db-bootstrap` Job이 `WaitForFirstConsumer` PVC를 bind하고 DB/checks를 준비한 뒤,
`trivy-db-update` CronJob이 공식 `mirror.gcr.io/aquasec/trivy-db:2`와
`trivy-checks:2`를 6시간마다 갱신한다. updater Pod에만 CoreDNS와 RFC1918을 제외한 public
TCP 443 egress를 허용한다. build는 PVC를 read-only로 읽고
`--skip-db-update --skip-check-update`를 사용하며, 마지막 성공 marker가 24시간을 넘으면
외부 fallback 없이 실패한다.

| 대안 | 선택하지 않은 이유 |
|---|---|
| 매 build 공식 DB 다운로드 | 외부 registry 장애·rate limit가 모든 build의 실패 원인이 된다 |
| Harbor DB mirror | 별도 project·동기화 robot·보존 정책을 먼저 운영해야 해 단일 Jenkins scanner보다 상태가 커진다 |
| Jenkins archive/cache만 사용 | build lifecycle과 DB freshness가 결합되고 독립 갱신 실패를 판정하기 어렵다 |

1 GiB PVC를 고른 이유는 DB와 checks bundle만 저장하고 image layer·SBOM은 저장하지 않기
때문이다. 선언 PVC 합계는 65.125 GiB에서 66.125 GiB가 되어 96 GiB 경고선 아래다.
merge 전 root rollback에서는 `Prune=false`·`IgnoreExtraneous`로 cache PVC를 보존하고 최종
main이 다시 채택한다. 작업을 중단해 삭제해야 한다면 PVC 삭제 승인을 별도로 받는다.

### gate와 예외 기준

| 대상 | 실패 조건 | 후속 순서 |
|---|---|---|
| source config/IaC | Trivy config의 `HIGH` 또는 `CRITICAL` misconfiguration | image build 전에 실패 |
| local image tar | fix가 존재하는 `HIGH` 또는 `CRITICAL` vulnerability | Harbor credential과 push 전에 실패 |
| fix가 없는 finding | 보고에는 남기되 이번 gate에서는 실패시키지 않음 | fix가 나오면 자동으로 gate 대상이 됨 |

예외가 필요하면 source repo의 `.trivyignore.yaml`만 사용한다. 각 항목은 `id`, 좁은
`paths` 또는 `purls`, 사유 `statement`, 날짜 `expired_at: YYYY-MM-DD`를 모두 가져야 하며
pipeline preflight가 하나라도 빠진 항목을 거부한다. Trivy는 날짜가 지난 항목을 더 이상
필터링하지 않으므로 다음 build에서 finding이 다시 gate에 들어온다. 전역 ID만 적거나 만료일
없는 예외는 허용하지 않는다.

### SBOM은 Harbor OCI accessory 하나만 사용

gate를 통과한 local image tar에서 Trivy CycloneDX JSON을 만들고, image를 Harbor에 push해
받은 immutable manifest digest에 ORAS Referrers API로
`application/vnd.cyclonedx+json` artifact를 첨부한다. Jenkins archive에는 같은 SBOM을
복제하지 않는다. `SIGN-01`은 이 subject digest와 accessory를 그대로 받아 CycloneDX
predicate의 서명·attestation 대상으로 쓸 수 있다.

## SIGN-01 결정과 근거

1. 라이브 Vault에는 transit mount가 없고 agent Pod에는 Vault·ServiceAccount token이 없으므로,
   hashivault KMS는 engine·policy뿐 아니라 새 token 전달 경계를 요구한다.
2. Vault KV 키쌍은 기존 `kv/jenkins/runtime` → controller Vault Agent → memory `emptyDir` →
   JCasC credential 경로를 그대로 확장해 agent 변경을 Cosign container 한 건으로 제한한다.
3. keyless/Fulcio는 공개 CA 의존이라 제외한다. KV v2 version으로 회전·복구를 실증할 수 있고
   ADR-0013의 소비 경계를 벗어나지 않으므로 새 ADR은 만들지 않는다.

Cosign `3.1.2`의 공식 `-dev` image를 공식 index digest로 고정한다. 기본 image는 UID 65532의
shell-less 정적 image라 Jenkins가 build 동안 container를 유지하고 `sh` step을 실행할 수 없다.
공식 dev variant는 같은 release binary와 `/busybox/sh`·`sleep`을 제공한다. Cosign container는
기존 `ci01-buildah` 동적 agent Pod에만 있고 build 종료와 함께 사라진다. `RuntimeDefault`,
non-root UID 1000, read-only root filesystem, `drop: [ALL]`이며 HOME과 `/tmp`만 memory
`emptyDir`이다. 상시 Deployment·Service·namespace·PVC는 추가하지 않는다.

### 키 소유·회전·복구

| 항목 | 소유·경계 |
|---|---|
| encrypted private key·password | Vault KV v2 `kv/jenkins/runtime`; Git·Kubernetes Secret·workspace disk에 두지 않음 |
| active public key | 같은 KV의 `cosign_public_key`; E2E-01/POL-02는 별도 최소권한 Vault role로 읽어 검증기에 전달 |
| previous public key | 회전·복구 때 current KV의 `cosign_previous_public_key`에 한 세대 보존 |
| negative-test key | 다른 keypair의 공개키만 `cosign_reject_public_key`에 보존하고 private key는 생성 tmpfs와 함께 제거 |
| key id | PEM 내부 줄바꿈은 유지하고 마지막 LF만 제거한 SHA-256; 공개 metadata로만 기록 |

생성·회전·복구는 workstation `/dev/shm`에서 공식 Cosign image를 `--network=none`으로 실행하고,
비밀 원문을 stdout·명령 인자에 내보내지 않는다. 모든 write는 기존 runtime의 비-SIGN 필드를
그대로 보존한 새 KV version이다.

| 단계 | 명령 | 성공 조건 |
|---|---|---|
| 최초 생성 | `gitops/tools/ci-01/provision.sh --signing-key-create` | SIGN 필드가 없을 때만 generation 1 생성 |
| 현재 판정 | `gitops/tools/ci-01/provision.sh --signing-key-check` | encrypted private key에서 유도한 public key가 저장값과 일치 |
| 회전 | `gitops/tools/ci-01/provision.sh --signing-key-rotate` | 새 generation을 current로 쓰고 직전 public key 보존 |
| 복구 | `gitops/tools/ci-01/provision.sh --signing-key-recover <kv-version>` | 지정 version의 keypair 일치 확인 뒤 새 current version으로 복구 |
| 작업 중단 정리 | `gitops/tools/ci-01/provision.sh --signing-key-destroy` | current에서 `cosign_*`만 제거하고 CI-01 다섯 필드는 보존 |

회전 중 consumer는 current와 previous 공개키를 함께 신뢰하고 새 artifact는 current key로만
서명한다. E2E-01/POL-02가 current key를 채택하고 이전 key로 서명된 artifact의 보존 경계가
끝난 뒤에만 previous trust를 제거한다. Vault 전체 장애의 복구는 기존 Raft snapshot과 Shamir
입력 경계를 그대로 따르며, 이 절차는 그 복원 뒤 지정 KV version을 current로 승격하는 단계다.

### 서명·검증과 downstream handoff

`E2E-01`부터 `SIGN01_CASE=pass|reject`도 현재 build의 동적 digest를 쓴다. 과거 SIGN-01 완료
때 사용한 고정 image/SBOM digest는 아래 완료 스냅샷에만 남고 실행 제어값이 아니다.

모든 case는 Gitea checkout과 기존 `quality01-pass` project의 SonarQube quality gate를 먼저
통과한다. `sonar.qualitygate.wait=true`가 실패하면 config/image scan, Harbor credential,
push와 서명에 진입하지 않는다. scanner는 기존 동적 agent의 별도 container이며 ClusterIP와
project-scoped token만 사용한다.

동적 agent가 시작된 직후 같은 `trivy-cache` PVC의 준비 마커가 아직 보이지 않는 짧은
가시성 경쟁이 관측됐으므로 config gate는 updater lock을 먼저 배제한 뒤 최대 60초 동안
비어 있지 않은 기존 마커만 기다린다. 제한 시간이 끝나면 DB를 임의로 갱신하거나 재시도하지
않고 실패한다.

`off`는 기존 SCAN-01 build/scan/push/SBOM handoff까지만 수행한다. `pass`는 그 실행이 Harbor에
올린 image manifest와 CycloneDX accessory digest를 workspace 파일에서 읽어 current key로
각각 서명·검증한다. 같은 build에서 scan 뒤 image config label만 바꾼 별도 digest도 같은
repository에 올리지만 서명하지 않고 E2E admission negative input으로만 넘긴다. `reject`는
현재 build digest를 active key로 서명한 뒤 고정된 다른 공개키로 거부해 `FAILURE`로 끝내며
release handoff는 없다.

signature는 모두 digest-only reference와 `COSIGN_EXPERIMENTAL=1` OCI 1.1 referrer mode를
사용한다. 공개 Fulcio·Rekor·timestamp service는 쓰지 않으므로 sign은
`--tlog-upload=false --use-signing-config=false`, verify는 고정 공개키와
`--insecure-ignore-tlog=true`를 함께 쓴다. registry/auth 같은 다른 실패를 signature 부재로
해석해 재서명하지 않는다.

pipeline에는 GitHub 쓰기 credential과 deploy stage가 없다. `e2e01-release-handoff`의 signed
digest를 작업자가 검증 commit 선언에 넣고 Argo가 그 immutable SHA를 읽는다. namespaced
Kyverno `verifyImages`와 current/previous trust 전달은 [`../e2e-01/README.md`](../e2e-01/README.md)가
소유하고 전역 Enforce·예외는 POL-02가 소유한다.

### SIGN-01 완료 증거 (2026-08-02)

키 소유·회전·복구는 최초 생성 KV version 2/generation 1, 회전 version 3/generation 2,
version 2에서 복구한 새 current version 4/generation 3 순서로 실증했다. 최종
`--signing-key-check`는 encrypted private key에서 유도한 public key와 저장값의 일치 및
key ID `sha256:d8fd0bd410281f1827770b82518ee9738d0a17be6d64021800ceab049c1b1be2`,
`recovered-from=2`를 확인했다.

서명·검증은 pipeline build 6에서 SCAN-01 image와 CycloneDX accessory의 기존 current-key
signature를 각각 재사용해 둘 다 검증하고 release handoff를 냈다. build 7은 같은 image를
negative-test 공개키로 검증해 Cosign의 `accepted signatures do not match threshold`
응답과 함께 의도한 `FAILURE`가 됐으며 서명 추가·scan stage·release handoff는 없었다.
초기 build 4의 OCI 1.1 experimental gate 누락과 build 5의 verify 미지원 option은 각 로그로
원인을 특정한 뒤 고쳤고, build 5가 이미 붙인 유효 signature는 project robot에 delete 권한을
추가하지 않고 build 6에서 재사용했다.

최종 검증 직전 `k3s-01` available RAM은 `11,472MiB`, swap은 0으로 12 GiB 경고 구간이지만
8 GiB 정지선 위의 **GO**였다. Jenkins 설정
`d2e61fd62767b7d01722fb2600dbf936d719cee4`와 root pointer
`06c194aec60afe9fa6eb40a39bb2c94fcb1e90fc`에서 root·Jenkins가
`Synced/Healthy`였다. 시작 main `c05892d1306eb18785525022fa80cea119863b2d`로 rollback한
뒤에도 둘 다 `Synced/Healthy`였고, 최종 child 선언은 `main`이다.

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
`SCAN-01`의 1 GiB Trivy cache를 더해도 `SIGN-01`·`E2E-01`에 29 GiB 이상 여유를 남긴다. 이 PVC는 job 설정, build
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
`jenkins` role에 로그인해 `kv/jenkins/runtime`의 CI-01 다섯 값과 SIGN-01 네 값을
memory `emptyDir`에 mode `0400`
파일로 렌더링하고 종료한다. 파일 이름이 곧 JCasC 변수 이름이며 controller는
`SECRETS=/vault/secrets`로 이를 읽는다.

| 파일 = JCasC 변수 | 쓰임 |
|---|---|
| `jenkins_admin_password` | local 복구 admin |
| `gitea_ssh_private_key` | read-only deploy key |
| `gitea_known_hosts` | Gitea SSH host key 고정 |
| `harbor_robot_name` / `harbor_robot_secret` | project-scoped push robot |
| `cosign_private_key` / `cosign_password` | encrypted signing key와 Cosign key password |
| `cosign_public_key` | active signature 검증과 downstream handoff |
| `cosign_reject_public_key` | 다른 key 거부 시험 전용 공개키 |
| `e2e01_sonar_token` | `kv/e2e-01/jenkins`의 QUALITY-01 pass project token 파생값 |

상시 Jenkins container에는 Vault용 token이 없다. kubernetes plugin이 쓰는 API token은
kubelet 자동 마운트가 아니라 별도 projected volume이며 기본 audience라 `audience=vault`인
Vault role이 거부한다. 그 RBAC는 `jenkins` namespace의 Pod·pods/exec·pods/log·events뿐이고
Secret, ServiceAccount, cluster 범위 자원은 없다.

E2E-01은 기존 `jenkins` Vault role에 `e2e-01-jenkins` policy만 추가한다. 이 policy는 원본
`kv/sonarqube/verification` 전체가 아니라 `kv/e2e-01/jenkins`의 pass token 한 필드만 읽는다.
파생값 갱신과 rollback은 `gitops/tools/e2e-01/provision.sh`가 소유한다.

## 기존 경계를 되돌리지 않는 접근 경로

- **Gitea**: `SCM-01`이 HTTP Git을 껐다. clone은 cluster 내부
  `ssh://git@gitea-ssh.gitea.svc.cluster.local:2222/...`만 쓰고 repo 하나에만 붙은
  read-only deploy key로 인증한다. 경로 분리 방식은
  [`../renovate/README.md`](../renovate/README.md)를 따른다. host key는 Gitea Pod가 이미
  소유한 공개키를 JCasC `manuallyProvidedKeyVerificationStrategy`로 고정하며
  `known_hosts` 파일에 의존하지 않는다.
- **Harbor**: `REG-01`이 만든 경계 그대로 `/v2/`는 Pomerium을 우회해 Harbor가 직접
  인증한다([`../harbor/README.md`](../harbor/README.md)). push는 `ci01-evidence` 하나에만
  pull/push 권한이 있는 project-scoped robot만 쓴다. SCAN-01도 gate 통과 후 같은 robot으로
  image와 그 digest의 SBOM accessory만 쓴다. Harbor local admin, 다른 project 권한과 system
  robot은 사용하지 않는다.
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
gitops/tools/ci-01/provision.sh --signing-key-create
gitops/tools/ci-01/provision.sh --signing-key-check
```

`provision.sh`는 저장소 밖 동적 객체만 소유하며 absent 상태에서만 만든다.

1. Gitea `scm-recovery/ci01-build-smoke` private repo와 `Jenkinsfile`·`Containerfile`·`app.sh` seed.
2. 그 repo 한 곳에만 붙는 read-only deploy key와 Gitea가 이미 소유한 SSH host key 고정.
3. Harbor `ci01-evidence`·`ci01-denied` private project와 `ci01-evidence` 전용 push/pull robot.
4. Vault `jenkins` policy, `audience=vault` Kubernetes auth role, `kv/jenkins/runtime`.

SIGN-01 key mode는 위 네 객체를 새로 만들지 않고 기존 `kv/jenkins/runtime`의 SIGN 필드만
새 KV version으로 관리한다. 기존 CI-01 다섯 값은 byte-for-byte 보존한다.

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
| `-2` | ServiceAccount·Role/RoleBinding·trust/Vault/JCasC/plugin/agent ConfigMap | 비밀 없는 identity와 Cosign 포함 agent 선언 준비 |
| `-1` | ClusterIP Service 2개·Trivy cache PVC/ConfigMap/NetworkPolicy·bootstrap Job | UI·agent 경계 준비, cache PVC bind와 최초 DB 갱신 완료 |
| `0` | PVC·Deployment·Trivy DB CronJob | Vault init 종료, 고정 플러그인/JCasC 적용, 독립 DB 갱신 가능 |

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

## SCAN-01 완료 증거

live 적용 직후 먼저 RAM/PVC stop 기준을 보고, pipeline은 정확히 두 번만 실행한다.

```bash
gitops/tools/scan-01/check-capacity.sh
gitops/tools/scan-01/verify-live.sh
```

1. `pass` build 한 번에서 config gate와 fix가 있는 `HIGH,CRITICAL` image gate 통과를 확인하고,
   같은 image digest의 CycloneDX OCI accessory 한 건을 Harbor API로 판정한다.
2. `fail` build 한 번은 고정 Alpine 3.18.0 입력의 fix가 있는 finding에서 `FAILURE`가 되고,
   해당 build tag와 release handoff marker가 모두 없어야 한다.
3. agent 비특권 spec, credential 마스킹, Gitea/Harbor 인증 경계는 CI-01 완료 증거를 재실행하지
   않는다. 검증기는 build 완료 감지와 local port 선점, 선언형 bootstrap Job 완료를 결정론적으로
   처리한다.

## SIGN-01 완료 증거

적용 직전 RAM 정지선을 먼저 읽고, pipeline은 정확히 두 번만 실행한다.

```bash
gitops/tools/sign-01/check-capacity.sh
gitops/tools/sign-01/verify-live.sh
```

1. `pass` build 한 번은 SCAN-01이 넘긴 image manifest와 CycloneDX accessory digest를 각각
   서명하고 active 공개키로 둘 다 검증한 뒤 release handoff를 낸다.
2. `reject` build 한 번은 같은 image signature를 별도 고정 공개키로 검증해 `FAILURE`가 되고,
   새 서명과 release handoff가 모두 없어야 한다.
3. key lifecycle은 `--signing-key-create` → `--signing-key-rotate` → 최초 KV version의
   `--signing-key-recover` → `--signing-key-check` 한 경로로 판정한다. CI-01 secret masking·
   agent spec, REG-01 robot 권한과 SCAN-01 gate/SBOM 연결은 다시 검증하지 않는다.

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

### SCAN-01 2026-08-02 라이브 검증 (build 2·3)

- **취약점 기준**: build `2`에서 source config와 package가 없는 고정 hello-world base를
  `HIGH,CRITICAL`·fixable-only 기준으로 통과시켰다. Harbor image digest는
  `sha256:50ac62320ee4ebce0da8cb6c05bac072da3c07cb31559487a1f3fb1028a63fe3`이다.
- **SBOM 저장**: 같은 image digest에 CycloneDX JSON OCI accessory
  `sha256:ced6c83cd50d2324bef40f8a4b625fc266bed96c128cf5e01b2bc22c9a0eeb5e`가 정확히 한 건
  연결되고 artifact type이 `application/vnd.cyclonedx+json`임을 Harbor API로 확인했다.
- **실패 pipeline**: build `3`은 고정 Alpine 3.18.0 base의 fix 가능한 `HIGH,CRITICAL`에서
  `FAILURE`가 됐고, 해당 tag와 push stage·release handoff marker는 모두 없었다.
- **capacity**: 배포 직전/직후 `k3s-01` available은 `11,781/11,585MiB`, swap은 0이었다.
  pass agent 실행 중 available은 `11,283MiB`로 배포 직후보다 302 MiB 낮았다. PVC 요청 합계는
  `66.125GiB`이며 Trivy cache 1 GiB를 포함한다. 8 GiB 정지선 위라 **GO**지만 12 GiB 경고
  구간이므로 다음 workload 전 재측정한다.
- **실패와 보정**: build `1`은 image gate 전 local docker archive에 존재하지 않는 registry
  auth file을 강제해 실패했다. archive 단계에서 `REGISTRY_AUTH_FILE`만 해제하도록 고치고 같은
  Buildah image로 오류와 성공을 재현했다. build `2` 뒤에는 Harbor Accessories 목록이 OCI
  artifact type 대신 `subject.accessory`만 주는 응답을 확인해, 연결 digest의 artifact 상세를
  판정하도록 검증기를 고쳤다. 추가 실행은 승인받은 build `2`·`3`뿐이다.
- **Argo와 rollback**: 완료 판정 시 root `ac14432edbf21c546351b04e8307cce057475665`와
  Jenkins 설정 `b1c332df4f52e0f18eda2615a80708b3a3f09b85`가 `Synced/Healthy`였다. 시작 main
  `a3870b2858db269ee28ad3e1c5502ae4820a8979`로 rollback한 뒤 root·Jenkins를 mutable `main`의
  `Synced/Healthy`로 복구했고 최종 child 선언도 `main`이다.

## rollback

검증이 실패하면 먼저 Pod 로그, pipeline 콘솔과 API 응답에서 실패 지점을 특정한다.
추정으로 securityContext, capability나 storage 설정을 바꾸지 않는다.

SIGN-01 branch 검증 rollback은 `platform-root`와 Jenkins seed를 시작 main으로 되돌린다.
기존 CI-01/SCAN-01 workload·PVC·Gitea repo·Harbor project/robot은 삭제하지 않는다. 작업을
중단할 때만 `provision.sh --signing-key-destroy`로 current KV의 `cosign_*` 필드만 제거한다.
성공 뒤에는 main 재채택을 위해 key를 유지한다.

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
