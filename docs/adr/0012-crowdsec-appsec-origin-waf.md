# ADR-0012: 오리진 WAF를 CrowdSec AppSec 경로로 전환

- 상태: `Accepted`
- 날짜: 2026-08-01
- 관련 작업: `WAF-DESIGN-01`, `CORAZA-01`, `CROWDSEC-01`, `CROWDSEC-PERF-01`,
  `CROWDSEC-FIX-01`, `EDGE-01`, `AUDIT-01`
- 부분 대체: ADR-0007의 탐지 계층·배포 순서는 유지하고 Traefik process 내부의 direct
  Coraza HTTP-WASM connector 선택만 대체한다.

## 배경

초기 설계는 k3s packaged Traefik의 HTTP-WASM middleware로 Coraza와 OWASP CRS를 직접
실행하려 했다. `CORAZA-01`은 현재 Traefik image와 공식 connector catalog release,
archive hash를 고정해 라이브 밖에서 검증했다. plugin 정적 load만 한 control은 HTTP
200이지만 최소 Coraza middleware와 full CRS middleware를 attach하면 OOM 없이 Traefik이
`split stack overflow`로 종료됐다. 유일한 ingress controller에 적용하면 모든 HTTP
경로와 인증서 제공을 함께 중단할 수 있어 라이브 HelmChartConfig와 route는 만들지 않았다.
정확한 고정값과 재현 자산은 [CORAZA-01 폐기 증거](../evidence/coraza-01/README.md)에 남긴다.

CrowdSec Security Engine의 AppSec component는 별도 HTTP 검사 endpoint에서 WAF 규칙을
처리하고 OWASP CRS 구성을 제공한다. Traefik은 community bouncer middleware로 요청을
전달하고 판정만 적용할 수 있으므로, Coraza WASM을 유일한 Traefik process 안에서 직접
실행하는 실패 경계를 피할 수 있다. 다만 이 bouncer도 first-party가 아닌 experimental
Traefik plugin이며 등록은 install configuration 변경과 Pod 재기동을 요구한다.

## 결정

오리진 L7 WAF의 다음 PoC는 CrowdSec AppSec(Coraza + OWASP CRS)로 수행한다. AppSec
process와 rule engine은 전용 namespace에 두고, Traefik community bouncer는 정확한 내부
test route 하나의 middleware로만 AppSec 판정을 연결한다. 같은 backend에 middleware가
없는 control route를 둬 기능·성능·장애 영향을 대조한다.

`CROWDSEC-01`은 WAF 기능만 소유한다. Community Blocklist, 외부 Console enrollment,
자동 IP ban·CAPTCHA, firewall·Cloudflare bouncer와 OPNsense 연동은 활성화하지 않는다.
plugin이 내부 LAPI를 요구하면 전용 secret과 최소 통신만 허용하고 IP remediation
decision은 만들거나 소비하지 않는다. secret 원문은 Git에 두지 않는다.

PoC 시작 시 CrowdSec image·chart, bouncer module, version·archive hash, Coraza·CRS를
포함한 Hub rule snapshot을 다시 조사해 immutable digest·commit·content hash로 고정한다.
Hub 자동 update와 부동 collection은 검증 중 사용하지 않는다. packaged Traefik은 지원되는
`HelmChartConfig`만 사용하며 k3s가 생성한 HelmChart나 실행 Pod를 수동 수정하지 않는다.

bouncer 정적 등록은 route-scoped attach와 달리 유일한 Traefik Pod를 재기동하므로 실제
적용 전에 다음을 사용자에게 제시하고 별도 승인을 받는다.

1. module 출처·license·version·hash와 현재 packaged Traefik 격리 호환 결과
2. CrowdSec image·chart digest와 AppSec/Coraza/CRS rule snapshot
3. exact attach host/path, control path, rule ID 단위의 exact 예외 조건
4. 정상·차단·예외 요청, p95·CPU·RSS 기준과 기존 ingress 전체 회귀 항목
5. AppSec 장애 시 test route의 fail policy, Argo rollback과 merge 뒤 Git revert 절차

