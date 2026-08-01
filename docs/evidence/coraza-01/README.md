# CORAZA-01 폐기 증거: Traefik HTTP-WASM 호환성 실패

이 디렉터리는 `WAF-DESIGN-01`이 활성 `gitops/` 경로에서 분리해 보존한 `CORAZA-01`의
로컬 격리 실패 증거다. 파일 provider와 Docker 전용 네트워크만 사용하며 k3s, Argo CD,
OPNsense, DNS와 인증서를 변경하지 않는다. direct connector 계획은 **DEFERRED**이며 이
파일들을 Kubernetes나 Traefik HelmChartConfig에 적용하지 않는다.

## 확인한 현재 경계

2026-08-01 최초 읽기 전용 preflight 결과는 다음과 같다.

- `platform-root`와 `ingress`는 revision
  `69c37a0dc34e373ac0ed9a05d3007d62b884a509`의 `Synced/Healthy`다.
- packaged Traefik은 chart `40.1.3+up40.1.0`, image `3.7.4`, imageID
  `sha256:fcdef599e6259359833dd2e1d49f9e964f66825d69bd3dd468f51102ce013d03`인
  단일 Pod다.
- Kubernetes `Ingress`, Traefik `IngressRoute`, `Middleware`, Gateway API `HTTPRoute`는
  모두 0개다.
- 현재 HelmChartConfig에는 plugin 인수가 없다. `websecure` entrypoint가 production
  ACME resolver와 `k3s-01.imcherry5778.xyz` domain을 소유한다. strict HTTPS는 인증서
  검증 성공 후 404, HTTP는 path와 query를 보존한 301이다.
- Node는 `55m` CPU와 `2415Mi` memory, Traefik은 `1m`과 `27Mi`, guest root 사용률은
  4%였고 비정상 Pod와 failed unit은 없었다.

차단 판정 뒤 후속 재조회 중 다른 작업의 staging으로 `platform-root` source
`targetRevision`이 `task/headlamp-01`의 immutable commit
`fe0c977be48ffe56527fdf7ce8478e6eef2ba135`로 바뀌었다. 해당 commit의 root 차이는
Headlamp child 추가뿐이며 ingress child는 계속 `main@69c37a0dc34e373ac0ed9a05d3007d62b884a509`
`Synced/Healthy`다. Traefik은 같은 imageID, ready, restart 0이고 route 수 0, strict HTTPS
404와 HTTP 301도 유지된다. 이 병렬 staging은 본 작업이 변경하거나 복구하지 않으며,
향후 새 ADR로 direct connector를 재검토할 때는 root가 최신 main인지 다시 확인해야 한다.

## 고정 artifact

정확한 값은 [`release-metadata.env`](release-metadata.env)가 소유한다.

- Coraza 공식 connector 목록이 가리키는 Traefik plugin module
  `github.com/jcchavezs/coraza-http-wasm-traefik`의 현재 catalog release `v0.3.0`을 쓴다.
- Traefik plugin registry와 GitHub release의 zip은 byte-for-byte 같고 SHA-256은
  `b96680b46e61287faae243e360db5de34e4f315e2a8ee105fedddc176e79b1e7`이다.
- plugin archive의 `.traefik.yml`은 `runtime: wasm`, `type: middleware`,
  `wasmPath: coraza-http-wasm.wasm`을 선언한다.
- 이 WASM은 `coraza-http-wasm v0.3.0`이 빌드한 것으로 Coraza `v3.2.1`과 embedded
  `coraza-coreruleset v4.0.0`을 포함한다.
- Traefik 3.7.4와 local backend image도 tag와 registry digest를 함께 고정한다.

Traefik 3.7의 지원 경로는 정적 install configuration의
`experimental.plugins.<name>.{moduleName,version,hash}`와 동적 route의
`Middleware.spec.plugin` 조합이다. packaged chart의 `experimental.plugins` 값은 이 세
인수를 생성하고 `/plugins-storage` emptyDir을 붙인다. 따라서 plugin 등록 자체는
HelmChartConfig를 통한 전역 정적 설정이고 Traefik Pod 재기동을 일으킨다. middleware의
실제 검사 범위만 이를 참조한 route로 제한할 수 있다.

## 재현 결과

[`verify-local-compat.sh`](verify-local-compat.sh)는 기존 동일 이름 자원이 있으면 중단하고,
전용 컨테이너와 네트워크를 종료 시 정리한다.

```bash
./docs/evidence/coraza-01/verify-local-compat.sh
```

세 단계를 같은 고정 이미지로 실행한다.

1. plugin을 정적으로 로드하되 middleware를 만들지 않은
   [`local-dynamic-control.yaml`](local-dynamic-control.yaml)은 Traefik이 계속 실행되고
   control route가 HTTP 200이다.
