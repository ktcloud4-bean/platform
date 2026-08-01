# CROWDSEC-FIX-01 검증 증거

이 디렉터리는 `CROWDSEC-01` live 적용에서 발견한 CRS ConfigMap 바이트
훼손과 AppProject prune 순서 결함을 보정하고, ADR-0012의 기능·성능·
장애·rollback gate를 재수행한 결과를 소유한다.

## 2026-08-01 시작 기준선

- branch/worktree: `task/crowdsec-fix-01`, `platform-crowdsec-fix-01`
- 시작 main: `87112193df5e156b4d9038ca3e83f3413ab16b11`
- Argo `platform-root`·`ingress`·`keycloak`: 모두 같은 main SHA에서
  `Synced/Healthy`
- packaged Traefik: generation `5`, Pod UID
  `5e3bd6ee-395f-4459-b4b6-9e358dd4b8c9`, restart `0`, image digest
  `sha256:fcdef599e6259359833dd2e1d49f9e964f66825d69bd3dd468f51102ce013d03`
- CrowdSec Application·AppProject·namespace와 HCC plugin marker: 없음
- Node: `Ready=True`, `DiskPressure=False`; 비정상 Pod 없음

`CROWDSEC-01` 실패 시 원본 CRS 49개는 모두 LF로 끝났지만 Helm template의
YAML `|-` block scalar는 렌더된 ConfigMap value에서 마지막 LF를 제거했다.
결과는 `files=49 mismatches=49`였다. 소스 디렉터리를 bind mount한 기존
Docker 검증은 Kubernetes API 직렬화를 통과하지 않아 이 결함을 놓쳤다.

rollback 중에는 root prune이 `AppProject/crowdsec`를 Application보다 먼저
제거해 Application finalizer가 `project not found`로 멈췄다. 비밀이 없는 Project를
임시 복원한 뒤에야 namespace와 하위 자원을 정상 prune할 수 있었다.

## 승인된 main 3커밋 경계

1. 영구 최소 `AppProject/crowdsec` 기반. Application·HelmChartConfig·workload를
   만들지 않으므로 Traefik을 재기동하지 않는다.
2. byte-preserving snapshot과 수정 enablement. 적용 직전 `KC-01` 상태와
   시점을 다시 확인한 뒤 Traefik을 한 번만 재생성한다.
3. 모든 live gate를 통과한 경우에만 evidence와 `CROWDSEC-FIX-01 DONE`을
   기록한다.

gate 실패 시 2번 enablement 커밋만 `git revert`하고, 1번의 영구
AppProject는 남겨 Application finalizer의 정상 prune 경계를 보장한다.

## 영구 기반 적용 결과

첫 main commit `161debf143d61f8e621ce25b25e601e0c5c207a7` 뒤 Argo
`platform-root`는 해당 SHA에서 `Synced/Healthy`이고 `AppProject/crowdsec` 하나만
생성됐다. CrowdSec Application·namespace는 없으며 Traefik은 generation `5`, Pod UID
`5e3bd6ee-395f-4459-b4b6-9e358dd4b8c9`, restart `0`으로 시작 기준선과 같다.

## byte-preserving 보정과 격리 결과

- source CRS 49개와 기존 manifest를 sorted ustar, mtime 0, owner/group 0, mode 0644,
  `gzip -n -9`로 묶었다. archive는 153,184 bytes이고 SHA-256은
  `235dc3bc50c3c861ba9561487c72d6562e8c6501467314a6618781a37bdaede6`이다.
- 공급망 verifier가 source 49개, manifest, deterministic rebuild, Helm
  `ConfigMap.binaryData`에서 decode한 archive와 AppSec YAML 3개의 byte hash를 확인했다.
  packaged chart는 358,527 bytes로 1MiB 미만이다.
- network 공급망 검증에서 고정 chart/source/plugin archive, Hub YAML과 Hub data
  49개가 기록된 hash와 모두 일치했다.
- Docker 격리에서 fixed CrowdSec image의 실제 `tar`·`sha256sum` init 명령과 packaged
  Traefik `3.7.4`+bouncer `v1.7.1`을 사용했다. 정상 200, rule `913100` 공격 403,
  exact URI+UA 예외만 200, 세 negative 예외 403, control 공격 200, decision 0개,
  AppSec 중단 시 WAF만 403/control 200, 복구 뒤 WAF 200을 확인했다. Traefik은
  running, OOMKilled false, restart 0이었다.
