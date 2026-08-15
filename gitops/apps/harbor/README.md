# Harbor registry GitOps 기준선

이 디렉터리는 `REG-01`의 Harbor 2.15.1 배포, 외부 저장소 연결, Pod-local Vault Agent와
registry API/UI 경계를 소유한다. upstream Harbor chart 1.19.1을 그대로 vendoring한 뒤
Kubernetes Secret 대신 명시적 init container를 쓰는 최소 patch를 적용했다. upstream 원문은
[`UPSTREAM-README.md`](UPSTREAM-README.md), 고정 release와 image digest는
[`release-metadata.env`](release-metadata.env)가 소유한다.

## 저장소와 자원 경계

| 데이터 | backend | 자격증명 소비 | k3s PVC |
|---|---|---|---|
| image layer·manifest | `object-01`의 SeaweedFS S3, `harbor-registry` bucket | `reg-01-harbor` bucket-scoped identity | 0 |
| 관계형 상태 | `postgres-01.imcherry5778.xyz:5432/harbor`, `sslmode=verify-full` | `harbor_user` | 0 |
| Redis | in-cluster 단일 replica, 휘발성 | 비밀번호 없음·cluster 내부 전용 | 0 |
| job log | Harbor DB logger | 위 PostgreSQL role | 0 |

registry의 `regionendpoint`는 `https://s3.imcherry5778.xyz:8333`이며 redirect를 끈다.
PostgreSQL과 S3의 공개 bootstrap leaf는 ConfigMap trust bundle일 뿐 비밀이 아니다. registry
data volume은 S3 driver가 사용하지 않는 작은 `emptyDir`이고 local-path PVC를 만들지 않는다.
Harbor 내장 Trivy는 꺼져 있으며 scanner와 gate 판정은 `SCAN-01`만 소유한다.

상시 Pod scheduler request 합계는 CPU 140m·memory 448Mi다. init Vault Agent는 각 Pod에서
상시 container보다 작은 CPU 10m·memory 32Mi이고 완료 뒤 자원을 소비하지 않는다. image layer
예산은 k3s가 아니라 `capacity-plan.md`의 `object-01` 170 GiB 구획에 포함한다.

## 시크릿 경계

사람이 제공하거나 생성하는 REG-01 값의 유일한 입력은
`$KTC_SECRET_ROOT/harbor/env` mode `0600`이다. 저장소 안 `.env`, Kubernetes Secret,
cluster-wide injector, CSI와 Secret 동기화 operator는 사용하지 않는다.

```bash
export KTC_SECRET_ROOT=/home/imcherry/secrets/ktcloud4-bean
python3 gitops/tools/reg-01/prepare-secret-input.py \
  --output "$KTC_SECRET_ROOT/harbor/env"
gitops/tools/reg-01/provision.sh --check
gitops/tools/reg-01/provision.sh --apply
```

`provision.sh`은 기존 상태를 먼저 분류한 뒤 다음 순서만 소유한다.

1. 승인된 `object-01` SeaweedFS volume slot `15`를 선언한다. 실측 volume 상한 `30GB`에서
   Harbor가 5개 volume까지 사용할 수 있게 하며, identity를 건드리지 않고 volume → filer →
   S3만 재시작한다. master와 기존 volume은 유지한다.
2. `postgres-01`에 `harbor_user`와 `harbor` DB를 선언하고 PUBLIC 권한을 회수한다.
3. 기존 SeaweedFS identity를 보존한 채 일회성 `Admin:harbor-registry` identity를 넣어 bucket을
   만든다. 즉시 Admin을 제거하고 `Read/List/Write:harbor-registry`만 남긴다.
4. runtime identity로 전용 bucket 접근 성공과 다른 기존 bucket 접근 403을 대조한다.
5. `kv/harbor/runtime`, read-only `harbor` policy와 `audience=vault` Kubernetes role을 선언한다.

core, jobservice와 registry Pod에는 각각 명시적 Vault Agent init container가 있다. projected
ServiceAccount token으로 `harbor` role에 로그인하고 필요한 key만 memory `emptyDir`에 mode
`0440`으로 렌더링한 뒤 종료한다. 상시 container는 ServiceAccount token을 마운트하지 않고
파일을 읽어 프로세스 환경에 전달한다. 이 패턴과 재검토 조건은 ADR-0013을 따른다.
token-service RSA 키는 renderer가 Harbor가 요구하는 PKCS#1 PEM으로 정규화하며, 기존 입력을
변환할 때 전후 공개키가 같고 다른 KV 값이 모두 같아야만 적용한다. 키 material은 회전하지 않는다.

## UI와 registry API 경로 분리

```text
Browser /, /api/... ── Traefik ── Pomerium claim/groups ── Harbor nginx
OCI /v2/           ── Traefik ──────────────────────────── Harbor nginx
token /service/    ── Traefik ──────────────────────────── Harbor nginx
```

