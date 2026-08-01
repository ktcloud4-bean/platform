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

측정 중 peak Traefik CPU는 `200m`, peak working set은 `57Mi`, peak Node CPU는 `7%`였고 완료된
5,000개 요청의 실패는 0건이었다. round 1 WAF 증분은 `-1.521ms`, round 2는
`3.348ms`지만 ADR-0012의 WAF 절대 p95 `100ms` 기준을 두 번 초과했다. control과 WAF가
같은 수준이므로 공통 client/DNS/TLS/route 측정 경로의 원인을 별도로 분석해야 하지만,
승인된 gate를 사후 완화하지 않고 round 3 WAF를 195건에서 중단했다. 60초 idle memory와
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

## 네 번째 enablement의 live gate 경과

실제 적용 직전에는 병렬 작업이 먼저 들어간 최신 `origin/main`
`7ea92d81661b4402be294825b7915b98ae0d687a`를 다시 읽었다. 2026-08-01 17:50 KST 기준
`platform-root`·`ingress`·`keycloak`은 이 SHA에서 `Synced/Healthy`였고, `KC-01 DONE`을
유지했다. CrowdSec Application·namespace·Secret은 없었다. HCC generation `9`,
Traefik Deployment generation `13`, Pod UID
`30abf3ac-5239-498e-b2e1-e445f17ea9c5`, restart `0`, image digest
`sha256:fcdef599e6259359833dd2e1d49f9e964f66825d69bd3dd468f51102ce013d03`을 최종
기준선으로 캡처했다. 인증서 SHA-256, path/query 보존 HTTP `301`, HTTPS `404`, 기존
Ingress·IngressRoute·Middleware spec도 함께 저장했다.

signed enablement commit은
`27db9b352020821b8b5e2cc9a6ab00822d9bcaab`이다. push 전에 저장소 밖 임시 파일에
bootstrap·bouncer 값을 mode `0600`으로 생성해 Secret에 주입했다. 출력은 Secret 이름·
type·key 이름과 개수만 남겼고 원문 파일과 임시 디렉터리는 즉시 `shred -u`와 `rmdir`로
제거했다. Git에는 실제 값이 든 env·Secret manifest·credential literal이 없다. live Secret은
`crowdsec-01-bootstrap` `Opaque` 3 keys와 `kube-system/crowdsec-01-bouncer` `Opaque`
1 key뿐이다.

Argo hard refresh는 `platform-root`의 `targetRevision: main`을 바꾸지 않고 표준 refresh
annotation만 사용했다. root가 CrowdSec Application을 만들고 ingress가 HCC를 반영한 뒤
`platform-root`·`ingress`·`keycloak`·`crowdsec` 모두 enablement SHA에서
`Synced/Healthy`가 됐다. HCC generation은 `9 → 10`, 기존 UID를 유지한 Traefik
Deployment generation은 `13 → 14`로 정확히 한 번 증가했다. Traefik Pod도
`30abf3ac-5239-498e-b2e1-e445f17ea9c5 → 046738f1-1b1a-4709-a0c3-f41d4168420d`로
한 번만 교체됐고 image digest는 같으며 ready, restart `0`이다. k3s server는 이 세션에서
정지·재시작하지 않았다.

### route와 기존 ingress 회귀

| 요청 | 기대·결과 |
|---|---|
| control `/crowdsec-01/control/normal` | `200` |
| WAF `/crowdsec-01/waf/normal` | `200` |
| WAF `/crowdsec-01/waf/attack`, UA `masscan` | rule `913100`, `403` |
| exact `/crowdsec-01/waf/exception`, UA `masscan` | `913100`만 제거, `200` |
| 같은 URI, UA `nmap-nse` | `403` |
| exact URI에 query `variant=1`, UA `masscan` | `403` |
| `/crowdsec-01/waf/not-exception`, UA `masscan` | `403` |
| middleware 없는 control 공격, UA `masscan` | backend 도달, `200` |