승인 후에도 middleware는 전용 내부 route에만 붙인다. 정상 요청 200, 대표 CRS 요청 403,
예외의 모든 조건이 일치한 요청만 200, 한 조건이라도 다른 요청은 403이어야 한다. control
route의 같은 공격형 요청은 backend까지 도달해야 한다. 기존 route·Keycloak·NetBird·관리
UI, Cloudflare, OPNsense NAT·DNS, 인증서와 Traefik entrypoint는 변경하지 않는다.

성능 기준은 같은 client·backend에서 warm-up 뒤 control/WAF 각각 1,000 GET, concurrency
10을 3회 비교한다. 정상 요청 실패율 0%, WAF p95 증분 20ms 이하·절대 100ms 이하,
Traefik 평균 CPU 증분 750m 이하·peak 1000m 이하를 요구한다. 세 round 뒤 60초 idle RSS가
사전값보다 64Mi 이상 남거나 단조 증가하면 실패다. restart, Node CPU 50% 이상, 비정상 Pod,
기존 strict HTTPS·301·source IP·인증서 회귀도 즉시 rollback 조건이다.

rollback은 시험 Application/namespace와 middleware를 prune하고 HelmChartConfig에서
plugin 등록·secret mount만 제거해 Traefik을 기존 image·설정으로 재생성한다. Argo root와
ingress가 시험 전 main revision에서 `Synced/Healthy`, Traefik restart 이후 기존 인증서·
HTTPS·301·source IP 경계가 회복돼야 완료다. merge 뒤 제거 시험은 `CROWDSEC-01` squash
commit 하나를 `git revert`해 같은 경계를 재검증한다.

### 2026-08-01 적용 결함 보정

`CROWDSEC-01` 최초 enablement는 YAML block scalar chomp로 CRS 49개의 마지막
LF가 사라져 AppSec init hash gate를 통과하지 못했고, 즉시 main에서 revert했다.
이 적용에서 root가 AppProject를 Application보다 먼저 prune해 finalizer가
`project not found`로 멈추는 rollback 순서 결함도 발견했다.

`CROWDSEC-FIX-01`은 다음 불변 경계로 두 결함을 보정한다.

1. 비밀이 없는 최소 `AppProject/crowdsec`는 별도 기반 커밋으로 먼저 적용하고
   enablement rollback 뒤에도 남긴다. rollback은 Application finalizer가 namespace와
   하위 자원을 모두 prune한 뒤 완료돼야 하며 finalizer를 강제 제거하지 않는다.
2. CRS snapshot은 YAML text scalar로 재직렬화하지 않고 deterministic binary
   archive와 archive SHA-256, 내부 49개 파일 manifest로 고정한다. 격리
   Kubernetes API에 저장한 뒤 다시 읽은 archive·파일 hash가 원본과 같아야
   enablement를 허용한다.
3. 사용자가 승인한 main 순서는 영구 AppProject 기반, 수정 enablement,
   live evidence·`DONE` 세 커밋이다. gate 실패 시 수정 enablement 커밋만
   `git revert`하고 영구 AppProject는 유지한다.

이 보정은 bouncer, route, AppSec policy, 금지 항목과 성능 기준을 바꾸지 않는다.

### 2026-08-01 성능 측정 계약 보정

수정 enablement의 control/WAF 측정은 각 요청마다 별도 `curl` process를 실행해 DNS 조회와
TCP·TLS 연결을 1,000번 새로 만들었다. 그 결과 control과 WAF p95가 모두 약 `333ms`였고
두 round의 WAF 증분은 각각 `-1.521ms`, `3.348ms`였지만 절대 `100ms` gate를 넘었다.
승인된 기준을 사후 완화하지 않고 enablement를 즉시 revert했다.

`CROWDSEC-PERF-01` 읽기 전용 진단에서 측정 client와 ingress 사이 경로는 `tailscale0`,
10회 ping 평균은 `72.472ms`였다. rollback 상태의 같은 HTTPS 경로를 1,000회 측정하면
매번 DNS·TCP·TLS를 새로 만든 p95는 `336.934ms`, DNS만 고정하고 TCP·TLS를 새로 만든
p95는 `360.639ms`였다. 반면 concurrency 10의 HTTP/2 연결을 먼저 만들고 각 연결의 첫
transfer를 버린 뒤 총 1,000 transfer를 재사용한 세 round p95는 `72.517ms`, `72.827ms`,
`72.867ms`였고 측정 중 새 연결과 실패는 모두 0이었다. k3s node에서 같은 인증서와
주소로 수행한 100개의 새 TLS 연결 p95는 `15.549ms`였다.