browser UI는 Pomerium route에서 `/platform-users` 또는 `/platform-privileged`의
`claim/groups`만 허용한다. 로그인 성공·email·`authenticated_user` fallback은 없다.

Docker/OCI client의 `/v2/` challenge와 `/service/token`은 Pomerium을 통과하지 않는다.
Pomerium browser cookie/OIDC redirect는 OCI bearer-token protocol과 호환되지 않고 robot/local
Harbor credential을 가릴 수 있기 때문이다. 두 경로는 더 구체적인 Traefik Ingress가 Harbor로
직접 전달하며 Harbor 자체 local/robot 인증이 끝까지 권한을 판정한다. `/api/v2.0` 관리 API는
direct Ingress에 넣지 않아 browser 경계와 함께 Pomerium 뒤에 남는다. 자동 검증은 공개 경계를
넓히지 않고 SSH port-forward로 ClusterIP에 접속한다.

공개 DNS, NAT와 새 방화벽 규칙은 이 작업에 없다. 내부 Unbound alias 한 건만 별도 승인 뒤
지원 API로 추가한다.

```bash
python3 gitops/tools/reg-01/opnsense-alias.py \
  --env-file "$KTC_SECRET_ROOT/opnsense/env" check
# OPNSENSE-LIVE 승인 뒤
python3 gitops/tools/reg-01/opnsense-alias.py \
  --env-file "$KTC_SECRET_ROOT/opnsense/env" apply
infra/opnsense/scripts/check-drift.sh --update
```

## Argo 동기화와 완료 증거

root Application은 vendored chart에 `values-reg-01.yaml`만 적용한다. 최종
`targetRevision`은 `main`이며 mutable 검증 branch를 선언에 남기지 않는다. merge 전에는
`ARGO-ROOT` 잠금 아래 최신 `origin/main`에 rebase한 단일 commit SHA로 `platform-root`와
`harbor`를 전환한다. 실패하면 시작 전에 기록한 main SHA로 둘을 되돌린다. 성공·실패와
무관하게 검증 뒤 main SHA로 원복한다.

branch-only 검증을 rollback할 때 root는 `Application/harbor`를 먼저 prune한다.
`AppProject/harbor`에는 `Prune=false`를 두어 child finalizer가 정확히 Harbor namespace를
삭제할 때까지 권한 경계를 보존한다. Application과 namespace 부재를 확인한 뒤 AppProject를
명시적으로 삭제하고 root의 `Synced/Healthy`를 확인한다.

```bash
gitops/tools/reg-01/verify-live.sh
```

검증기는 백로그 완료 증거 다섯 항목만 실행한다.

- digest 고정 BusyBox를 project-scoped robot으로 push하고 다른 client(Podman)로 pull한다.
- 같은 robot의 지정 project push/pull 성공과 다른 project push 거부를 붙여 대조한다.
- `latestPushedK=1` retention을 dry-run 없이 실행해 `remove` tag 삭제와 `keep` 보존을 확인한다.
- `pg_dump`와 같은 시점의 S3 object inventory로 임시 `harbor-restore` instance를 올리고 같은
  image digest를 pull한다. 복사된 작업 큐의 중복 실행을 막기 위해 복원 jobservice는 0 replica로
  두고, nginx readiness에 필요한 정적 portal은 유지한다. 복원 namespace·DB·dump와 임시 Vault
  namespace binding을 제거한다.
- 복원 검증 자원을 제거한 뒤 `capacity-plan.md` stop 기준과 Harbor PVC 0건을 판정한다.

성능·부하, 재부팅, SeaweedFS versioning/multipart/presigned, PostgreSQL TLS/role 격리는 다시
시험하지 않는다. 각각 이 작업 밖이거나 `S3-01`·`PG-01`에서 이미 판정한 경계다.

## Upstream Proxy Cache 획득 경계 (SUPPLY-03)

ADR-0028에 따라 Harbor를 7대 exact upstream registry에 대한 Proxy Cache 획득 경계로 운영한다.
Proxy Cache는 최종 원본이 아니며, upstream 획득 후 `SUPPLY-04`에서 normal curated project로 승격하여 소비한다.

- `proxy-dockerhub`: `https://hub.docker.com`
- `proxy-quay`: `https://quay.io`
- `proxy-ghcr`: `https://ghcr.io`
- `proxy-gitea`: `https://docker.gitea.com`
- `proxy-kyverno`: `https://ghcr.io` (reg.kyverno.io backend)
- `proxy-k8s`: `https://registry.k8s.io`
- `proxy-public-ecr`: `https://public.ecr.aws`

k3s 워크로드는 proxy cache 프로젝트를 직접 참조하지 않고, normal curated project(`@sha256:`)만 참조한다.
프로비저닝 도구: `gitops/tools/supply-03/provision.py`
라이브 검증 도구: `gitops/tools/supply-03/verify-live.sh`