위조 `X-Forwarded-For: 203.0.113.77`은 backend에서 제거되고 실제 client
`10.10.60.2`만 `X-Real-Ip`와 `X-Forwarded-For`에 남았다. LAPI decision은 `[]`이고
AppSec·LAPI·whoami Pod는 모두 Ready, restart `0`이다. 최근 20분의 모든 CrowdSec Pod
로그에서 Hub download/update와 CrowdSec online API 일치 항목은 각각 `0`이었다.

기준선에 있던 모든 Ingress·IngressRoute·Middleware spec이 그대로 존재했다. 인증서
fingerprint는
`60:91:4D:97:DF:E7:E3:49:A6:6E:CC:6E:15:07:D2:3A:0B:A8:AB:22:3C:DF:05:02:44:E9:DF:6B:06:4B:2D:10`,
HTTP는 원 path/query를 보존한 `301`, HTTPS control은 `404`로 불변이다. Keycloak issuer는
`https://sso.imcherry5778.xyz/realms/platform`, Node는 `Ready=True`,
`DiskPressure=False`이고 전체 Pod health 검사도 통과했다.

### warmed HTTP/2 성능

동일 client·backend와 고정 connect IP에서 persistent HTTP/2 worker 10개를 먼저 만들고
각 worker의 첫 transfer를 제외했다. control/WAF 각 1,000건을 세 round 수행했으며 status,
remote IP, HTTP/2와 측정 구간 신규 연결 `0`을 요청마다 확인했다.

| phase | count | failures | new connections | p95 | WAF-control |
|---|---:|---:|---:|---:|---:|
| round1-control | 1,000 | 0 | 0 | 74.135ms | - |
| round1-waf | 1,000 | 0 | 0 | 78.090ms | 3.955ms |
| round2-waf | 1,000 | 0 | 0 | 76.286ms | 3.409ms |
| round2-control | 1,000 | 0 | 0 | 72.877ms | - |
| round3-control | 1,000 | 0 | 0 | 73.926ms | - |
| round3-waf | 1,000 | 0 | 0 | 77.373ms | 3.447ms |

WAF p95는 세 round 모두 절대 `100ms` 이하이고 control 대비 증분 `20ms` 이하이다.
Traefik 평균 CPU는 control `31.083m`, WAF `39.917m`, 증분 `8.833m`이고 WAF peak는
`78m`이다. Node CPU peak는 `6%`다. 당시 RSS로 표기한 Traefik working set은 baseline `40Mi`, round 종료
`46/46/54Mi`, peak `54Mi`, 60초 idle `53Mi`여서 잔류 증분 `13Mi`이고 3회 연속 단조
증가도 아니다. 실제 RSS는 측정하지 않았다. 측정 전후 Traefik UID·restart가 같으며 정상
요청 실패는 0건이다.

최종 통합 직전 `BKP-03 DONE` main `67f4ea39186e594606ac8a5b0db5793038e1657c`로
rebase한 뒤 전체 공급망·packaged chart·Docker·Kubernetes API round-trip·offline startup·
live 기능과 성능을 다시 수행했다. 두 번째 성능 실행도 실패·신규 연결 0이며 control p95
`75.341/73.892/73.108ms`, WAF p95 `74.455/76.397/76.068ms`로 통과했다. 평균 CPU
증분은 `-7.833m`, WAF peak `96m`, Node peak `6%`, working set baseline/60초 idle
`58/65Mi`였다. 실제 RSS는 측정하지 않았다. 첫 재실행 시 관리 Tailscale 경로가 SSH 시작 전에 timeout됐으나 요청·자원
측정은 시작되지 않았다. subnet router 연결이 회복된 뒤 새 결과 디렉터리에서 전 구간을
다시 실행해 PASS만 증거로 사용했다.

### AppSec 장애 정책과 복구

