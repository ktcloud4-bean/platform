# Gitea GitOps 기준선

이 디렉터리는 `SCM-01`의 Gitea rootless 단일 replica, 전용 PVC, ClusterIP HTTP와
NodePort SSH 서비스를 소유한다. PostgreSQL·Vault·Keycloak·Pomerium의 기존 제어면은
재사용하지만 Kubernetes Secret, 자체 PostgreSQL, Gitea Actions와 공개 진입점은 만들지 않는다.

## UI와 Git 데이터 경로 결정

브라우저 OIDC session/cookie는 Git CLI의 clone/push 인증 프로토콜이 아니다. Harbor UI와
registry API를 분리한 `architecture.md`의 원칙대로 다음 경계를 택했다.

```text
브라우저 UI
Client -> Traefik HTTPS -> Pomerium claim/groups=/platform-users
       -> Service/gitea-http:3000 -> Gitea Keycloak OIDC

Git 데이터
Client -> git.imcherry5778.xyz:30022 -> Service/gitea-ssh NodePort
       -> Gitea built-in SSH:2222 -> repository
```

- HTTP Git은 `[repository] DISABLE_HTTP_GIT=true`로 끈다. 로그인 성공이나 email만으로
  Pomerium Route를 허용하는 fallback도 없다.
- SSH는 Gitea가 소유하는 공개키·repository 권한으로 인증한다. clone URL은
  `ssh://git@git.imcherry5778.xyz:30022/<owner>/<repo>.git` 형식이다.
- NodePort는 기존 사설 라우팅 경계 안의 데이터 경로일 뿐 공개 노출이 아니다. 공개 DNS,
  NAT, Cloudflare와 새 방화벽 규칙은 `SCM-01`에서 만들지 않는다.
- CI-01은 같은 클러스터에서 `gitea-ssh.gitea.svc.cluster.local:2222`를 쓸 수 있다.
  브라우저 Route와 SSH data path 어느 쪽도 다른 쪽의 인증을 대신하지 않는다.

검토한 대안은 Pomerium에서 smart HTTP 경로만 제외하는 방식이다. URL 패턴 누락이 OIDC
우회를 만들고 Git credential 경계를 별도로 다시 설계해야 하므로 채택하지 않았다. SSH가
운영 client를 지원하지 못하는 요구가 생길 때만 별도 hostname의 Git HTTP 인증 경계를 새
작업으로 재검토한다.

## 데이터·시크릿·권한

- 관계형 데이터는 `postgres-01`의 `gitea` DB와 `gitea_user` role만 쓴다. role은
  `NOSUPERUSER,NOCREATEDB,NOCREATEROLE,NOREPLICATION`, DB owner/CONNECT와 자기 schema만
  가지며 `infra/ansible/roles/postgres_baseline`이 선언한다.
- Gitea는 `SSL_MODE=verify-full`과 PG-01 공개 trust anchor로 canonical PostgreSQL 이름을
  검증한다. k3s-01에서 TCP 5432 경로는 `NET-03A` 상태를 재검증하거나 수정하지 않는다.
- repository와 앱 파일은 `local-path` 10Gi PVC에 둔다. DB dump와 repository data를 한
  앱 백업 단위로 취급하며, local-path 요청량이 hard quota가 아니라는 stop 기준은
  `docs/capacity-plan.md`가 소유한다.
- 전용 ServiceAccount `gitea`만 Vault Kubernetes auth role에 bind한다. projected token은
  `audience=vault`, 600초이며 Vault Agent init container만 마운트한다.
- Agent는 `kv/gitea/runtime`을 memory `emptyDir`의 `app.ini`와 bootstrap 전용 파일로
  렌더링하고 종료한다. 상시 Gitea container에는 SA token이나 local recovery password,
  OIDC client secret을 마운트하지 않는다.
