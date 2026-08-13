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

Shuffle PVC 합계는 정확히 20 GiB로 `CAP-04`가 잡은 상한과 같다. 이 최초 dashboard 배포에는
orborus·worker가 없었다. 후속 `SOAR-01`은 정적 orborus·worker, 하나의 오프라인 보강 app과
User Input 내부 runtime을 추가하지만 PVC를 추가하지 않는다. 실행 계층의 request 합계는 CPU
`200m`, memory `512Mi`(limit CPU `950m`, memory `1024Mi`)이며 재판정 기준은
[`docs/capacity-plan.md`](../../../docs/capacity-plan.md)의 `SOAR-01` 절이다.

## SOAR-01 실행·승인 경계

`execution.yaml`은 upstream Orborus가 Kubernetes workload 또는 RoleBinding을 동적으로
만드는 경로를 사용하지 않는다. 고정 `creator-all` compatibility RoleBinding은 empty Role만
참조하고, Orborus와 worker ServiceAccount는 필요한 Deployment `list` 외에
create/update/delete 권한이 없다. worker와 보강 app에는 Docker socket·hostPath가 없다.

`soar01-enrichment.yaml`의 보강 app은 IPv4·URL·SHA-256 추출만 한다. shell·subprocess·외부
URL·Kubernetes credential이 없고, 결과 callback은 static worker Service로만 보낸다.
`execution.yaml`의 고정 User Input runtime은 upstream `shuffle-subflow:1.1.0` image를 비특권
8080으로만 실행한다. worker가 생성할 Deployment와 Service를 미리 선언한 것이며, user-input의
subflow·email·SMS 파라미터는 비워 실제 child workflow·외부 알림을 호출하지 않는다.
`BASE_URL`과 workflow의 User Input `backend_url`은 내부 backend가 아니라 Pomerium의 canonical
Shuffle HTTPS 주소다. upstream은 non-empty `backend_url`을 우선하므로 두 값을 함께 고정해
Continue/Abort Form 링크가 사용자 browser에서 같은 보호 Route로 열린다. app Pod는 blank
subflow·email·SMS 때문에 그 주소로 요청을 보내지 않는다.
고정 image의 User Input SDK는 실행 요청의 worker callback 주소로 `self.base_url`을 다시 덮어쓰고,
app은 그것을 Form query에도 넣는다. initContainer는 `/app/app.py`를 `emptyDir`로 복사한 뒤 Form
링크용 `backend_url`을 canonical URL literal로 치환한다. upstream 결과 카드가
`frontend_continue`를 우선 열면 `answer=true` query로 Form이 자동 응답되는 문제가 있으므로, 네
frontend/API 결과 링크도 먼저 answer 없는 수동 Form으로 통일한다. 실제 Continue/Stop callback은
그 Form 버튼을 사람이 눌렀을 때만 생성된다. 결과 callback은 SDK의 internal worker 주소를 그대로
사용한다. 원문이 달라지면 `grep`에서 Pod가 실패하므로 image update가 조용히 이 보정을 무효화하지
않는다.
Shuffle frontend 2.2.1도 같은 image digest의 Form bundle에서 `source_node` query를 승인 callback에
누락한다. frontend initContainer는 정적 site를 `emptyDir`로 복사하고 callback query 한 곳에만
`source_node`를 보존한다. Workflow·승인 link에 포함된 capability나 사용자의 browser cookie는
변경하거나 기록하지 않는다.
같은 bundle은 내부 `shuffle-subflow` runtime으로 실행된 `User Input` 결과의 ↗를 child workflow로
오인해 안내 문구를 workflow ID로 열고 `execution_id=undefined`를 붙인다. 그 결과에 한해 ↗가
이미 생성된 `frontend_no_answer` 수동 Form으로 향하게 보정한다. 이때도 capability는 생성·기록·
변경하지 않고, 사용자가 Form에서 Continue 또는 Stop을 선택하기 전 callback은 없다.
또한 이 SDK는 `User Input` 결과를 `WAITING`으로 남긴 뒤 상위 execution을 `FINISHED`로 표시한다.
Form은 query의 `source_node` 결과가 실제로 `WAITING`인 동안에는 그 상위 상태만으로 Continue/Stop을
비활성화하지 않는다. 다른 종료 상태나 이미 응답된 입력은 upstream 판정을 그대로 따른다.
`gitops/tools/soar-01/provision.py`가 Dashboard의 webhook → 보강 → `User Input` manual 승인
대기를 만든다. 자동 response action은 0건이다.

Wazuh upstream `shuffle` integration은 hook URL을 integration log에 남기므로 사용하지 않는다.
대신 `custom-soar01`이 Vault Agent가 memory volume에 렌더한 URL만 읽어 내부 backend에 전송한다.
URL은 `ossec.conf`나 integration argv에 없으며 Vault field가 없거나 URL 검증에 실패하면 전송하지
않고 종료한다.

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
- **Route와 내부 role을 분리한다.** IAM-01 이후 Pomerium은 `/soar-readers`,
  `/soar-operators`, `/platform-privileged`만 Route에 들이고 일반 `/platform-users`는
  거부한다. Shuffle은 Keycloak 전용 client role을 다시 읽어 reader·user·admin 동작을
  판정한다. Route 통과만으로 Shuffle 권한을 얻지 않는다.

## IAM-01 OIDC 경계

Shuffle `2.2.1`은 OIDC userinfo의 `email` claim을 내부 username으로 쓰고 소문자로
정규화한다. 실제 검증 email을 서비스로 복제하지 않도록 Keycloak `shuffle` client만
`email` claim을 canonical username으로 매핑한다. 따라서 Keycloak의 `Jaeeyun`은 Shuffle
내부에서 `jaeeyun`으로 비교하며, 나머지도 같은 소문자 정규화를 적용한다.

backend의 `SSO_REDIRECT_URL=https://shuffle.imcherry5778.xyz`는 public Authorization Code +
PKCE callback을 고정한다. 이 값이 없으면 upstream이 내부 `BASE_URL`을 redirect URI로 만들어
browser login이 실패한다. backend는 token 교환과 userinfo 조회 때 TLS hostname을 유지하되
노드 외부 443 hairpin 대신 app manifest에 고정한 in-cluster Traefik Service만 사용하고,
그 endpoint만 egress로 허용한다. 조직은
`Platform Security` 하나만 사용하고 하위 조직은 만들지
않는다. `role_required=true`, `SSORequired=false`이며 upstream의 역의미 필드
`auto_provision=true`가 자동 프로비저닝 **off** 최종 상태다. 등록 창 전환과 local recovery
MFA는 `gitops/tools/iam-01/provision.py`가 소유한다.

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