사용자가 별도로 승인한 AppSec Pod 삭제 시험을 수행했다. replacement가 준비되기 전
WAF 정상 요청은 fail-closed `403`, middleware 없는 control은 `200`이었다. Deployment가
AppSec를 자동 재생성한 뒤 WAF와 control은 모두 `200`으로 회복했고 최종 AppSec Pod UID는
`6e42eb95-5b23-4b47-bcc8-c18d84480fee`, ready, restart `0`이다. 이 시험 전후 Traefik Pod
UID `046738f1-1b1a-4709-a0c3-f41d4168420d`는 변하지 않아 정적 등록 이후 추가 Traefik
재기동이 없었다. 회복 후 전체 route·decision 0·ingress 회귀 검증을 다시 통과했다.

### rollback과 merge 뒤 복구 절차

이 작업의 실제 rollback 경로는 앞선 enablement 실패에서 두 번 수행했다. signed revert를
main에 push한 뒤 root finalizer가 Application·namespace를 prune하고, ingress HCC에서
plugin·secret mount가 제거된 새 Traefik Pod가 Ready가 된 다음에만 bouncer Secret을
삭제했다. 영구 `AppProject/crowdsec`를 남긴 두 번째 rollback부터 finalizer 강제 제거 없이
정상 완료됐으며 인증서·HTTPS·301·source IP·Keycloak과 Node 상태가 회복됐다.

현재 enablement SHA에서 gate 실패가 evidence merge 전에 발생하면 깨끗한 최신 main에서
`git revert -S 27db9b352020821b8b5e2cc9a6ab00822d9bcaab`를 실행해 push하고 같은 순서로
Argo prune과 ingress 회복을 확인한다. evidence/`DONE` merge 뒤 결함이 발견되면 공개 이력을
고치지 않는다. 새 FIX ID·branch·worktree를 만들고 `git revert --no-commit`으로 enablement
역변경을 준비한 뒤, 역사 증거 문서는 보존하고 live Application·HCC plugin/mount 선언만
제거하며 현재 상태를 backlog에 함께 기록한 signed 단일 FIX commit으로 push한다. 두 경우
모두 `platform-root` targetRevision을 바꾸지 않고 다음 순서로 완료를 판정한다.

1. root finalizer가 CrowdSec Application·namespace·workload를 모두 prune한다.
2. ingress가 같은 revert SHA에서 `Synced/Healthy`이고 HCC plugin·mount가 사라진다.
3. 기존 image의 새 Traefik Pod 1개가 Ready, restart `0`이 된 뒤 bouncer Secret을 삭제한다.
4. root·ingress·keycloak, 인증서·HTTPS·path/query `301`·source IP와 Node health를 재검증한다.
5. 원격 main SHA·서명을 확인하고 새 FIX에서 별도 승인받은 통합 구조로 복구 증거를 기록한다.

이 시점의 기능·p95·CPU·당시 working set·장애 검사는 통과했지만 실제 RSS는 측정하지
않았다. 이후 들어오는 최신 main으로 rebase한 뒤 전체 증거도 다시 검증해야 하므로 이
결과만으로 `DONE`을 확정하지 않는다.

## POM-01·NB-02 통합 뒤 최종 성능 실패와 rollback

`POM-01`·`NB-02`가 들어간 최신 main
`5029d74e0dcbdb3a322b3cc5046bbc501cf0ac85`로 evidence 후보를 rebase했다. root·ingress·
keycloak·crowdsec·pomerium은 모두 `targetRevision: main`, 같은 SHA에서
`Synced/Healthy`였고 HCC generation `10`, Traefik UID
`046738f1-1b1a-4709-a0c3-f41d4168420d`, restart `0`은 불변이었다. 이 상태에서 공급망,
packaged chart, Docker 호환, Kubernetes API round-trip, egress 없는 startup, live 기능과
server dry-run을 다시 통과했다.

최종 warmed HTTP/2 측정은 요청 실패와 측정 구간 신규 연결이 모두 0이었지만 승인된 성능
gate를 통과하지 못했다.