- UID 100 Vault Agent가 만든 bootstrap 파일은 `0440`으로 GID 1000 bootstrap만 읽는다.
  migration·admin/OIDC 확인 뒤 같은 UID의 전용 cleanup init container가 삭제하고
  부재를 확인한 뒤에만 main을 시작한다.
- Deployment Pod template의 `runtime-config-sha256`은 bootstrap·Vault Agent ConfigMap 내용
  해시다. 두 선언을 바꾸면 해시도 갱신해 init 수렴이 새 Pod에서 반드시 다시 실행되게 한다.
- 메인 container는 rootless image entrypoint의 in-place env rewrite를 실행하지 않고, Vault가
  완성한 read-only `app.ini`를 명시해 `gitea web`을 실행한다.
- cluster-wide injector, CSI DaemonSet, Secret 동기화 operator와 Kubernetes Secret은 없다.
- Keycloak OAuth source도 `required-claim-name=groups`,
  `required-claim-value=/platform-users`를 요구한다. Pomerium과 앱 두 경계 모두 email이나
  인증 성공만으로 자동 허용하지 않는다. Gitea는 표준 `openid profile email` scope만 요청하고,
  전용 Keycloak client에 직접 붙인 protocol mapper가 `groups` claim을 발급한다.
- `scm-recovery`는 Pomerium/Keycloak 장애 때 trusted SSH와 root-only kubeconfig로
  `Service/gitea-http`를 port-forward한 경로에서만 쓰는 로컬 관리자다. 일반 UI entrypoint로
  안내하지 않는다. bootstrap은 계정 존재만으로 완료하지 않고 외부 입력의
  password를 다시 설정해 비밀번호가 없는 기존 local admin도 복구한다.

## 저장소 밖 입력

사람이 제공하거나 SCM-01이 생성해 보존할 입력은 mode `0600` 일반 파일
`$KTC_SECRET_ROOT/gitea/env` 하나뿐이다. `KTC_SECRET_ROOT` 미지정 시
`~/secrets/ktcloud4-bean`을 쓴다. symlink, group/other 권한, 저장소 내부 경로와 아래 키 외의
입력은 거부한다.

```dotenv
GITEA_DB_PASSWORD=<PostgreSQL gitea_user password>
GITEA_LOCAL_ADMIN_PASSWORD=<scm-recovery password>
GITEA_OIDC_CLIENT_SECRET=<Keycloak confidential client secret>
GITEA_SECRET_KEY=<Gitea security SECRET_KEY>
GITEA_INTERNAL_TOKEN=<Gitea INTERNAL_TOKEN>
GITEA_JWT_SECRET=<32 byte raw URL-safe Base64 Gitea OAuth2 JWT secret>
GITEA_WEBHOOK_SECRET=<repository webhook HMAC secret>
```

새 파일은 기존 값을 덮어쓰지 않는 `gitops/tools/scm-01/prepare-secret-input.sh`로 만들고,
적용 전 차이를 분류한다.

```bash
gitops/tools/scm-01/prepare-secret-input.sh
gitops/tools/scm-01/provision.sh --check
gitops/tools/scm-01/provision.sh --apply
```

초기 생성기가 만든 64자 hex JWT를 보정할 때는 credential 교체 승인을 받은 뒤
`repair-jwt-secret.sh`와 `provision.sh --rotate-jwt`를 순서대로 한 번만 실행한다.
보정 도구는 정확히 64자 소문자 hex인 기존 값만 받고, Vault 갱신은 나머지
여섯 필드가 live와 일치할 때만 허용한다.

## 동기화·복구 순서

| wave | 리소스 | 성공 조건 |
|---|---|---|
| `-3` | Namespace | 전용 namespace 생성 |
| `-2` | SA·public trust·Vault config·bootstrap script | identity와 runtime input 준비 |
| `-1` | HTTP ClusterIP·SSH NodePort | UI upstream과 Git data path 분리 |
| `0` | PVC·Deployment | WaitForFirstConsumer 바인딩, Vault render, DB migration, recovery admin/OIDC source 확인 뒤 Ready |

