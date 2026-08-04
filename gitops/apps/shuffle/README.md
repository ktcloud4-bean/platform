# SOAR-DASH-01 Shuffle 엔진·대시보드 단독 배포

이 디렉터리는 단일 노드 `k3s-01`의 Shuffle backend 한 대, frontend 한 대, 전용 OpenSearch
한 대, `shuffle` namespace default-deny NetworkPolicy를 소유한다. Orborus(워크플로 실행
엔진)·worker·앱 커넥터·webhook·알림 연동은 소유하지 않는다 — 이 배포는 로그인해서 열어볼
수 있는 SOAR 대시보드까지만 만들고, 경보 수신→정보 보강→통지→승인 흐름은 후속 `SOAR-01`
범위다. Pomerium Route·NetworkPolicy egress는 `gitops/apps/pomerium` 소유, Unbound alias는
`docs/ip-plan.md`가 단일 원본이다.

버전·이미지 digest의 단일 원본은 [`release-metadata.env`](release-metadata.env)다.
자원 한도의 단일 원본은 [`docs/capacity-plan.md`](../../../docs/capacity-plan.md)의
`SOAR-DASH-01` 절이다.

## 왜 분리 배포인가

공식 Shuffle Helm chart나 Kubernetes manifest는 upstream 저장소(`Shuffle/Shuffle`)에 없다.
`docker-compose.yml`과 `shuffle-docs/configuration.md`를 검토해 이 디렉터리의 선언을
직접 파생했다. `CAP-04`가 이미 Wazuh indexer와 분리한 전용 OpenSearch를 전제로 진입선을
계산해 뒀으므로 그 결정을 그대로 따른다 — 같은 클러스터를 쓰면 Wazuh가 고정한 indexer
버전과 Shuffle의 지원 버전이 묶이고, SOAR가 SIEM의 가용성을 잡는 구조가 된다.

## 배치와 자원

| 구성 | 값 | 근거 |
|---|---|---|
| opensearch | replica 1, `discovery.type=single-node` | 단일 노드 k3s, Wazuh indexer와 완전 분리 |
| opensearch heap | `-Xms1g -Xmx1g` | wazuh-indexer와 동일 관례값 |
| opensearch limit | cpu 1, memory 2Gi | wazuh-indexer와 동일 관례값 |
| opensearch PVC | 16 GiB `local-path` | `CAP-04`가 배정한 Shuffle OpenSearch 몫 |
| backend limit | cpu 500m, memory 1Gi | Go REST API, 워크플로 실행 없음(가벼움) |
| backend PVC(`shuffle-files`) | 4 GiB `local-path` | `CAP-04`가 배정한 file data 몫 |
| backend `shuffle-apps`(hotload) | emptyDir 256Mi | 아직 앱을 hotload하지 않아 영속 불필요 |
| frontend limit | cpu 200m, memory 256Mi | nginx 정적 서빙 + `/api/v(1\|2)` reverse proxy |

Shuffle PVC 합계는 정확히 20 GiB로 `CAP-04`가 잡은 상한과 같다. orborus·worker는 배포하지
않아 추가 RAM·PVC를 쓰지 않는다.

## 보안 결정

- **root 없이 실행한다.** upstream `shuffle-frontend` 이미지는 기본 `nginx.conf.tmpl`이
  포트 80과 443(TLS)을 그대로 바인딩해 root가 필요하다. 이 클러스터의 모든 앱은 Pomerium이
  edge TLS를 종단하므로, [`files/nginx.conf.tmpl`](files/nginx.conf.tmpl)로 upstream
  템플릿을 대체해 TLS server block을 제거하고 평문 listener를 8080(비특권 포트)으로
  옮겼다. 세 컨테이너(opensearch·backend·frontend) 모두 `runAsNonRoot: true`,
  `capabilities.drop: [ALL]`이고 Kyverno `pol-02-*` PolicyException을 새로 만들지 않았다
  (Wazuh manager는 UID 0라 예외가 필요했던 것과 다르다).
- **credential은 Vault Agent만 렌더한다.** OpenSearch admin password(OpenSearch 2.12+가
  요구하는 `OPENSEARCH_INITIAL_ADMIN_PASSWORD`), backend의 `SHUFFLE_ENCRYPTION_MODIFIER`,
  검증용 bootstrap admin 계정(`SHUFFLE_DEFAULT_USERNAME=soar-dash-01-admin`과
  `SHUFFLE_DEFAULT_PASSWORD`)은 Kubernetes Secret 평문 없이 `kv/shuffle/{opensearch,backend}`에서
  각 ServiceAccount 전용 Kubernetes auth role로만 읽는다. backend policy는
  `kv/shuffle/opensearch`를 직접 읽지 않고, opensearch admin password를
  `kv/shuffle/backend`에도 같은 값으로 복사해 둔다(ServiceAccount별 최소권한 분리 유지).
  `gitops/tools/soar-dash-01/provision.sh`가 이 KV·policy·role을 만든다. frontend는 어떤
  credential도 갖지 않는다(순수 리버스 프록시).
