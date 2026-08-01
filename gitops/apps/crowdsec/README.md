# CROWDSEC-FIX-01 CrowdSec AppSec PoC

이 디렉터리는 ADR-0012의 route-scoped CrowdSec AppSec(Coraza + OWASP CRS) PoC를
소유한다. 전용 `crowdsec-01` namespace의 LAPI·AppSec·digest 고정 `whoami`와 내부 test
route만 만든다. Community Blocklist, Console enrollment, IP decision/remediation,
CAPTCHA, firewall·Cloudflare bouncer와 OPNsense 연동은 이 chart에 없다.

upstream CrowdSec chart `0.24.0`을 저장소 안에 vendoring하고
[`values-crowdsec-01.yaml`](values-crowdsec-01.yaml)만 활성 값으로 사용한다. 원본 사용법은
[`UPSTREAM-README.md`](UPSTREAM-README.md)에 보존했다. vendored chart의 의도적 변경은
다음뿐이다.

- AppSec acquisition을 floating value가 아니라 추적되는
  [`files/appsec/acquis.yaml`](files/appsec/acquis.yaml)에서 읽는다.
- upstream test Pod의 floating `curl` image와 사용하지 않는 online updater ServiceAccount를
  렌더하지 않는다.
- CRS 49개와 manifest를 deterministic `tar.gz`로 고정하고 `ConfigMap.binaryData`로
  전달한다. init container는 archive SHA-256을 먼저 확인한 뒤 writable `emptyDir`에
  추출하고 49개 개별 hash를 다시 확인한다. 이를 CrowdSec의 Coraza `RootFS`인
  `/var/lib/crowdsec/data`에 마운트한다. 이 경로가
  아니면 CRS `@pmFromFile`이 데이터를 읽지 못하며, `docker_start`가 GeoIP link를
  추가하므로 ConfigMap을 그 경로에 직접 read-only mount할 수도 없다.
- 전용 snapshot ConfigMap, test/control route, NetworkPolicy를 추가한다.

## 공급망 고정

단일 원본은 [`release-metadata.env`](release-metadata.env),
[`crs-snapshot.SHA256`](crs-snapshot.SHA256)과
[`crs-snapshot.tar.gz.SHA256`](crs-snapshot.tar.gz.SHA256)이다.

- CrowdSec `v1.7.8`, source commit `632274597a88a6b01ed41c0e6affca0f87ff26df`, image
  digest `sha256:2f527c9bb8b367120eb08b82890aa912ce96bfa1ada93dda0721700e4b4e0dde`, MIT
- official Helm chart `0.24.0`, tag commit
  `e2976c41c892a34ecdb54301a44c9150bc6ddb45`, release archive SHA-256
  `fa383e922a46536db813a514e2bf082bab355081bab4aefaa964fbdbbfd7f8f1`, MIT
- community Traefik bouncer `v1.7.1`, source commit
  `bef5dfaadbb07381af02ec4e7391e49214ebf953`, registry archive SHA-256
  `500739fc1600c12a651433b13a81693470cd336dbc7864cb85ee42098c93d884`, Apache-2.0
- CrowdSec Hub commit `3e948c376e84e7dfc0d0cb3642301780434801b2`, CRS YAML 두 개의
  content hash와 Hub data 49개의 개별 SHA-256
- 위 49개와 manifest를 재현 가능한 ustar+gzip으로 묶은 archive SHA-256
  `235dc3bc50c3c861ba9561487c72d6562e8c6501467314a6618781a37bdaede6`
- CrowdSec fork Coraza `v3.3.3-crowdsec.20251113`와 OWASP CRS `v4.0.0-rc1`,
  Apache-2.0
- packaged Traefik `3.7.4`, live image digest
  `sha256:fcdef599e6259359833dd2e1d49f9e964f66825d69bd3dd468f51102ce013d03`

Hub URL 자체는 release URL이 아니므로 실행 중 내려받지 않는다. capture한 49개 파일을
Git에 넣고 manifest hash까지 고정했다. `NO_HUB_UPGRADE=true`, 빈 `COLLECTIONS`, 빈
`APPSEC_CONFIGS`와 빈 `APPSEC_RULES`로 자동 update와 floating collection을 막는다.

