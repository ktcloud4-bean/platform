# CROWDSEC-FIX-01 활성 검증 자산

이 디렉터리는 ADR-0012의 CrowdSec AppSec PoC를 격리 환경과 승인 뒤 live 환경에서
검증한다. `CORAZA-01`의 direct WASM 자산을 활성화하지 않는다.

## 2026-08-01 읽기 전용 preflight

최초 확인 시 `origin/main`은 `e8e50af91dfd56b026c8f8140d2229d1a1b07e04`였고,
`platform-root`와 `ingress`는 같은 main revision에서 `Synced/Healthy`였다. packaged
Traefik은 chart `40.1.3+up40.1.0`, image `3.7.4`, imageID
`sha256:fcdef599e6259359833dd2e1d49f9e964f66825d69bd3dd468f51102ce013d03`인
단일 Pod이며 restart 0이었다. Node는 Ready, DiskPressure false였고 측정 시 Node
`66m/2628Mi`, Traefik `1m/27Mi`였다. CrowdSec test route 자원은 없었다.

이는 적용 시점의 보증이 아니다. KC-01·BKP-01·BKP-03 병렬 작업 뒤 최신 main, worktree,
Argo revision, live route, Pod와 resource를 다시 읽어 차이가 있으면 중단한다. 특히
`gitops/root/kustomization.yaml`의 KC-01 항목을 rebase에서 보존하고 KC-01 이후에만 main
통합 순서를 잡는다.

## 공급망과 격리 결과

[`release-metadata.env`](../../../gitops/apps/crowdsec/release-metadata.env),
[`crs-snapshot.SHA256`](../../../gitops/apps/crowdsec/crs-snapshot.SHA256)과 archive hash가
source, version, commit, image digest, plugin source/registry archive hash, Hub YAML과
data 49개를 고정한다. Hub 자동 update와 floating collection은 렌더 결과에 없다.
archive는 재현 가능한 ustar+gzip이고 SHA-256은
`235dc3bc50c3c861ba9561487c72d6562e8c6501467314a6618781a37bdaede6`이다.

[`verify-packaged-traefik-chart.sh`](verify-packaged-traefik-chart.sh)는 live HelmChart의
내부 static chart 경로와 base values를 읽기만 한다. chart archive SHA-256을 검증한 뒤
현재 HelmChartConfig를 로컬 렌더해 Traefik `3.7.4`, plugin module/version/hash,
`/plugins-storage`, mode `0440` secret mount가 packaged chart에서 정확히 생성되는지 확인한다.

[`verify-local-compat.sh`](verify-local-compat.sh)는 Docker 전용 network와 실행마다 생성한
임시 key만 사용하고 종료 시 모두 제거한다. k3s, Argo, OPNsense, DNS, 인증서는 변경하지
않는다. `LAPI↔AppSec` network와 `Traefik↔AppSec/backend` network를 분리하므로
Traefik은 LAPI에 접근하거나 이름을 해석할 수 없다. 이는 live NetworkPolicy의
Traefik→LAPI 차단 경계를 그대로 재현한다. AppSec/LAPI network는 `internal=true`이고,
고정 hash community plugin을 받는 외부 network는 Traefik에만 연결한다.

[`verify-kubernetes-roundtrip.sh`](verify-kubernetes-roundtrip.sh)는 기존 namespace가
없을 때만 `crowdsec-fix-01-verify`를 만들고, Helm render의 ConfigMap을 실제 API에 저장한
뒤 API JSON bytes와 fixed CrowdSec image가 volume으로 읽은 archive·49개 파일 hash를
검증한다. Secret·HelmChartConfig·Traefik을 만들거나 수정하지 않고 종료 시 namespace를
삭제한다.

[`verify-kubernetes-offline-startup.sh`](verify-kubernetes-offline-startup.sh)는 route,
Middleware, HCC, PVC를 렌더하지 않은 격리 namespace에서 full AppSec/LAPI startup을
검증한다. pinned image 원본 entrypoint, offline builder와 결과 script hash를 실제 init과
main container에서 확인하고, AppSec→LAPI TCP는 성공하지만 외부 TCP는 차단되는지 검사한다.
AppSec/LAPI 로그에 Hub 설치·갱신 호출이 0건이어야 하며 전후 Traefik HCC·Pod 상태가 같아야
한다.