| phase | count | failures | new connections | p95 |
|---|---:|---:|---:|---:|
| round1-control | 1,000 | 0 | 0 | 104.104ms |
| round1-waf | 1,000 | 0 | 0 | 105.554ms |
| round2-waf | 1,000 | 0 | 0 | 105.530ms |
| round2-control | 1,000 | 0 | 0 | 104.370ms |
| round3-control | 1,000 | 0 | 0 | 239.366ms |
| round3-waf | 1,000 | 0 | 0 | 107.479ms |

세 WAF round가 모두 절대 p95 `100ms`를 `5.554/5.530/7.479ms` 초과했다. 당시 RSS로
표기한 Traefik working set round 종료값도 `58 → 68 → 69Mi`로 3회 연속 증가해 기존
verifier의 monotonic 검사를 실패했다.
60초 idle `68Mi`는 baseline `58Mi` 대비 `10Mi` 증가로 잔류 `64Mi` 기준 안이고,
Traefik 평균 CPU 증분 `-9.243m`, WAF peak `50m`, Node peak `5%`도 기준 안이지만 다른
실패를 상쇄하지 않는다. 특히 기존 verifier의 절대 p95 필터가 phase column을 지정하지 않고
전체 line 끝에 `-waf`를 찾는 오류로 p95 초과를 직접 보고하지 못한 점을 발견했다. branch에서
필터를 `$1 ~ /-waf$/`로 보정했으며, working set monotonic 검사가 같은 실행을 실패
처리했으므로 합격으로 오판되지는 않았다. 다만 이는 ADR의 실제 RSS gate 증거가 아니다.

승인된 기준을 완화하거나 evidence/`DONE`을 main에 merge하지 않았다. signed revert
`1315f9dc0a68fb85995b2ff8b23e725b9c7d37c5`로 enablement
`27db9b352020821b8b5e2cc9a6ab00822d9bcaab`만 되돌렸다. POM-01·NB-02와 다른 최신 main
변경은 보존했다.

- root finalizer가 CrowdSec Application·namespace·workload·bootstrap Secret을 정상 prune했고
  영구 `AppProject/crowdsec`는 남았다.
- ingress가 revert SHA를 읽어 HCC generation `10 → 11`, Traefik Deployment
  `14 → 15`, Pod UID `dc5f3c99-9e72-40bb-8851-bfbaadee2e5c`로 기존 설정을 복구했다.
  image digest는 같고 ready, restart `0`이다.
- plugin args·storage·secret mount 제거 뒤에만 bouncer Secret을 삭제했다. CrowdSec route는
  `404`이고 Application·namespace·두 Secret은 없다.
- root·ingress·keycloak·pomerium·headlamp·vault·velero는 revert SHA에서 모두
  `targetRevision: main`, `Synced/Healthy`다.
- 인증서 fingerprint, path/query 보존 HTTP `301`, HTTPS `404`, 실제 source IP
  `10.10.60.2`, Keycloak issuer, Pomerium `302`, Node `Ready=True`·`DiskPressure=False`가
  정상이다.

`CROWDSEC-FIX-01`은 `DONE`이 아니며 성능 변동과 수정 verifier로 다시 판단하기 전까지
branch에 `BLOCKED` 증거로 남긴다. `EDGE-01`은 이 작업과 `NET-04`가 미완료이므로
`BLOCKED`를 유지한다.

## enablement 없는 p95·RSS 원인 조사

사용자는 CrowdSec enablement와 Traefik 재기동을 금지하고 수정 verifier를 이용한 원인
조사만 승인했다. rollback main
`1315f9dc0a68fb85995b2ff8b23e725b9c7d37c5`에서 HCC generation `11`, Traefik
Deployment generation `15`와 plugin·bouncer marker 부재를 먼저 확인했다. 조사 전후
`platform-root`·`ingress`·`pomerium`은 `targetRevision: main`, 같은 SHA에서
`Synced/Healthy`였고 live invariant JSON SHA-256도
`baa86786547b762100301df3219bccf853f293ce2da5931d2980f8b9d5dd0f18`로 같았다.

