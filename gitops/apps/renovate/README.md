# Renovate GitOps 기준선

이 디렉터리는 `UPDATE-01`의 단일 repository 의존성 PR 자동화를 소유한다. 상주 서비스나 UI가
아니라 매주 한 번 실행되는 `CronJob`이며, Kubernetes Secret, PVC, 공개 Route, 자동 merge,
Gitea Actions와 다른 repository 대상은 만들지 않는다.

## API와 Git 전송 경로

Gitea는 `SCM-01`에서 HTTP Git을 껐다. Renovate의 Gitea platform도 이 경계를 되돌리지 않고
API와 Git 데이터를 다음처럼 분리한다.

```text
Gitea API
Renovate -> http://gitea-http.gitea.svc.cluster.local:3000/api/v1/

Git data
Gitea API ssh_url (ssh://git@git.imcherry5778.xyz:30022/...)
  -> Renovate gitUrl=ssh
  -> Git url.<base>.insteadOf 정확 prefix 치환
  -> ssh://git@gitea-ssh.gitea.svc.cluster.local:2222/...
```

Renovate 공식 `gitUrl=ssh`는 platform이 반환한 SSH URL을 사용한다. Renovate 44.6.0은 보안을
위해 process environment의 unsafe `GIT_CONFIG_*`를 Git child에 그대로 상속하지 않으므로
전역 `customEnvVariables`에서만 Git 설정을 허용한다. 그 안의 `insteadOf`는
`ssh://git@git.imcherry5778.xyz:30022/`와 정확히 일치하는 prefix만 내부 Service URL로 바꾼다.
Gitea 설정, HTTP Git, NodePort, 방화벽과 DNS는 바꾸지 않는다. SSH는 bot의 ed25519 key와 Gitea
Pod가 이미 소유한 host public key를 `HostKeyAlias`로 고정해 `StrictHostKeyChecking=yes`로
검증한다.