2026-08-01 최종 격리 실행 결과:

```text
PASS: AppSec/LAPI의 Docker network는 internal이며 Hub 설치·갱신 요청은 0건이다.
PASS: 외부 network는 고정 hash community plugin을 받는 Traefik에만 연결했다.
PASS: packaged Traefik 3.7.4 고정 image에서 bouncer v1.7.1/hash가 로드됐다.
PASS: 정상 200, CRS 913100 공격 403, exact URI+UA 예외만 200, control 공격 200이다.
PASS: IP decision은 0개이며 AppSec 중단 시 WAF test route만 fail-closed 403, control은 200이다.
PASS: Traefik은 running, OOMKilled=false, restart=0이고 AppSec 재기동 뒤 WAF 200으로 복구됐다.
PASS: 실제 Kubernetes init/main startup의 원본·builder·offline script hash가 고정값과 일치한다.
PASS: AppSec→LAPI는 허용되고 외부 TCP egress는 차단되며 Hub 설치·갱신 요청은 0건이다.
PASS: route/HCC/PVC 없이 검증했고 Traefik HCC·Pod 상태는 불변이며 격리 namespace를 제거했다.
```

검증 과정에서 두 호환 조건도 명시적으로 고정했다.

- bouncer `updateIntervalSeconds`는 0을 허용하지 않아 60초로 고정했다.
  `crowdsecMode: appsec`이므로 IP decision은 소비하지 않으며 metrics update는 0으로 끈다.
- CrowdSec는 `/var/lib/crowdsec/data`를 Coraza `RootFS`로 전달한다. 하위 디렉터리나
  컨테이너 루트 mount는 실패하고, ConfigMap을 그 경로에 직접 read-only mount하면
  `docker_start`의 GeoIP link 생성이 실패한다. read-only ConfigMap의 deterministic archive를
  init container가 archive SHA-256 검증 뒤 writable `emptyDir`로 추출하고 개별 manifest를
  다시 검증한다. 고정 CrowdSec image의 실제 `tar`·`sha256sum` 명령을 격리 Docker와
  Kubernetes API round-trip에서 모두 실행한다.
- AppSec의 `default_remediation: ban`은 해당 HTTP transaction의 403 action일 뿐 LAPI IP
  decision이 아니다. 항상 false인 profile은 decision 생성을 막고, NetworkPolicy에는
  Traefik→LAPI 허용 규칙이 없어 bouncer가 decision을 소비할 경로도 없다.

격리 결과는 라이브 성공 증거가 아니다. 승인 뒤 기능, 성능, AppSec 장애, 전체 ingress
회귀와 rollback을 검증하기 전까지 `CROWDSEC-FIX-01`은 `DONE`이 아니다.

## 2026-08-01 적용 승인과 통합 예외

사용자는 ADR-0012의 다섯 항목을 확인한 뒤 bouncer 정적 등록, 제시한 live 검증과
rollback을 승인했다. 적용 직전 KC-01 완료 여부를 다시 확인하고 재기동 시점을 조율하는
조건은 그대로 남는다.

GitOps 선언을 검증 전에 main에 먼저 통합해야 하는 조건과 live 증거 뒤에만 `DONE`을
기록할 수 있는 조건을 함께 지키기 위해, `CROWDSEC-FIX-01`에 한해서 main 세 커밋을
승인받았다.

1. 영구 AppProject 기반 commit `161debf143d61f8e621ce25b25e601e0c5c207a7`
2. 수정 enablement commit: `CROWDSEC-FIX-01 READY` 유지
3. live gate를 모두 통과한 뒤 evidence와 `CROWDSEC-FIX-01 DONE`을 기록하는 commit

live gate가 실패하면 세 번째 커밋을 만들지 않고 두 번째 수정 enablement commit만
`git revert`한다. 영구 AppProject는 남겨 child Application finalizer의 정상 prune을
보장한다. Traefik 재기동 직전에는 live `KC-01` 상태와 시점을 다시 확인한다.