따라서 기존의 WAF p95 증분 `20ms` 이하·절대 `100ms` 이하 기준은 그대로 유지하되,
“warm-up 뒤”를 다음과 같이 해석한다.

1. 같은 client·backend에서 concurrency 10에 대응하는 10개의 지속 HTTP/2 연결을 먼저
   수립하고 각 연결의 첫 transfer를 결과에서 제외한다.
2. control과 WAF 각각 총 1,000개의 정상 GET을 그 연결 pool에서 전송하고 이를 3회
   반복한다. 각 round는 HTTP 상태, remote IP, HTTP/2, 측정 구간의 신규 연결 0을 함께
   검증한다.
3. cold DNS·TCP·TLS 지연은 별도 진단 표로 기록하며 WAF 처리시간 합격·실패 판정에
   합산하지 않는다. phase별 percentile은 서로 다른 요청의 값일 수 있으므로 단순 합산하지
   않는다.
4. 이 보정은 rollback 상태의 측정 계약 진단일 뿐 WAF 성능 합격 증거가 아니다. 다음
   enablement는 기존 기능·CPU·RSS·장애·회귀 gate와 함께 보정된 방식으로 control/WAF를
   다시 측정하고, 정적 등록·유일한 Traefik Pod 재기동 전에 다섯 항목과 적용 시점을 다시
   승인받는다.

## 검토한 대안

- **direct Coraza HTTP-WASM 재시도:** 현재 고정 조합은 middleware 초기화만으로 ingress
  process를 종료한다. 새 connector와 현재 Traefik의 격리 성공 전에는 재시도하지 않는다.
- **두 번째 ingress controller 또는 WAF sidecar 추가:** 기본 Traefik 단일 controller
  원칙과 운영·인증서 경계를 늘리므로 이 전환 작업에서 채택하지 않는다.
- **CrowdSec IP reputation만 사용:** L3/L4 또는 IP decision은 HTTP body·CRS 검사가 아니며
  요구한 L7 WAF를 대체하지 못한다.
- **Cloudflare WAF만 사용:** 공개 경로에는 유효하지만 내부 direct ingress와 origin 도달
  후 검사를 대체하지 못하고 `EDGE-01` 전 공개 DNS/NAT도 만들 수 없다.

## 결과

- direct Coraza connector는 `DEFERRED`로 남고 CrowdSec AppSec PoC가 대체한다.
- Coraza와 CRS는 AppSec 내부 검사 엔진으로 남지만 Traefik process 안의 WASM은 제거된다.
- route attach는 좁지만 plugin 등록과 Traefik 재기동은 전역 영향이므로 별도 승인이 필요하다.
- first-party가 아닌 bouncer와 rule 공급망을 직접 고정·검증하는 부담이 생긴다.
- AppSec·bouncer 장애가 기존 route에 전파되지 않는지 rollback 포함 실제 검증해야 한다.

## 재검토 조건

- community bouncer가 유지 중단되거나 현재 Traefik plugin 정책과 호환되지 않는다.
- 고정 AppSec·CRS가 기능, 오탐, latency·CPU·RSS 또는 rollback gate를 통과하지 못한다.
- Traefik이 first-party WAF/API 또는 안정된 out-of-process 연동을 제공한다.
- direct Coraza connector가 현재 packaged Traefik에서 검증된 새 release를 제공한다.

## 근거

- [CrowdSec AppSec의 Coraza transaction 구현](https://github.com/crowdsecurity/crowdsec/blob/v1.7.8/pkg/appsec/tx.go)
- [CrowdSec AppSec data source](https://docs.crowdsec.net/docs/log_processor/data_sources/appsec/)
- [CrowdSec Traefik Kubernetes bouncer](https://docs.crowdsec.net/u/bouncers/traefik/)
- [CrowdSec Hub CRS configuration](https://app.crowdsec.net/hub/author/crowdsecurity/appsec-configurations/crs)
- [Traefik plugin install configuration](https://doc.traefik.io/traefik/reference/install-configuration/experimental/plugins/)
