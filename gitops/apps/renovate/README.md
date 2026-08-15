# Renovate GitOps 기준선

이 디렉터리는 `UPDATE-02`의 실제 권위 저장소(`ktcloud4-bean/hr-system`) 의존성 PR 자동화를 소유한다. 상주 서비스나 UI가
아니라 매주 한 번 실행되는 `CronJob`이며, Kubernetes Secret, PVC, 공개 Route, 자동 merge, package script 실행은
금지한다.

## API와 Git 전송 경로

Renovate는 GitHub 공식 플랫폼(`platform: github`)을 사용하며 GitHub REST/GraphQL API 및 HTTPS Git 전송을 통한다.

```text
GitHub API / Git HTTPS
Renovate -> https://api.github.com/
         -> Authorization: Bearer <github-token>
```

Renovate 공식 GitHub 플랫폼은 token을 통해 API 요청과 Git operations를 수행한다.
Gitea 및 내부 SSH 설정은 사용하지 않으며, 외부 HTTPS(TCP 443)를 통해 `api.github.com`, `registry.npmjs.org`, `pypi.org`와 통신한다.

## 자격증명과 권한

- GitHub token(`GITHUB_RENOVATE_TOKEN`)은 `ktcloud4-bean/hr-system` 저장소에 한정된 fine-grained PAT(또는 권한 토큰)이다.
- 토큰 원본은 저장소 밖 `$KTC_SECRET_ROOT/renovate/github.env`에 mode `0600`으로 보관된다.
- `gitops/tools/update-02/provision.sh`가 토큰을 Vault `kv/renovate/runtime` (`github_token`)에 주입한다.
- `renovate` ServiceAccount만 Vault Kubernetes auth role에 bind한다. projected token은 `audience=vault`, 600초이며 Vault Agent init container만 마운트한다.
- Vault Agent는 Renovate와 같은 UID 12021로 `github-token`을 memory `emptyDir`에 mode `0400`으로 렌더링하고 종료한다.
- namespace 안 Kubernetes Secret과 cluster-wide injector, CSI, Secret 동기화 operator는 없다.

동적 객체는 다음 도구가 값 없이 메타데이터만 판정한 뒤 관리한다.

```bash
gitops/tools/update-02/provision.sh --check
gitops/tools/update-02/provision.sh --apply
```

## 자동 merge 및 스크립트 실행 차단

Renovate top-level 및 `packageRules` 모두 `automerge: false`, `platformAutomerge: false`, `allowScripts: false`다.
설정과 권한 계층에서 자동 merge 및 임의 script 실행을 원천 차단한다.

## 실행·egress·자원 경계

- `CronJob`은 매주 일요일 03:17 KST에 단발 Job을 만든다. `concurrencyPolicy=Forbid`, 시작 deadline 15분, 성공/실패 history 각 1건, Job backoff 0, active deadline 30분이다.
- 수동 실행은 `kubectl -n renovate create job --from=cronjob/renovate <고유 이름>`으로 같은 Pod template을 한 번만 사용한다. 상주 Deployment나 Service는 없다.
- `repositories`는 `ktcloud4-bean/hr-system` 하나, manager는 `npm`과 `pip_requirements`만 허용한다. autodiscover, onboarding, dependency dashboard, package script 실행은 끈다. branch/PR 동시 한도는 1이다.
- upstream npm/PyPI registry 조회 및 GitHub 통신은 외부 HTTPS를 사용한다. `NET-03`이 허용한 RFC1918 외 TCP 443 bootstrap 경계를 소비할 뿐 OPNsense rule을 조회·변경하거나 새 예외를 만들지 않는다.
- PVC는 0개다. 실행 중 request/limit은 Renovate 100m/256Mi·1CPU/1Gi, Vault Agent 10m/32Mi·200m/128Mi이며 작업 파일은 최대 2Gi `emptyDir`, credential은 1Mi memory `emptyDir`에만 둔다.

## 동기화·라이브 검증·rollback

| wave | 리소스 | 성공 조건 |
|---|---|---|
| `-3` | Namespace | 전용 namespace 생성 |
| `-2` | ServiceAccount·public trust·Vault/앱 config | identity와 runtime input 준비 |
| `0` | CronJob | 예약·수동 단발 실행 준비 |

`gitops/tools/update-02/verify-live.sh`는 완료 증거를 한 번씩만 판정한다.

1. 저장소 선언 일치: `ktcloud4-bean/hr-system` 단일 repo, `npm` 및 `pip_requirements` manager allowlist, onboarding/autodiscover/script/automerge 비활성, concurrent limit 1.
2. CronJob 기반 test Job 실행: Job 완료(`succeeded=1`), GitHub API로 Renovate 실행에 따른 `state=open`, `merged=false` canary PR 확인.
3. Node·Pod·PVC 및 guest 여유를 `capacity-plan.md` 경고/정지 기준에 대조.
4. 검증 후 canary PR/branch 및 test Job 정리.