- live packaged chart archive/base values를 읽기만 해 수정 HCC를 격리 렌더했고 plugin
  module/version/hash, `/plugins-storage`, mode 0440 bouncer key mount와 기존 image를
  확인했다.
- `crowdsec-fix-01-verify` 격리 namespace의 실제 Kubernetes API에 ConfigMap을 저장했다.
  API JSON에서 decode한 archive와 AppSec YAML hash, Pod volume mount 뒤 archive와
  추출된 CRS 49개 hash가 모두 일치했다. 첫 실행의 마지막 중복 확인은 BusyBox가 GNU
  `sha256sum --quiet`를 지원하지 않아 실패했지만 Pod의 실제 init과 API hash는 이미
  통과했고 실패 trap이 namespace를 제거했다. 중복 확인을 `sha256sum -c`로 보정한
  두 번째 실행은 전부 통과했고 namespace를 다시 제거했다.
- full Helm render, root와 HCC는 live API server-side dry-run을 통과했다. Secret manifest는
  0개이고 Application targetRevision은 계속 `main`이다.

격리 검증 후 live root·ingress·keycloak은 foundation SHA에서 모두 `Synced/Healthy`,
AppProject는 존재하고 CrowdSec Application·검증 namespace는 없다. Traefik generation
`5`, UID `5e3bd6ee-395f-4459-b4b6-9e358dd4b8c9`, restart `0`도 불변이다.

## 두 번째 enablement 중단과 rollback

적용 직전 live `keycloak` Application은 root·ingress와 함께 foundation SHA에서
`Synced/Healthy`였고, 사용자에게 시점을 다시 확인해 받은 `Y` 뒤에만 enablement를
진행했다. 저장소 밖 mode `0600` 임시 파일에서 bootstrap·bouncer Secret을 주입한 뒤
그 파일은 즉시 shred·삭제했으며 명령 출력에는 이름·key 개수만 남겼다.

두 번째 main commit
`396c92cd90ce170f11aebe4c91adf7e2fa7980b6`에서 다음 경계까지 통과했다.

- root·ingress·keycloak은 같은 SHA에서 `Synced/Healthy`였다.
- HCC generation은 `5 → 6`, Traefik Deployment generation은 `9 → 10`이었다.
- Traefik Pod는 UID `6693d7ee-1911-467e-810e-60b3b8847553`으로 정확히 한 번
  교체됐고 기존 image digest, ready, restart `0`을 유지했다.
- archive 검증·CRS 49개 추출 init과 LAPI bouncer 등록 init은 모두 exit `0`이었다.
  따라서 `CROWDSEC-01`에서 드러난 ConfigMap byte 훼손은 실제 live API 경계에서도
  보정됐다.

그러나 AppSec main container가 사용하는 고정 CrowdSec image의 `/docker_start.sh`는
`prepare_hub()`에서 env와 무관하게 `crowdsecurity/docker-logs`와
`crowdsecurity/cri-logs` parser 설치를 호출한다. 첫 parser 설치가 실패하자
`https://version.crowdsec.net/latest` 조회와 `cscli hub update`를 시도했고 NetworkPolicy가
이를 거부해 exit `1`과 CrashLoopBackOff가 발생했다. rendered chart에는 `PARSERS` env가
없으며 image metadata의 env도 `PATH`뿐이므로 chart 기본값 문제가 아니다. 이는 ADR-0012의
Hub 자동 update 금지와 고정 snapshot만으로 기동해야 한다는 조건을 위반한다. 기존 Docker
격리 시험은 컨테이너 간 network를 분리했지만 외부 egress를 차단하거나 Hub 호출 부재를
assert하지 않아 같은 entrypoint 호출이 외부 통신으로 통과했다.

route가 준비되기 전 실패했으므로 WAF/control 기능, exact rule 예외, p95·CPU·RSS,
AppSec 장애 정책 live gate는 실행하지 않았다. 즉시 enablement commit만 signed revert한
`ed37f6228b2dcd13e63ada8347fa7f94514c495f`를 push했고 Argo hard refresh는 targetRevision을
바꾸지 않고 수행했다.