```bash
./gitops/tools/crowdsec-01/verify-supply-chain.sh
./gitops/tools/crowdsec-01/verify-supply-chain.sh --network
K3S_SSH_TARGET=rocky@k3s-01.imcherry5778.xyz \
K3S_SSH_KNOWN_HOSTS="$HOME/.ssh/known_hosts" \
./docs/evidence/crowdsec-01/verify-packaged-traefik-chart.sh
./docs/evidence/crowdsec-01/verify-local-compat.sh
K3S_SSH_TARGET=rocky@k3s-01.imcherry5778.xyz \
K3S_SSH_KNOWN_HOSTS="$HOME/.ssh/known_hosts" \
./docs/evidence/crowdsec-01/verify-kubernetes-roundtrip.sh
```

두 번째 명령은 현재 upstream bytes가 capture 당시 hash와 같은지도 확인한다. 향후 upstream
drift로 이 검사가 실패해도 vendored snapshot은 바뀌지 않으며, 새 검토 없이 update하지
않는다.

## 정확한 attach 경계

기존 `websecure` entrypoint와 canonical 내부 host는 바꾸지 않는다.

- control: `Host(k3s-01.imcherry5778.xyz) && PathPrefix(/crowdsec-01/control)`
- WAF: `Host(k3s-01.imcherry5778.xyz) && PathPrefix(/crowdsec-01/waf)`
- middleware는 WAF route만 참조한다. 두 route의 backend는 동일한 digest 고정 `whoami`다.
- 예외는 exact URI `/crowdsec-01/waf/exception`과 exact `User-Agent: masscan`이 모두
  일치하는 transaction에서 CRS rule ID `913100` 하나만 제거한다.
- 같은 path의 `nmap-nse`, query가 붙거나 다른 path인 `masscan`은 403이어야 하고
  control의 같은 `masscan`은 200이어야 한다.

bouncer는 `crowdsecMode: appsec`이며 IP decision을 조회·소비하지 않는다. AppSec 연결
실패, unreadable body와 timeout은 WAF test route에서 403 fail-closed다. middleware가 없는
control 및 기존 route에는 이 fail policy가 적용되지 않는다.

AppSec config의 `default_remediation: ban`은 현재 HTTP transaction을 403으로 끝내는
CrowdSec AppSec 내부 action 이름이다. LAPI에 IP ban을 기록한다는 뜻이 아니다. LAPI의
`profiles.yaml`은 항상 false인 filter와 빈 `decisions`를 사용하고, NetworkPolicy는
Traefik→LAPI 통신 자체를 허용하지 않는다. 따라서 이 PoC는 IP remediation decision을
생성하거나 소비하지 않는다.

## Secret과 승인 gate

`crowdsec-01/crowdsec-01-bootstrap`과 `kube-system/crowdsec-01-bouncer`는 Git 밖에서만
주입한다. raw 값, Secret YAML, kubeconfig를 출력하거나 커밋하지 않는다.

ADR-0012의 5개 항목에 대한 별도 승인은 2026-08-01 받았다. 다만 KC-01의 완료 여부와
Traefik 재기동 시점을 적용 직전에 다시 확인하기 전에는 아래 명령을 실행하지 않는다.

```bash
./gitops/tools/crowdsec-01/prepare-secret-input.sh
K3S_SSH_TARGET=rocky@k3s-01.imcherry5778.xyz \
K3S_SSH_KNOWN_HOSTS="$HOME/.ssh/known_hosts" \
./gitops/tools/crowdsec-01/inject-secrets.sh
```

생성되는 `.env`는 Git 제외·mode `0600`이며 스크립트는 파일을 `source`하지 않는다.
`platform-root.targetRevision`은 `main`을 유지한다. branch pointer를 사용하지 않고 최종
선언이 main에 통합된 뒤에만 Argo를 동기화한다.

## live gate

