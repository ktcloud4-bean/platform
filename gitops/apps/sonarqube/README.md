# SonarQube Community Build GitOps 기준선

이 디렉터리는 `QUALITY-01`의 SonarQube Community Build 단일 인스턴스를 소유한다.
내장 H2, Helm chart의 내장 PostgreSQL, 공개 scanner endpoint, 플러그인과 Kubernetes
Secret은 사용하지 않는다. 이미지와 scanner 근거는 [`release-metadata.env`](release-metadata.env)에
고정한다.

## 배치와 상태 경계

```text
browser -> Traefik -> Pomerium claim/groups=/platform-users
        -> SonarQube SAML -> Keycloak platform realm

temporary scanner Job -> ClusterIP Service/sonarqube:9000 -> SonarQube
                      -> project analysis token (Vault Agent init)

SonarQube -> PostgreSQL postgres-01:5432/sonarqube
         -> sslmode=verify-full, role=sonarqube_user
```

관계형 원본은 `postgres-01`의 전용 `sonarqube` DB다. `sonarqube_user`는 login과 자기
DB·schema 사용 권한만 가지며 superuser, createdb, createrole, replication, bypassrls는
모두 끈다. JDBC는 `postgres-01.imcherry5778.xyz`와 저장소의 공개 trust anchor로
`sslmode=verify-full`을 강제한다. 30 GiB PVC는 내장 Elasticsearch index만 보관하며 DB
dump를 대신하지 않는다.

Pod는 3 GiB를 request하고 4 GiB에서 제한한다. 내장 Elasticsearch의 Linux host 요구값
`vm.max_map_count=524288`은 privileged init container로 바꾸지 않고
`infra/ansible/roles/k3s_baseline`의 `/etc/sysctl.d/99-sonarqube.conf`가 소유한다. k3s나
Traefik 재기동은 필요하지 않다. 배포 전후 `k3s-01` guest available RAM을
`docs/capacity-plan.md`의 경계로 판정한다. 12 GiB 미만은 WARN, 8 GiB 미만은 STOP이다.

## UI와 scanner API 분리

`https://sonar.imcherry5778.xyz`의 모든 외부 browser 요청은 Pomerium에서
`claim/groups=/platform-users`를 확인하며 email·로그인 성공 fallback은 없다. 이어
SonarQube가 Community Build에 내장된 SAML로 Keycloak을 다시 확인하고
`platform-users` group을 동기화한다. 별도 인증 플러그인은 추가하지 않는다.

Scanner는 SAML redirect, browser cookie와 대화형 MFA를 수행할 수 없으므로 이 hostname을
쓰지 않는다. `QUALITY-01`의 작은 검증 Job만 cluster 내부
`http://sonarqube.sonarqube.svc.cluster.local:9000`에 project-scoped analysis token으로
접속한다. token은 `kv/sonarqube/verification`에서 명시적 Vault Agent init container가
메모리 `emptyDir`로 렌더링하고 scanner 시작 직후 삭제한다. 외부·노드 포트와 Pomerium
bypass route는 만들지 않는다. Jenkins 연동은 `CI-01`의 별도 범위다.

## 비밀과 복구 인증

사람이 보관하는 입력은 저장소 밖
`${KTC_SECRET_ROOT:-/home/imcherry/secrets/ktcloud4-bean}/sonarqube/env` 한 파일이며 mode는
`0600`이다. 여기에는 DB 암호와 local `admin` 복구 암호만 둔다. 런타임 DB 암호는
`kv/sonarqube/runtime`에서 `ServiceAccount/sonarqube`와 audience `vault`에 묶인 명시적
Vault Agent init container가 읽는다. cluster-wide injector, CSI, Secret 동기화 operator와
저장소 안 `.env`는 금지한다.
렌더 파일은 main container 재시작 때도 사용할 수 있도록 Pod 수명 동안 mode `0440`
메모리 `emptyDir`에만 유지하며 Pod 삭제와 함께 사라진다.

Keycloak·Pomerium 장애 때 local `admin`은 공개 hostname을 통과하지 않는다. trusted SSH로
다음처럼 loopback port-forward를 열고 저장소 밖 암호로 로그인한다.

```bash
ssh -L 19000:127.0.0.1:19000 rocky@k3s-01.imcherry5778.xyz \
  'sudo /usr/local/bin/k3s kubectl -n sonarqube port-forward service/sonarqube 19000:9000 --address=127.0.0.1'
SONAR_URL=http://127.0.0.1:19000 gitops/tools/quality-01/verify-sso.sh
```

이 경로는 복구용이며 Ingress, NodePort나 별도 DNS로 노출하지 않는다.

## 선언과 동기화 순서

| wave | 리소스 | 성공 조건 |
|---|---|---|
| `-3` | Namespace | 전용 namespace 생성 |
| `-2` | ServiceAccount·공개 trust/agent/script ConfigMap | 비밀 없는 identity와 trust 준비 |
| `-1` | ClusterIP Service | 내부 HTTP 경계 준비 |
| `0` | PVC·Deployment | WaitForFirstConsumer 바인딩, Vault init 종료 후 SonarQube `UP`·Ready |

