# CROWDSEC-01 검증 증거

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

[`release-metadata.env`](../../../gitops/apps/crowdsec/release-metadata.env)와
[`crs-snapshot.SHA256`](../../../gitops/apps/crowdsec/crs-snapshot.SHA256)이 source,
version, commit, image digest, plugin source/registry archive hash, Hub YAML과 data 49개를
고정한다. Hub 자동 update와 floating collection은 렌더 결과에 없다.

[`verify-packaged-traefik-chart.sh`](verify-packaged-traefik-chart.sh)는 live HelmChart의
내부 static chart 경로와 base values를 읽기만 한다. chart archive SHA-256을 검증한 뒤
현재 HelmChartConfig를 로컬 렌더해 Traefik `3.7.4`, plugin module/version/hash,
`/plugins-storage`, mode `0440` secret mount가 packaged chart에서 정확히 생성되는지 확인한다.

[`verify-local-compat.sh`](verify-local-compat.sh)는 Docker 전용 network와 실행마다 생성한
임시 key만 사용하고 종료 시 모두 제거한다. k3s, Argo, OPNsense, DNS, 인증서는 변경하지
않는다. `LAPI↔AppSec` network와 `Traefik↔AppSec/backend` network를 분리하므로
Traefik은 LAPI에 접근하거나 이름을 해석할 수 없다. 이는 live NetworkPolicy의
Traefik→LAPI 차단 경계를 그대로 재현한다.

2026-08-01 최종 격리 실행 결과:

```text
PASS: packaged Traefik 3.7.4 고정 image에서 bouncer v1.7.1/hash가 로드됐다.
PASS: 정상 200, CRS 913100 공격 403, exact URI+UA 예외만 200, control 공격 200이다.
PASS: IP decision은 0개이며 AppSec 중단 시 WAF test route만 fail-closed 403, control은 200이다.
PASS: Traefik은 running, OOMKilled=false, restart=0이고 AppSec 재기동 뒤 WAF 200으로 복구됐다.
```

검증 과정에서 두 호환 조건도 명시적으로 고정했다.

- bouncer `updateIntervalSeconds`는 0을 허용하지 않아 60초로 고정했다.
  `crowdsecMode: appsec`이므로 IP decision은 소비하지 않으며 metrics update는 0으로 끈다.
- CrowdSec는 `/var/lib/crowdsec/data`를 Coraza `RootFS`로 전달한다. 하위 디렉터리나
  컨테이너 루트 mount는 실패하고, ConfigMap을 그 경로에 직접 read-only mount하면
  `docker_start`의 GeoIP link 생성이 실패한다. read-only ConfigMap을 init container가
  SHA-256 검증 뒤 writable `emptyDir`로 복사하는 경계를 사용한다. 실행 뒤에도 원본 49개
  CRS bytes의 hash가 동일하며 snapshot 자체는 수정하지 않았다. 고정 CrowdSec image에서
  실제 init 명령인 `cp -a`와 `sha256sum -c`도 별도로 실행해 49개 파일 검증을 통과했다.
- AppSec의 `default_remediation: ban`은 해당 HTTP transaction의 403 action일 뿐 LAPI IP
  decision이 아니다. 항상 false인 profile은 decision 생성을 막고, NetworkPolicy에는
  Traefik→LAPI 허용 규칙이 없어 bouncer가 decision을 소비할 경로도 없다.

격리 결과는 라이브 성공 증거가 아니다. 승인 뒤 기능, 성능, AppSec 장애, 전체 ingress
회귀와 rollback을 검증하기 전까지 `CROWDSEC-01`은 `DONE`이 아니다.

## 2026-08-01 적용 승인과 통합 예외

사용자는 ADR-0012의 다섯 항목을 확인한 뒤 bouncer 정적 등록, 제시한 live 검증과
rollback을 승인했다. 적용 직전 KC-01 완료 여부를 다시 확인하고 재기동 시점을 조율하는
조건은 그대로 남는다.

GitOps 선언을 검증 전에 main에 먼저 통합해야 하는 조건과 live 증거 뒤에만 `DONE`을
기록할 수 있는 조건을 함께 지키기 위해, CROWDSEC-01에 한해서만 main 두 커밋을 승인받았다.

1. 선언 enablement squash commit: `CROWDSEC-01 READY` 유지
2. live gate를 모두 통과한 뒤 evidence와 `CROWDSEC-01 DONE`을 기록하는 commit

live gate가 실패하면 두 번째 커밋을 만들지 않고 첫 enablement commit만 `git revert`한다.
2026-08-01 승인 직후 재확인에서는 KC-01 worktree가 여전히 미커밋 상태였고 live Keycloak
Application과 리소스도 없었으므로, main 통합·Secret 주입·Traefik 재기동을 보류했다.

## 승인 뒤 채울 live evidence

- 적용 직전 main SHA, KC-01 상태와 합의한 Traefik 재기동 시각
- Secret 이름/type만 확인한 결과와 Git history/diff secret scan
- Argo root/ingress/crowdsec revision과 `Synced/Healthy`
- Traefik old/new Pod UID, imageID 불변, 정확히 한 번의 계획된 교체와 이후 restart 0
- 정상 200, rule 913100 공격 403, exact 예외 200, 두 negative exception 403, control 200
- LAPI decision 0개, forbidden integration/egress 부재
- [`benchmark-live.sh`](benchmark-live.sh)의 3 round p95·CPU·RSS·Node 결과
- [`verify-appsec-failure.sh`](verify-appsec-failure.sh)의 승인된 AppSec Pod 1개 삭제,
  장애 중 WAF 403/control 200, 자동 재생성 뒤 WAF/control 200과 Traefik UID 불변
- [`capture-live-baseline.sh`](capture-live-baseline.sh)와
  [`verify-live.sh`](verify-live.sh)로 기존 route spec 및 strict HTTPS·301·source
  IP/XFF·인증서 fingerprint 전후 동일
- rollback rehearsal 또는 실제 rollback의 Argo prune/reconcile와 Git revert 명령