2. upstream 예제보다도 작은 두 지시문만 가진
   [`local-dynamic-minimal.yaml`](local-dynamic-minimal.yaml)을 attach하면 plugin load 직후
   Traefik이 OOM 없이 exit 2로 종료하고
   `fatal error: runtime: split stack overflow`를 남긴다.
3. 전체 CRS와 좁은 예외를 선언한 [`local-dynamic.yaml`](local-dynamic.yaml)도 같은
   초기화 지점에서 동일하게 종료한다.

이는 CRS 탐지나 성능 기준을 측정하기 전에 ingress process가 죽는 호환성 실패다.
upstream에도
[`Traefik 3.4.3부터 plugin 비호환`](https://github.com/jcchavezs/coraza-http-wasm-traefik/issues/23)
이슈가 열려 있고, plugin main은 프로젝트가 초기 단계이며 production-grade 성능에는
적합하지 않다는 disclaimer를 명시한다. 별도로 WASM middleware의 고메모리 이슈도
열려 있으므로 기동만 성공해도 memory gate를 생략하지 않는다.

## 적용하지 않고 폐기한 attach 설계

아래는 원래 승인 gate에 제시하려던 설계다. 실제 attach하지 않았고
[ADR-0012](../../adr/0012-crowdsec-appsec-origin-waf.md)가 활성 계획을 CrowdSec AppSec로
대체했으므로 구현 입력으로 사용하지 않는다.

- 같은 내부 canonical host와 기존 entrypoint 인증서를 사용한다. DNS, NAT, 인증서,
  entrypoint를 추가하거나 바꾸지 않는다.
- 새 `coraza-01` namespace의 digest 고정 `whoami` 하나에만 연결한다.
- host `k3s-01.imcherry5778.xyz`와 exact prefix `/coraza-01/control`의 조합은 같은
  backend의 무보호 성능 대조 route로 두고, `/coraza-01/waf` route만 middleware를
  참조한다.
- 기존 공개 route, Keycloak, NetBird, 관리 UI에는 참조를 추가하지 않는다.
- policy는 `SecRuleEngine On`, request body 검사, response body 검사 끔, CRS PL1,
  inbound anomaly threshold 5로 시작한다.
- 예외는 exact `/coraza-01/waf/exception`과 exact `User-Agent: masscan`이 모두 일치할
  때만 CRS `913100` 하나를 transaction 범위에서 제거한다. 같은 path의 다른 scanner
  User-Agent와 다른 path의 `masscan`은 계속 차단돼야 한다.

기능 gate는 정상 요청 200, `masscan` 대표 CRS 913100 요청 403, exact 예외 200,
예외와 한 조건만 다른 두 요청 403, control route의 공격형 요청 200을 모두 요구한다.

성능 gate는 같은 client와 backend에서 control/WAF 각각 warm-up 뒤 1,000 GET,
concurrency 10을 3회 수행한다. 정상 요청 실패율 0%, WAF p95가 control p95보다 20ms 넘게
늘지 않고 절대 100ms 이하이며, Traefik 평균 CPU 증분 750m 이하·peak 1000m 이하를
요구한다. 알려진 WASM memory 위험 때문에 세 round 뒤 60초 idle RSS가 사전값보다
64Mi 이상 남거나 round별 단조 증가하면 실패다. Pod restart, Node CPU 50% 이상,
비정상 Pod, 기존 HTTPS/301 회귀도 즉시 rollback 조건이다.

## 폐기 판정과 재검토 조건

현재 artifact를 HelmChartConfig에 등록해 실제 route를 attach하면 유일한 Traefik을
CrashLoop에 넣을 수 있다. 기존 route가 0개여도 ingress TLS와 이후 모든 HTTP 앱의 단일
controller이므로 이 중단은 허용하지 않는다. direct connector 경로는 폐기하며 다음 중
하나가 충족돼도 기존 작업을 재개하지 않고 새 ADR·새 작업에서 재채택 여부를 결정한다.

1. Coraza connector가 새 signed/tagged release와 고정 archive hash를 제공하고 Traefik
   3.7.4에서 최소 middleware 및 full CRS 시험을 통과한다.
2. packaged Traefik의 정식 upgrade가 같은 `v0.3.0`을 호환하며 INGRESS-01 전체 회귀를
   별도 작업에서 통과한다.

unreleased branch 직접 build, 임의 fork, hash 없는 archive, Traefik downgrade, 두 번째
ingress controller와 sidecar WAF는 `CORAZA-01`의 대체 경로가 아니다.

CORAZA-01은 라이브 HelmChartConfig·route·namespace를 만들지 않았으므로 제거할 라이브
자원과 rollback은 없다. 이 evidence는 WAF-DESIGN-01 main commit에 보존한 뒤 실패 branch와
worktree를 삭제할 수 있게 하는 기록이다. CrowdSec AppSec의 향후 rollback은 ADR-0012와
`CROWDSEC-01`이 별도로 소유한다.