## CROWDSEC-FIX-01 격리 재검증

FIX는 49개 raw text를 YAML scalar로 재직렬화하지 않고 deterministic archive 하나를
`ConfigMap.binaryData`로 전달한다. archive SHA-256은
`235dc3bc50c3c861ba9561487c72d6562e8c6501467314a6618781a37bdaede6`이다.
로컬 deterministic rebuild와 Helm decode, 고정 CrowdSec image init, 실제 Kubernetes API
저장/조회와 volume mount 후 추출을 거쳐 원본 49개 hash가 모두 일치했다. AppSec YAML
config/rule/exception도 `binaryData` API 전후 바이트가 고정 hash와 같았다.

packaged Traefik chart와 Docker 격리 기능 검증도 다시 통과했다. 상세 실행 결과와 최초
실패/revert, 영구 AppProject foundation commit은
[`CROWDSEC-FIX-01 증거`](../crowdsec-fix-01/README.md)가 소유한다.

## 승인 뒤 live evidence 결과

- 적용 직전 KC-01 `DONE`·`Synced/Healthy`, Secret 원문 비출력·임시 파일 파기,
  Argo와 Traefik 단일 교체를 확인했다.
- 정상/공격/exact 예외/negative 예외/control과 decision 0, 기존 ingress 회귀는 통과했다.
- 성능은 control과 WAF p95가 모두 약 `333~338ms`로 WAF 절대 `100ms` gate를 실패했다.
  AppSec Pod 삭제 시험과 60초 idle 측정 전 signed Git revert와 Argo prune을 수행했다.
- 상세 SHA·수치·rollback 증거는
  [`CROWDSEC-FIX-01 증거`](../crowdsec-fix-01/README.md)에 기록한다.

이 실패는 [`CROWDSEC-PERF-01`](../crowdsec-perf-01/README.md)에서 각 요청이 DNS·TCP·TLS를
새로 만든 측정 도구 결함으로 분리했다. p95 절대 `100ms`·control 대비 `20ms` 기준은
완화하지 않는다. 다음 enablement는 worker 10개가 각각 HTTP/2 연결을 먼저 수립하고 첫
transfer를 제외한 뒤 총 1,000건을 재사용한다. status·remote IP·HTTP/2와 측정 구간 신규
연결 0을 확인하고 이 과정을 control/WAF에 대해 3회 반복한다. 과거 결과는 소급해 합격
처리하지 않으며 live WAF에서 전 항목을 다시 측정한다.

## 네 번째 enablement 중간 결과

사용자가 immutable 공급망·route와 exact 예외·성능·장애/rollback 다섯 항목과 적용 시점을
다시 승인한 뒤 signed enablement
`27db9b352020821b8b5e2cc9a6ab00822d9bcaab`를 main에 통합했다. 적용 직전 KC-01은
`DONE`이고 root·ingress·keycloak은 최신 main에서 `Synced/Healthy`였다. 저장소 밖 mode
`0600` 파일로 Secret을 주입하고 원문은 즉시 파기했다.

HCC generation `9 → 10`, Traefik Deployment generation `13 → 14`, Pod UID
`30abf3ac-5239-498e-b2e1-e445f17ea9c5 → 046738f1-1b1a-4709-a0c3-f41d4168420d`로
정확히 한 번 교체됐다. Traefik `3.7.4` image digest와 인증서·기존 ingress spec은
불변이고 restart는 `0`이다. root·ingress·keycloak·crowdsec은 모두 enablement SHA에서
`Synced/Healthy`다.

- 정상 control/WAF `200`, rule `913100` 공격 `403`, exact URI+UA 예외만 `200`, 세
  negative 예외 `403`, middleware 없는 control 공격 `200`
- LAPI decision `[]`, 위조 XFF 제거와 실제 source IP 유지, Hub download/update 로그 0건
- persistent HTTP/2 10개 연결에서 control/WAF 각 1,000건×3회 실패·신규 연결 0;
  WAF p95 `78.090/76.286/77.373ms`, control 대비 증분 `3.955/3.409/3.447ms`