rollback 뒤 확인 결과는 다음과 같다.

- root·ingress·keycloak은 revert SHA에서 모두 `Synced/Healthy`다.
- HCC generation `7`, Traefik Deployment generation `11`, 최종 Pod UID
  `49afb38c-5bba-467f-9501-e95d36f37598`, 기존 image digest, ready, restart `0`이다.
- CrowdSec Application·namespace·workload·PVC/PV·Secret은 0개다. 영구
  `AppProject/crowdsec`는 남았고 이번에는 Application finalizer prune이 정상 완료됐다.
- ingress 선언 JSON, 인증서 fingerprint
  `60:91:4D:97:DF:E7:E3:49:A6:6E:CC:6E:15:07:D2:3A:0B:A8:AB:22:3C:DF:05:02:44:E9:DF:6B:06:4B:2D:10`,
  path/query 보존 HTTP `301`, HTTPS control `404`가 시작 기준선과 같다.
- 위조 XFF control 요청은 `404`, Traefik `ClientHost=10.10.60.2`였고 ingress HCC의
  `trustedIPs: []`, `insecure: false`가 시작 선언과 같다. Keycloak discovery issuer는
  `https://sso.imcherry5778.xyz/realms/platform`이다.
- Node `Ready=True`, `DiskPressure=False`, k3s active, failed unit 0이다.
- local main과 `origin/main`은 revert SHA로 일치하고 main worktree는 clean이다.

이 시점에는 공개 main에 들어간 enablement에서 새 결함이 발견됐으므로 작업을 `DONE`으로
바꾸거나 evidence commit을 만들지 않았다. 이후 사용자가 이 결함을 별도 FIX ID로 분리하지
않고 `CROWDSEC-FIX-01`의 미완료 live gate로 계속 처리하는 작업별 예외를 명시적으로
승인했다. 전역 AGENTS.md 규칙과 공개 main의 기존 enablement·revert 이력은 바꾸지 않는다.
현재 branch/worktree에서 고정 image의 AppSec startup 경계가 Hub 설치를 실행하지 않도록
보정하고, egress 없는 Docker network·full rendered Pod·실제 Kubernetes startup에서 Hub
요청 0건을 확인한다. 변경된 5항목 live gate를 다시 승인받은 뒤 corrected enablement와
성공 evidence·`DONE`을 순서대로 main에 남긴다.

## offline startup 보정과 BKP-01 재기동 경계

고정 image의 원본 `/docker_start.sh` SHA-256
`ccdd566b08a5ffa57d1b7b205ebc9334a6f58ca097fee0a9837e884977c42824`를 먼저 확인하고,
정확히 한 번 존재하는 `prepare_hub` 호출만 offline marker로 바꾸는 builder를 추가했다.
결과 script SHA-256은
`6b1f168eb4fa5f40ec6b68568b051fb78b43db583fff8107b36bf16d6c5f69b4`다. builder도
`release-metadata.env`의 SHA-256으로 검증하며 source나 결과가 다르면 main container 전에
fail-closed한다. emptyDir에 정확한 결과가 이미 있으면 재사용하고, 다른 byte가 있으면
덮어쓰지 않고 실패하도록 idempotent하게 만들었다.

- Hub 선택 env 여섯 개는 명시적으로 빈 값이고 main container도 offline script hash를
  다시 확인한 뒤에만 실행한다.
- AppSec/LAPI가 연결된 Docker network를 `internal=true`로 만들었다. Traefik만 고정 hash
  plugin 다운로드용 외부 network를 별도로 사용한다.
- egress 없는 Docker 재검증에서 Hub 설치·갱신 요청 0건, 정상 200, rule `913100` 공격 403,
  exact URI+UA 예외만 200, 세 negative 예외 403, control 공격 200, decision 0개,
  AppSec 중단 시 WAF 403/control 200과 복구 200을 모두 확인했다.
- NetworkPolicy selector의 hard-coded `k8s-app=crowdsec`와 격리 release
  `crowdsec-01`의 불일치를 `.Release.Name` 단일 원본으로 보정했다. live release도 root
  Application의 `helm.releaseName`을 verifier가 읽어 Deployment·label을 결정한다.