기능 검증은 정상 WAF 200, `masscan` 403, exact 예외 200, 한 조건만 다른 세 요청 403,
control 공격 200과 LAPI decision 0개를 모두 요구한다. AppSec Pod를 한 번 제거해 실제
unreachable window에서 WAF 403·control 200을 확인하고 새 AppSec Pod Ready 뒤 WAF 200을
재확인한다. Traefik Pod를 수동 수정·삭제하지 않는다.

성능은 같은 client/backend에서 concurrency 10에 대응하는 지속 HTTP/2 연결 10개를 먼저
만들고 각 연결의 첫 transfer를 버린 뒤, control/WAF 각각 1,000 GET을 3 round 측정한다.
[`benchmark-live.sh`](../../../docs/evidence/crowdsec-01/benchmark-live.sh)는 Kubernetes를
읽기만 하며 다음 gate를 자동 판정한다. cold DNS·TCP·TLS는
[`CROWDSEC-PERF-01`](../../../docs/evidence/crowdsec-perf-01/README.md)의 별도 진단으로
분리하고 WAF 처리시간에 합산하지 않는다.

- 정상 요청 실패율 0%, remote IP·HTTP/2 일치, 측정 구간 신규 연결 0
- 각 round WAF p95 증분 20ms 이하, WAF p95 절대 100ms 이하
- Traefik 평균 CPU 증분 750m 이하, WAF peak 1000m 이하
- 60초 idle RSS 증가 64Mi 미만이며 round 종료 RSS가 3회 연속 증가하지 않음
- benchmark 중 Traefik UID/restartCount 불변, Node CPU 50% 미만

별도로 기존 ingress 전체 object spec, strict HTTPS 인증서 fingerprint, HTTP 301의 원래
path/query 보존, source IP/XFF 위조 방어, Keycloak을 포함한 기존 route, Argo
`platform-root`·`ingress`·`crowdsec`의 `Synced/Healthy`, Node Ready·DiskPressure 없음과
전체 비정상 Pod 0개를 전후 대조한다. 적용 직전
[`capture-live-baseline.sh`](../../../docs/evidence/crowdsec-01/capture-live-baseline.sh)로
기준선을 만들고 적용 뒤
[`verify-live.sh`](../../../docs/evidence/crowdsec-01/verify-live.sh)로 같은 object와 경계를
비교한다. AppSec 장애 시험은 Pod 삭제를 수행하므로 승인 확인 환경변수를 요구하는
[`verify-appsec-failure.sh`](../../../docs/evidence/crowdsec-01/verify-appsec-failure.sh)로
분리했다. KC-01 자체 runbook의 Keycloak 로그인 검증도 별도로 재실행한다.

## rollback

fail gate 하나라도 발생하면 새 route만 우회하는 것으로 완료하지 않는다.

1. `CROWDSEC-FIX-01` 수정 enablement commit을 `git revert`한 단일 rollback commit으로
   main에 push한다. live gate 실패 시 evidence/`DONE` 커밋은 만들지 않는다.
2. `platform-root`를 sync해 `crowdsec` child Application을 finalizer로 prune하고,
   `ingress`를 sync해 HelmChartConfig의 plugin registration과 secret mount를 제거한다.
   먼저 통합한 비밀 없는 `AppProject/crowdsec`는 삭제하지 않는다.
3. packaged controller가 기존 image로 정확히 한 번 재생성되고 ingress Application과 root가
   revert main SHA에서 `Synced/Healthy`인지 확인한다.
4. 기존 인증서 fingerprint, strict HTTPS, 301, source IP/XFF, 기존 route를 재검증한다.
5. Traefik이 secret mount를 제거한 뒤 `kube-system/crowdsec-01-bouncer`를 삭제한다.
   `crowdsec-01` namespace의 bootstrap secret은 namespace prune과 함께 제거된다.

Application이 사라지기 전 AppProject를 제거하거나 finalizer를 강제 삭제하는 절차는
rollback이 아니다. merge 후 rollback도 공개 main 이력을 재작성하지 않고 수정 enablement
commit 하나에 대한 새 `git revert` commit으로 수행한다.

k3s server 재시작·중지, Cloudflare·OPNsense·DNS·인증서·entrypoint 변경은 rollback에도
포함하지 않는다.