### p95 원인

최종 실패 실행의 6,000개 원본 요청을 다시 계산했다. 정상 구간의 control 평균/p95는
`101.960/104.104ms`, `102.262/104.370ms`이고 WAF 평균/p95는
`103.351/105.554ms`, `103.141/105.530ms`였다. 따라서 WAF 고유 증분은 약 `1~3ms`인
반면 양쪽에 공통인 client 경로가 이미 `100ms`를 넘었다.

round3 control의 p95 `239.366ms`는 임의의 WAF 처리 spike가 아니었다. 10개 worker 모두
요청 index `21~23`, `55~57`, `86~88` 부근에서 동시에 두 요청씩 느려져 정확히 60건이
`120ms`를 넘었다. 같은 실행의 round3 WAF에서는 첫 요청 5건만 `120ms`를 넘었다. 이는
backend나 WAF보다 모든 persistent connection이 공유한 네트워크 경로의 주기적 stall과
일치한다.

2026-08-01T21:22:34+09:00에 CrowdSec이 없는 `404` control path를 기존 read-only
진단으로 다시 측정했다.

| 구간 | 요청 | 실패 | 신규 연결 | p95 |
|---|---:|---:|---:|---:|
| rollback warmed round 1 | 1,000 | 0 | 0 | 105.414ms |
| rollback warmed round 2 | 1,000 | 0 | 0 | 105.755ms |
| rollback warmed round 3 | 1,000 | 0 | 0 | 105.270ms |
| k3s node fresh TLS | 100 | 0 | 100 | 15.507ms |

client route는 `10.10.0.0/16 dev tailscale0`이고 ping은 loss `0%`, 평균
`103.681ms`였다. subnet router `ds224p`에는 direct endpoint가 없고 Tokyo DERP relay가
선택돼 있으며 Tailscale ping도 `99~102ms`였다. 따라서 이번 절대 p95 실패의 직접 원인은
CrowdSec이 아니라 현재 Tailscale DERP 경로의 RTT다. 과거 성공 실행도 같은 DERP 연결
로그가 있어 direct→relay 전환 시점을 입증할 수는 없고, 성공 당시 ping 평균
`72.472ms`에서 현재 `103.681ms`로 relay 종단 지연이 상승했다는 범위까지만 판정한다.

### RSS 원인