정상 `platform-root`와 child Application은 `targetRevision: main`이다. merge 전에는
`AGENTS.md`의 `ARGO-ROOT` 잠금 아래 최신 `origin/main`에 rebase한 commit SHA만 임시로
가리킨다. 검증 종료 시 성공·실패와 무관하게 시작 main SHA와 최종 `main` 선언으로
복귀한다.

## 준비·완료 증거

저장소 루트에서 다음 순서만 실행한다. 완료 판정은 백로그의 다섯 항목을 넘겨 확장하지
않는다.

```bash
gitops/tools/quality-01/init-env.sh
gitops/tools/quality-01/provision.sh --check
gitops/tools/quality-01/provision.sh --apply

# child가 Ready인 동안 loopback port-forward를 별도 셸에서 유지한다.
SONAR_URL=http://127.0.0.1:19000 gitops/tools/quality-01/configure-sonarqube.sh --apply
SONAR_URL=http://127.0.0.1:19000 gitops/tools/quality-01/verify-analysis.sh
SONAR_URL=http://127.0.0.1:19000 gitops/tools/quality-01/verify-restore.sh
SONAR_URL=http://127.0.0.1:19000 gitops/tools/quality-01/verify-sso.sh
gitops/tools/quality-01/check-capacity.sh
```

`verify-analysis.sh`는 명시적인 `coverage < 80%` 단일 gate 정의를 연결한
`quality01-pass`와 `quality01-fail` 작은 JavaScript project를 분석해 기록·통과·실패를
대조하고 Job과 sample ConfigMap을 제거한다. `verify-restore.sh`는 primary DB dump를 별도 DB와
별도 SonarQube Pod/PVC에 한 번 복원해 두 project와 분석을 조회한 뒤 복원 DB·role·Pod·PVC,
Vault 임시 policy/role/KV와 dump를 제거한다. `verify-sso.sh`는 실제 browser로 허용 사용자와
권한 없는 group을 같은 배포에서 대조하고 local admin 복구 로그인을 확인한다.

### 2026-08-02 라이브 검증

- 배포 전 `k3s-01` guest available은 19.58 GiB여서 12/8 GiB 경고·정지선 밖이었다.
- 작은 JavaScript 분석은 `quality01-pass`에 `2026-08-02T08:50:21Z`,
  `quality01-fail`에 `2026-08-02T08:50:35Z`로 기록됐다. 동일한
  `coverage < 80%` gate에서 전자는 `OK`, 후자는 `ERROR`였다.
- primary DB dump를 별도 DB·Pod·PVC에 복원해 두 project의 같은 최신 분석 시각을
  조회했다. 복원 전 steady-state 가용 RAM이 11.92 GiB였으므로 primary Pod만 잠시
  중지해 15.12 GiB를 확보했으며, 검증 뒤 복원 DB·role·Pod·PVC·Vault 임시 자원과
  dump를 제거하고 primary를 1 replica `Ready`로 되돌렸다.
- 실제 browser에서 `imcherry`의 Pomerium 허용과 Keycloak SAML SonarQube session을
  확인하고, 허용 group이 없는 `imcherry-admin`은 같은 시점 Pomerium `403`이었다.
  내부 SSH port-forward의 local `admin` 복구 login도 `valid=true`였다.
- 배포 직후 `k3s-01` guest available은 12,895 MiB, SonarQube Pod는 2,669.42 MiB,
  PVC 요청 합계는 45.125 GiB였다. guest swap 0, root 11%, Proxmox available
  28,947 MiB·swap 0, thin data/metadata 4.77%/0.39%로 정지 기준을 넘지 않아
  최종 판정은 **GO**다.
- 검증 설정 SHA `2a25b12c05c0a29989df6336f80e49ca0b779536`와 root pointer
  `319c6aae82677f66860877bdc41e5e0b4bc935cc`에서 root·Pomerium·SonarQube가
  `Synced/Healthy`였다. 시작 main은
  `430ee4af8435f3df8329deeea030ca80e6e4a012`이며 최종 child 선언은 `main`이다.

## rollback

검증 실패 시 먼저 Pod log·응답·DB 상태로 실패 지점을 특정한다. Elasticsearch 기동 실패를
추정으로 sysctl·RAM·권한 변경하지 않는다.

1. `platform-root`와 `pomerium`/`sonarqube` child를 기록한 main SHA로 돌리고 sync한다.
2. 이 작업이 새로 만든 SonarQube namespace/PVC, `sonarqube` DB/role, Vault KV/policy/role과
   Keycloak client만 정확히 제거한다.
3. `opnsense-alias.py ... rollback`으로 이 작업의 exact alias UUID만 지우고 Unbound를
   재구성한 뒤 `check-drift.sh --update`를 실행한다.
4. SonarQube Pod가 없는 것을 확인한 뒤 k3s 노드에서
   `/etc/sysctl.d/99-sonarqube.conf`를 제거하고 `vm.max_map_count`를 사전값으로 되돌린다.

새 PVC·DB 삭제와 live DNS/sysctl rollback은 작업 승인 범위의 정확한 대상에만 수행한다.
다른 Application, PostgreSQL DB, Vault path, DNS record와 node 설정은 건드리지 않는다.