- Traefik 평균 CPU 증분 `8.833m`, WAF peak `78m`, Node CPU peak `6%`, 당시
  `kubectl top` working set baseline/60초 idle `40/53Mi`이며 restart·비정상 Pod 0
- AppSec Pod 삭제 중 WAF fail-closed `403`·control `200`, 자동 재생성 뒤 둘 다 `200`,
  Traefik UID 불변
- 기존 인증서 fingerprint, path/query 보존 HTTP `301`, HTTPS `404`, Keycloak issuer와
  Node `Ready=True`·`DiskPressure=False` 불변

과거 실패 enablement의 signed revert에서 영구 AppProject를 남긴 finalizer prune,
HCC plugin/mount 제거, 기존 Traefik·인증서·source IP 회복을 실제 검증했다. 현재 SHA의
gate 실패는 evidence merge 전 signed `git revert`; merge 후 결함은 새 FIX ID에서 공개
이력을 보존한 signed revert 변경으로 처리한다. 정확한 SHA·Pod UID·성능 표·secret 경계와
순서는 [`CROWDSEC-FIX-01 증거`](../crowdsec-fix-01/README.md)가 소유한다.

## 최신 main 재검증 실패와 rollback

POM-01·NB-02 통합 뒤 최신 main `5029d74e0dcbdb3a322b3cc5046bbc501cf0ac85`에서 전체
검증을 다시 수행했다. 기능·공급망·격리 startup은 통과했지만 세 WAF p95가
`105.554/105.530/107.479ms`로 절대 `100ms` gate를 모두 초과했고, 당시 RSS로 잘못
표기한 `kubectl top` working set도 `58/68/69Mi`로 연속 증가했다. 기존 absolute p95 awk가
phase column을 지정하지 않은 결함은 branch에서 보정했으며 working set gate가 같은 실행을
실패로 처리했다.

evidence/`DONE`은 main에 넣지 않고 signed revert
`1315f9dc0a68fb85995b2ff8b23e725b9c7d37c5`를 적용했다. CrowdSec Application·namespace·
Secret과 HCC plugin/mount를 제거하고 기존 Traefik image·인증서·301·source IP를 복구했다.
Pomerium을 포함한 기존 Argo 앱은 모두 revert SHA에서 `Synced/Healthy`다. 이 작업은
`DONE`이 아니며 상세 실패 수치와 rollback 증거는
[`CROWDSEC-FIX-01 증거`](../crowdsec-fix-01/README.md)가 소유한다.

후속 enablement 없는 조사에서 CrowdSec이 없는 같은 client의 warmed p95도
`105.414/105.755/105.270ms`였고, `tailscale0`의 Tokyo DERP relay ping은 `99~102ms`였다.
따라서 절대 p95 실패는 현재 공통 client 경로 지연이 원인이다. 또한 `kubectl top` memory가
실제 RSS가 아닌 working set임을 kubelet `rssBytes`와 직접 대조했다. verifier는 두 값을
분리하도록 보정했으며 enabled 실제 RSS는 재적용 전에는 판정할 수 없다. 상세 수치와 불변
증거는 [`CROWDSEC-FIX-01 증거`](../crowdsec-fix-01/README.md)의 원인 조사 절을 따른다.

## 최종 enablement

사용자는 Tailscale DERP 공통 지연을 CrowdSec 실패에서 제외하고 추가 성능 부하 없이
기존 WAF 증분·CPU·memory 증거를 수용했다. signed main
`af9b5bd15baabd316772150dc12b392e612b95bf`에서 HCC `11 → 12`, Traefik Deployment
`15 → 16`, Pod UID
`dc5f3c99-9e72-40bb-8851-bfbaadee2e5c → 745d8a7d-f9e1-4fa1-8f01-d62530990d2b`로
정확히 한 번 교체했다. route 200/403·exact 예외·control·decision 0과 기존 ingress·
인증서·301·source IP·Keycloak·Pomerium 회귀 없음을 다시 확인했다. runtime Secret 원문은
Git 밖에서만 주입하고 즉시 파기했다. 최종 상태와 승인 판정은
[`CROWDSEC-FIX-01 증거`](../crowdsec-fix-01/README.md)의 마지막 절이 소유한다.