첫 격리 Kubernetes startup 시험 도중, 다른 세션이 소유한 `BKP-01`이 예정된 k3s
stop/start를 `15:41:11 → 15:41:31 KST`에 수행했다. journal과 전체 namespace의 같은 시각
`SandboxChanged` 이벤트로 확인했으며 CROWDSEC-FIX-01은 k3s를 정지·재시작하지 않았다.
이 전역 재기동이 SSH와 시험을 중단했으므로 해당 실행은 PASS로 인정하지 않는다. 그 과정에서
emptyDir가 보존된 채 init이 다시 실행되는 조건을 발견해 위 idempotency 보정을 추가했다.
임시 namespace와 Secret은 제거했다.

`BKP-01 DONE` main commit `a8b91b155025530f307a606d14fd4e9745c9cfa0` 적용 뒤
root·ingress·keycloak은 같은 SHA에서 `Synced/Healthy`, Keycloak issuer는 200으로
복구됐다. Traefik HCC generation `7`과 Pod UID
`49afb38c-5bba-467f-9501-e95d36f37598`는 같고, 전역 k3s 재기동 때문에 restart count만
`0 → 1`이다. 이를 다음 격리 시험과 corrected enablement의 새 기준선으로 사용한다.

`BKP-01 DONE`과 cluster 복구를 확인한 뒤 격리 Kubernetes startup을 다시 실행했다.
원본·builder·offline script hash가 모두 고정값과 일치했고 AppSec와 LAPI는 ready,
restart `0`이었다. AppSec→LAPI TCP는 성공하고 외부 TCP는 거부됐으며 AppSec/LAPI 로그의
Hub 설치·갱신 요청은 0건, decision도 0개였다. route·Middleware·HCC·PVC는 만들지 않았고
전후 Traefik HCC generation/resourceVersion, Pod UID/imageID/restart count가 같았다. 임시
namespace와 bootstrap Secret은 제거했다. 공급망 network hash, packaged Traefik render와
Kubernetes API CRS 49개 byte round-trip도 이어서 다시 통과했다.

## 세 번째 enablement와 성능 gate 실패

사용자는 offline startup 자산을 포함한 ADR-0012의 다섯 항목과 즉시 적용 시점을 다시
승인했다. 적용 직전 `KC-01`이 main `34135c8fe1a4e49dd551660114e24123e64b8b79`에서
`DONE`이고 root·ingress·keycloak이 모두 `Synced/Healthy`임을 확인했다. 새 기준선은
Traefik HCC generation `7`, Deployment generation `11`, Pod UID
`49afb38c-5bba-467f-9501-e95d36f37598`, k3s 재기동 누적 restart `1`이었다.

corrected enablement `0d6ff16125d49e282f9ea01c765b3dd428f0e5cf`를 signed main
commit으로 push했다. Git 밖 mode `0600` 파일로 bootstrap과 bouncer Secret을 주입하고
원문 파일을 즉시 파기했다. Argo가 같은 SHA로 수렴하면서 HCC `7 → 8`, Deployment
`11 → 12`, Traefik Pod UID `9cb69e4f-452e-41e3-8ee2-43968abddda6`, restart `0`으로
정확히 한 번 교체됐다. LAPI·AppSec·whoami는 모두 Ready였다.

live 기능과 회귀 검증 결과는 다음과 같다.

- 정상 control/WAF `200`, `masscan` rule `913100` 공격 `403`, exact URI+UA 예외 `200`
- 다른 UA, query 추가, 다른 path의 세 negative 예외는 모두 `403`, control 공격은 `200`
- LAPI decision `0`, 기존 ingress object·인증서 fingerprint·HTTP `301` path/query,
  source IP/XFF, root·ingress·keycloak·crowdsec Argo와 전체 Pod health 통과
- 이전 rollback에서 같은 Traefik spec의 ReplicaSet이 남아 있어 새 ReplicaSet을 만들지 않고
  재사용했다. verifier는 새 Pod UID·Deployment generation 증가·현재 owner ReplicaSet의
  desired/current `1`을 확인하도록 보정했다.

성능 gate는 완료 전에 실패가 확정됐다.