초기 적용은 PostgreSQL role/DB, Keycloak client, Vault policy/role/KV를 먼저 만든 뒤 Argo child를
동기화한다. 실패 rollback은 Pomerium `git` host/Route와 Gitea child를 이전 main SHA로
되돌린다. DB migration이 시작된 뒤에는 이전 minor 버전 선언만 재적용하지 않고, 앱 수준
DB dump와 repository data 복원본으로 판정한다. PVC나 DB 삭제는 rollback 수단이 아니다.

`SCM-01`은 main에 없던 첫 child를 추가하므로 merge 전 검증 종료 순서를 다음처럼
고정한다. 설정 commit에서 새 AppProject를 먼저 적용하고, 다음 pointer commit에서
`gitea`와 변경된 `pomerium` child를 설정 commit SHA로 고정한 뒤 `platform-root`를
pointer SHA로 전환한다. 검증이 끝나면 두 child의 최종 선언을 `main`으로 돌린다.
main에는 아직 Gitea child가 없으므로 root를 기록한 main SHA로 돌리기 직전 라이브
`Application/gitea`의 resource finalizer만 제거해 workload·PVC를 orphan으로 보전한다. 이후
squash main이 재생성한 child가 같은 리소스를 즉시 재채택하게 하며, 검증한 PVC를
삭제했다가 빈 서비스로 재생성하지 않는다. 이 rollback handoff 동안에는 `platform-root`의
reconcile을 skip annotation으로 멈춰 이전 pointer가 finalizer를 되살리는 경쟁을 막고,
root SHA를 되돌린 직후 annotation을 제거한다.

백업/복원 검증은 쓰기를 멈춘 단일 Gitea replica에서 native `pg_dump`와 repository tar를
만들고, 별도 DB·별도 PVC·Ingress 없는 격리 Pod에 복원한다. 복원 앱 API에서 원본 commit을
조회한 뒤 격리 DB/PVC/Pod와 임시 key·hook·receiver를 제거한다. 이는 SCM-01 앱 수준 복구
증거이며 BKP 작업의 S3 보존·오프사이트 복사를 대신하지 않는다.
scale-to-zero 구간에만 `platform-root`와 `gitea` reconcile을 skip annotation으로 멈추고,
EXIT trap은 원본 replica 복구와 두 annotation 제거를 먼저 수행한다.
API 조회는 k3s 호스트에서 Service/Pod IP로 이어지는 단일 SSH tunnel만 사용하고,
이중 `kubectl port-forward`나 임시 Ingress를 만들지 않는다.

라이브 완료 증거는 다음 세 도구가 한 경계를 한 번씩 판정한다.

```bash
gitops/tools/scm-01/verify-push-restore.sh
gitops/tools/scm-01/verify-sso-rbac.sh
gitops/tools/scm-01/verify-webhook.sh
```

`verify-push-restore.sh`는 실제 `platform-smoke` repo의 SSH push commit을 남기되 임시 deploy
key와 격리 DB/PVC/Pod를 제거한다. `verify-webhook.sh`는 CI-01이 따를 repository hook과
HMAC-SHA256 receiver 계약을 양성/음성으로 판정한 뒤 임시 hook/receiver를 제거한다.
`verify-sso-rbac.sh`는 같은 실행의 allow/deny와 platform realm 비활성 중 ClusterIP
port-forward local admin login을 대조하고 realm을 즉시 원복한다.

## 공급망

Gitea `v1.27.1` 공식 rootless image의 multi-arch OCI index digest, 현재 amd64 manifest,
tag commit, MIT license URL/hash, Vault Agent digest와 webhook 검증용 공식 Python image의
version·index/amd64 digest·license 근거는
[`release-metadata.env`](release-metadata.env)가 소유한다. rootless image의 UID/GID 1000,
내장 SSH와 `/var/lib/gitea` 경계를 유지하며 rootful image로 제자리 전환하지 않는다.