기존 verifier의 `kubectl top pod` memory는 실제 RSS가 아니라 kubelet working set이다.
[metrics-server 공식 FAQ](https://github.com/kubernetes-sigs/metrics-server/blob/master/FAQ.md#how-memory-usage-is-calculated)도
memory를 수집 시점의 working set이라고 정의한다. rollback Traefik에서 근접 시점의
`kubectl top` `25Mi`와 kubelet `workingSetBytes=27,545,600`은 같은 범위였지만,
`rssBytes=21,159,936`은 약 `20.18Mi`로 별도 값이었다.
따라서 최종 실행에서 `RSS`라고 기록한 `58 → 68 → 69Mi`는 working set 시계열로
재분류해야 한다. 삭제된 enablement Pod의 과거 `rssBytes`는 보존되지 않아 실제 RSS의
단조 증가나 누수는 증명되지 않았다.

rollback Traefik은 read-only 5,100건 전 실제 RSS/working set 약
`20.18/26.27Mi`, 완료 뒤 `25.16/35.95Mi`였고 이후 세 표본에서
`25.16/35.95Mi`로 유지됐다. 이 대조는 working set과 RSS가 서로 다르게 움직임을
확인하지만, bouncer가 없는 Pod이므로 enabled 상태의 RSS 합격 증거로 사용하지 않는다.

verifier는 앞으로 kubelet summary의 실제 `rssBytes`와 `workingSetBytes`를 별도 열에
기록하고 RSS gate에는 `rssBytes`만 사용한다. client route와 ping도 결과에 고정한다.
absolute p95 검사도 phase 열 `$1`만 검사하도록 유지한다. 현재 같은 client에서 WAF가
없어도 absolute `100ms`를 초과하므로 enablement 전 read-only control preflight가
`100ms` 아래로 회복되지 않으면 재적용하지 않는다. 실제 enabled RSS는 사용자 승인 뒤의
새 적용에서만 다시 판정할 수 있어 `CROWDSEC-FIX-01 BLOCKED` 상태는 바꾸지 않는다.

## Tailscale 제외 승인과 최종 enablement

사용자는 Tailscale relay 지연을 CrowdSec 실패에서 제외하고, 추가 성능시험 없이
CrowdSec enablement·Traefik 1회 재기동 뒤 기본 기능과 기존 ingress 회귀만 확인해
완료하도록 명시적으로 승인했다. 이 결정은 기존 WAF 증분 약 `1~3ms`, CPU·working set과
두 차례 warmed 통과 실행을 수용한 PoC 한정 판정이다.

적용 직전 main `1315f9dc0a68fb85995b2ff8b23e725b9c7d37c5`에서
`platform-root`·`ingress`·`keycloak`은 `Synced/Healthy`, HCC generation `11`, Traefik
Deployment generation `15`, Pod UID
`dc5f3c99-9e72-40bb-8851-bfbaadee2e5c`, restart `0`이었다. Pomerium도
`targetRevision: main`, `Synced/Healthy`였고 CrowdSec Application·namespace·Secret은
없었다.

Git 밖 mode `0600` 임시 입력으로 새 bootstrap·bouncer 값을 생성해 Secret 이름·type만
출력하고 원문 파일과 임시 디렉터리를 즉시 파기했다. signed enablement
`af9b5bd15baabd316772150dc12b392e612b95bf`는 공개 main의 기존 revert를 다시 쓰지 않고
역변경한 새 커밋이다. `platform-root.targetRevision`은 계속 `main`이며 standard hard
refresh annotation만 사용했다.

Argo root·ingress·keycloak·pomerium·crowdsec은 enablement SHA에서 모두
`Synced/Healthy`다. HCC `11 → 12`, Traefik Deployment `15 → 16`, Pod UID
`dc5f3c99-9e72-40bb-8851-bfbaadee2e5c → 745d8a7d-f9e1-4fa1-8f01-d62530990d2b`로
정확히 한 번 교체됐으며 기존 image digest, ready, restart `0`이다. CrowdSec LAPI·AppSec·
whoami Pod도 모두 ready, restart `0`이다.

추가 성능 부하는 실행하지 않고 다음 기능·회귀만 검증했다.

- control·WAF 정상 `200`, `masscan` rule `913100` 공격 `403`
- exact URI+UA 예외 `200`, UA·query·URI 중 하나가 다른 세 요청 `403`
- middleware 없는 control 공격 `200`, LAPI decision `0`
- 기존 ingress object spec·인증서 fingerprint·path/query 보존 HTTP `301`·HTTPS `404`
- forged XFF 제거와 실제 source IP `10.10.60.2`, Keycloak issuer, Pomerium `302`
- Node `Ready=True`·`DiskPressure=False`, 전체 Pod 정상, Secret type·이름만 확인

공개 main enablement·과거 rollback 이력, immutable 공급망, AppSec fail-closed와 Argo/Git
rollback 증거를 모두 보존했다. 향후 성능 재검증은 보정된 verifier의 실제 `rssBytes`와
working set을 분리하지만 이번 완료를 위한 반복 부하는 요구하지 않는다.
`CROWDSEC-FIX-01`은 `DONE`이며 `EDGE-01`은 `NET-04`가 남아 `BLOCKED`다.