| phase | count | failures | p95 |
|---|---:|---:|---:|
| round1-control | 1,000 | 0 | 337.959ms |
| round1-waf | 1,000 | 0 | 336.438ms |
| round2-waf | 1,000 | 0 | 335.974ms |
| round2-control | 1,000 | 0 | 332.626ms |
| round3-control | 1,000 | 0 | 335.271ms |

측정 중 peak Traefik CPU는 `200m`, peak RSS는 `57Mi`, peak Node CPU는 `7%`였고 완료된
5,000개 요청의 실패는 0건이었다. round 1 WAF 증분은 `-1.521ms`, round 2는
`3.348ms`지만 ADR-0012의 WAF 절대 p95 `100ms` 기준을 두 번 초과했다. control과 WAF가
같은 수준이므로 공통 client/DNS/TLS/route 측정 경로의 원인을 별도로 분석해야 하지만,
승인된 gate를 사후 완화하지 않고 round 3 WAF를 195건에서 중단했다. 60초 idle RSS와
AppSec Pod 삭제 장애 시험은 실행하지 않았다.

enablement만 되돌린 signed main commit은
`f4841207ca71901566117a03c3c8998b42bfafef`다. root finalizer가 CrowdSec Application과
namespace를 정상 prune했고 영구 `AppProject/crowdsec`는 유지됐다. ingress hard refresh 뒤
HCC `9`, Deployment `13`, Traefik Pod UID
`30abf3ac-5239-498e-b2e1-e445f17ea9c5`, 기존 image digest, restart `0`, Ready로 복구됐다.
plugin args·volume mount가 사라진 뒤 bouncer Secret을 삭제했다. root·ingress·keycloak은
revert SHA에서 `Synced/Healthy`, CrowdSec Application·namespace·Secret은 없으며 기존
ingress object·HCC spec·인증서 fingerprint·HTTP `301`·HTTPS `404`·Keycloak issuer,
Node Ready·DiskPressure false와 전체 Pod Ready를 기준선과 대조했다.

## 실패로 남은 증거

- 3 round 전체와 60초 idle RSS: 절대 p95 gate 실패로 중단
- AppSec Pod 삭제 live fail-closed: 성능 실패가 먼저 발생해 실행하지 않음
- 성공 상태 유지와 `DONE`: 만들지 않음

## CROWDSEC-PERF-01 보정과 네 번째 적용 승인

`CROWDSEC-PERF-01`은 rollback 상태에서 cold DNS·TCP·TLS와 warmed HTTP/2 요청을 분리했다.
client→ingress RTT 평균이 약 `72ms`인 경로에서 매 요청 새 연결 p95는 약 `337ms`였지만,
지속 연결 10개를 먼저 만들고 첫 transfer를 제외한 1,000건 세 round p95는
`72.517ms`·`72.827ms`·`72.867ms`였다. 실패와 측정 구간 신규 연결은 0이었다. ADR의
WAF 절대 p95 `100ms`, control 대비 증분 `20ms` 기준은 그대로 유지했다.

네 번째 enablement 전 기준 main은
`1b78913e24dfba57501802725c1753e02506c0cc`다. 2026-08-01 17:28 KST에
root·ingress·keycloak은 같은 SHA에서 `Synced/Healthy`, HCC generation `9`, Deployment
generation `13`, Traefik Pod UID `30abf3ac-5239-498e-b2e1-e445f17ea9c5`, restart `0`,
Ready였다. CrowdSec Application·namespace·Secret은 없고 영구 AppProject만 남았다.
Node는 Ready, DiskPressure false였다.

사용자에게 immutable source·license·version·hash, CrowdSec/Hub/CRS snapshot, exact
host/path/rule `913100` 예외, warmed HTTP/2 1,000건×3회와 CPU/RSS/회귀 기준, AppSec
fail-closed와 Argo/Git rollback을 다시 제시했다. 사용자는 `Y`로 이 다섯 항목과 현재
적용 시점을 승인했다. 성공 시 기존 영구 AppProject에 이어 enablement와 live
evidence/`DONE` 두 신규 main commit을 남기며, 실패 시 evidence/`DONE` 없이 enablement만
즉시 signed revert한다.