근거는 [Renovate self-hosted `gitUrl`](https://docs.renovatebot.com/self-hosted-configuration/#giturl),
[전역 `customEnvVariables`](https://docs.renovatebot.com/self-hosted-configuration/#customenvvariables),
[44.6.0 Git 환경 격리 회귀검사](https://github.com/renovatebot/renovate/blob/60259686dfc32d56343bc140751dbc24745de080/lib/util/git/index.spec.ts#L1915-L1975),
[공식 SSH self-hosting 예시](https://docs.renovatebot.com/examples/self-hosting/#kubernetes-for-gitlab-using-git-over-ssh),
[Git `url.<base>.insteadOf`](https://git-scm.com/docs/git-config#Documentation/git-config.txt-urlbaseinsteadOf)다.

## 자격증명과 권한

- Gitea `renovate`는 `restricted=true`, private visibility, non-admin인 전용 local bot이다.
- `scm-recovery/platform-smoke` 한 곳에만 `write` collaborator다. organization 가입, 다른 repo
  collaborator, admin 권한은 없다.
- Gitea PAT scope는 공식 Gitea platform 요구값 중 package 접근을 제외한
  `write:repository`, `read:user`, `write:issue`, `read:organization`만 쓴다. PAT scope 자체는
  repository 이름을 제한하지 못하므로 단일 collaborator가 실제 repository 경계를 닫는다.
- bot의 일회성 bootstrap password, PAT와 SSH private key는 저장소 밖 mode `0700` 임시
  디렉터리에서만 다룬다. password는 PAT 생성 뒤 보존하지 않고 PAT/private key는
  `kv/renovate/runtime`으로 직접 옮긴다.
- `renovate` ServiceAccount만 Vault Kubernetes auth role에 bind한다. projected token은
  `audience=vault`, 600초이며 Vault Agent init container만 마운트한다.
- Agent는 Renovate와 같은 UID 12021로 PAT, SSH private key, pinned known_hosts를 memory
  `emptyDir`에 mode `0400`으로 렌더링하고 종료한다. OpenSSH가 group-readable private key를
  거부하지 않으면서 상시 Renovate container에는 ServiceAccount token을 마운트하지 않는다.
- namespace 안 Kubernetes Secret과 cluster-wide injector, CSI, Secret 동기화 operator는 없다.

PAT 요구 scope의 제품 근거는
[Renovate Gitea authentication](https://docs.renovatebot.com/modules/platform/gitea/#authentication)이
소유한다. 동적 객체는 다음 도구가 값 없이 메타데이터만 판정한 뒤 최초 absent 상태에서 만든다.

```bash
gitops/tools/update-01/provision.sh --check
gitops/tools/update-01/provision.sh --apply
```

입력은 기존 `$KTC_SECRET_ROOT/gitea/env`의 Gitea local recovery password와
`$KTC_SECRET_ROOT/vault-root.token`뿐이다. 둘 다 저장소 밖 caller-owned mode `0600` 일반
파일이어야 한다. 새 bot credential 원문을 위한 별도 장기 파일은 만들지 않는다.

## 자동 merge 이중 차단

Renovate top-level과 npm `packageRules` 모두 `automerge=false`, `platformAutomerge=false`다.
Gitea 쪽 bot도 non-admin이고 대상 repo의 write만 가지므로 설정과 계정 권한 두 계층에서
자동 merge를 막는다. `platformAutomerge` 기본값이 true이므로 false를 생략하지 않는다.
동작 근거는 [Renovate `platformAutomerge`](https://docs.renovatebot.com/configuration-options/#platformautomerge)다.

## 실행·egress·자원 경계

- `CronJob`은 매주 일요일 03:17 KST에 단발 Job을 만든다. `concurrencyPolicy=Forbid`, 시작
  deadline 15분, 성공/실패 history 각 1건, Job backoff 0, active deadline 30분이다.
- 수동 실행은 `kubectl -n renovate create job --from=cronjob/renovate <고유 이름>`으로 같은
  Pod template을 한 번만 사용한다. 상주 Deployment나 Service는 없다.
- `repositories`는 `scm-recovery/platform-smoke` 하나, manager는 npm 하나다. autodiscover와
  onboarding, dependency dashboard, package script 실행은 끈다. branch/PR 동시 한도는 각
  1이다. 검증 재시도를 시간대에 의존시키지 않도록 hourly PR limit은 0이지만 동시에 열린 작업은
  여전히 한 건을 넘지 않는다.
- upstream npm registry 조회는 외부 HTTPS를 사용한다. `NET-03`이 허용한 RFC1918 외 TCP 443
  bootstrap 경계를 소비할 뿐 OPNsense rule을 조회·변경하거나 새 예외를 만들지 않는다.
- PVC는 0개다. 실행 중 request/limit은 Renovate 100m/256Mi·1CPU/1Gi, Vault Agent
  10m/32Mi·200m/128Mi이며 작업 파일은 최대 2Gi `emptyDir`, credential은 1Mi memory
  `emptyDir`에만 둔다.

CronJob 필드의 의미는
[Kubernetes CronJob 문서](https://kubernetes.io/docs/concepts/workloads/controllers/cron-jobs/)를
따른다. 이미지 version·index/amd64/config digest, tag commit, license URL/hash와 Vault Agent
digest는 [`release-metadata.env`](release-metadata.env)가 소유한다.

## 동기화·라이브 검증·rollback

| wave | 리소스 | 성공 조건 |
|---|---|---|
| `-3` | Namespace | 전용 namespace 생성 |
| `-2` | ServiceAccount·public trust·Vault/앱 config | identity와 runtime input 준비 |
| `0` | CronJob | 예약·수동 단발 실행 준비 |

첫 child라 merge 전에는 설정 commit과 pointer commit을 나눈다. 설정 commit의 최종 child
`targetRevision`은 `main`이다. 다음 pointer commit에서 child만 설정 commit SHA로 고정하고,
`platform-root`를 pointer SHA로 전환한다. mutable branch는 어느 Application에도 넣지 않는다.

`gitops/tools/update-01/verify-live.sh`는 완료 증거를 한 번씩만 판정한다.

1. bot PAT로 대상 repo branch 생성 201과 admin API 403을 대조한다.
2. 기존 파일이 없는 smoke repo에 `update01-lodash-smoke` npm alias로 `lodash 4.17.20` 한 건을
   임시 commit하고 CronJob 기반 Job을 한 번 실행해 Renovate PR 정확히 한 건을 확인한다. 이 검증
   alias만 `recreateWhen=always`라 이전 실패에서 닫힌 검증 PR이 재시도를 막지 않는다.
3. Job 종료 뒤 PR이 `open`, `merged=false`인지 확인한다.
4. 같은 실행의 Node·Pod·PVC와 k3s guest 여유를 `capacity-plan.md` 경고/정지 기준에 대조한다.
5. PR을 닫고 Renovate/permission branch를 삭제하며 seed를 revert하고 검증 Job과 로컬 key
   사본을 제거한다. 운영 bot key/PAT는 다음 CronJob 실행에 필요한 장기 credential이라 유지한다.

성공·실패와 무관하게 검증 뒤 `platform-root`를 시작 main SHA로 되돌린다. child Application의
foreground finalizer는 AppProject를 조회하므로 root가 둘을 동시에 prune하면 project 선삭제로
멈출 수 있다. 이를 막기 위해 AppProject에는 `Prune=false`를 두며 rollback은 다음 순서를 지킨다.

1. `platform-root` reconcile을 잠시 멈추고 AppProject가 존재하는 상태에서 child Application을
   foreground 삭제한다.
2. child와 `renovate` namespace가 모두 없어진 것을 확인한다.
3. `platform-root`를 시작 main SHA로 되돌리고 reconcile을 재개한다. project의 `Prune=false` 때문에
   이 시점의 root는 `OutOfSync/Healthy`가 정상이다.
4. root가 더 이상 선언하지 않는 `AppProject/renovate`만 명시적으로 삭제하고 hard refresh한 뒤
   root의 `Synced/Healthy`를 확인한다.

실패하면 이 GitOps rollback까지 확인한 뒤 `provision.sh --destroy`로 단일 collaborator, bot,
Vault KV/role/policy만 제거한다. 성공하면 동적 credential은 유지해 squash main이 재생성한 child가
그대로 사용한다. PVC, Gitea repository, 방화벽·DNS·Traefik·Vault seal/Raft는 rollback 대상이 아니다.