- **워크플로·앱 연동은 0건이다.** Orborus를 배포하지 않았으므로 Shuffle이 임의 컨테이너를
  실행할 방법이 이 단계에는 없다. 로그인 후 org를 만들고 화면을 볼 수는 있지만 어떤
  workflow도 실행되지 않는다.
- **접근 등급은 Wazuh와 동일하게 privileged-only다.** SOAR PoC는 대시보드만 있어도
  사고대응 도구로 취급하고 `/platform-users`는 통과시키지 않는다
  (`gitops/apps/pomerium/pomerium-conf.yaml`의 `shuffle` route).

## 알려진 Kubernetes 함정 두 가지

- **`shuffle-backend-files` PVC는 backend Deployment와 같은 sync-wave에 있어야 한다.**
  `local-path`는 `volumeBindingMode: WaitForFirstConsumer`라 PVC를 소비할 Pod가 없으면
  영원히 `Pending`이다. PVC가 더 이른 wave에 있으면 Argo가 "그 wave가 healthy해질 때까지"
  기다리며 정확히 그 Pod를 만드는 다음 wave를 막아 데드락이 된다.
- **emptyDir subPath로 upstream이 이미 파일로 둔 경로(`/etc/nginx/nginx.conf`)를 덮으면
  실패한다.** 빈 emptyDir의 subPath 항목을 kubelet이 디렉터리로 만들어 파일 경로 위
  bind mount가 "not a directory"로 거부된다. `nginx-conf-init` initContainer가 같은
  volume을 subPath 없이 마운트해 빈 파일을 먼저 만들어 둔다.

내부 alias는 이미 있어도(WAZUH-02 등) Pomerium route·NetworkPolicy egress만으로는 부족하다.
`gitops/apps/pomerium/ingress.yaml`의 Traefik host·TLS 목록에 새 hostname을 추가하지 않으면
Traefik이 SNI를 몰라 자체 default cert로 응답해 TLS 검증이 실패한다(신규 hostname마다
Let's Encrypt DNS-01 발급도 새로 필요해 수십 초~수 분 걸릴 수 있다).

## 완료 증거 절차

1. `docs/capacity-plan.md`의 `SOAR-DASH-01` 배포 직전 gate가 GO여야 한다.
2. `gitops/tools/soar-dash-01/provision.sh apply`로 Vault KV·policy·role을 만든다(원문은
   `$KTC_SECRET_ROOT/shuffle/`에만 남는다).
3. Argo child `shuffle`이 `Synced/Healthy`가 될 때까지 기다린다.
4. `gitops/tools/soar-dash-01/opnsense-alias.py apply`로 `shuffle` Unbound alias를 등록한다.
5. `gitops/tools/soar-dash-01/verify-routes.py`로 `/platform-privileged` 계정의 허용과
   `/platform-users`만 가진 계정의 403을 같은 실행에서 대조하고, bootstrap admin
   (`soar-dash-01-admin`)의 Shuffle 자체 `/api/v1/login`이 전체 외부 경로(Pomerium→Traefik
   TLS→frontend→backend)로 성공하는지 확인한다.
6. 배포 후 `k3s-01` available·PVC 합계가 정지선 안인지 재측정한다(`docs/capacity-plan.md`).
7. `kubectl -n shuffle get deploy,sts` 세 워크로드가 모두 `Ready`이고, Argo가 소유한 23개
   Application 전체가 `Synced/Healthy`인지 확인한다.
8. `shuffle-opensearch-0`를 삭제해 StatefulSet이 재생성한 뒤에도 bootstrap admin 로그인이
   그대로 성공하는지 확인해 PVC 데이터 지속을 증명한다.

## rollback

`shuffle` Application을 시작 main SHA로 되돌리면 Deployment·StatefulSet·NetworkPolicy·
namespace가 PVC까지 포함해(신규 namespace라 다른 앱에 영향이 없다) prune으로 함께
제거된다(`shuffle` AppProject는 다른 앱과 동일하게 `Prune=false`라 남으며, 재배포 시
그대로 재사용된다). Vault KV·policy·role은 `provision.sh`가 만든 것과 정확히 반대
명령(`vault kv delete`, `vault policy delete`, `vault delete auth/kubernetes/role/...`)으로만
되돌리고, Unbound alias는 `opnsense-alias.py rollback`으로 되돌린다.
`gitops/apps/pomerium/ingress.yaml`의 `shuffle.imcherry5778.xyz` host·TLS 항목도 함께
제거해야 다른 앱과 이름 형식이 맞는다(제거해도 Traefik이 발급한 인증서 자체는 즉시
폐기되지 않는다). indexer·manager를 포함한 `wazuh` namespace는 이 rollback의 대상이
아니다(별도 앱).
