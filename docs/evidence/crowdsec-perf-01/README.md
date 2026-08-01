# CROWDSEC-PERF-01 성능 측정 계약 진단

## 결론

`CROWDSEC-FIX-01`의 약 `333ms` p95는 WAF 처리시간이 아니라 각 요청이 DNS·TCP·TLS를
모두 새로 만든 cold-connection 측정값이었다. ADR-0012의 p95 증분 `20ms` 이하·절대
`100ms` 이하 기준은 완화하지 않는다. 같은 client·backend에서 concurrency 10에 대응하는
10개 HTTP/2 연결을 먼저 수립하고, 각 연결의 첫 transfer를 제외한 총 1,000건을 3회
측정하는 것을 “warm-up 뒤”의 고정 계약으로 삼는다. cold DNS·TCP·TLS는 별도 진단 표로
남긴다.

이 결과는 rollback 상태의 존재하지 않는 CrowdSec control path가 반환하는 strict TLS
`404`를 사용한 측정 방법 진단이다. WAF가 없으므로 `CROWDSEC-FIX-01`의 성능 합격 증거가
아니다. 다음 enablement에서 control과 WAF를 모두 같은 방식으로 다시 측정해야 한다.

## 범위와 불변 조건

- 기준 Git SHA: rollback `f4841207ca71901566117a03c3c8998b42bfafef`
- 측정 시각: 2026-08-01T16:58:12+09:00
- client 경로: `10.10.20.10 dev tailscale0`, source `100.64.0.1`
- 10회 ping: loss 0%, min/avg/max/mdev
  `69.885/72.472/78.163/2.434ms`
- URL: `https://k3s-01.imcherry5778.xyz/crowdsec-01/control`
- 주소와 기대 status: `10.10.20.10`, `404`
- client curl: `8.18.0`, HTTP/2 사용, 인증서 검증 비활성화 옵션 없음

측정 전후 다음 값은 byte-for-byte 같은 JSON이었다.

- `platform-root`, `ingress`: target `main`, revision rollback SHA,
  `Synced/Healthy`
- `HelmChartConfig/traefik`: generation `9`, resourceVersion `62406`
- Traefik: Pod 1개, UID `30abf3ac-5239-498e-b2e1-e445f17ea9c5`, restart `0`,
  Ready, image digest
  `sha256:fcdef599e6259359833dd2e1d49f9e964f66825d69bd3dd468f51102ce013d03`

HelmChartConfig, Deployment, Pod, route, Argo Application을 쓰거나 재기동하지 않았다.
CrowdSec Application·namespace·Secret은 rollback 상태 그대로 없었다. DNS·인증서·entrypoint,
Cloudflare·OPNsense·k3s server도 변경하지 않았다.

## 재현 방법

저장소 밖 trusted `known_hosts`를 사용한다. 결과 디렉터리는 새 경로여야 하며 스크립트는
기존 경로를 덮어쓰지 않는다.

```bash
export CROWDSEC_PERF_URL=https://k3s-01.imcherry5778.xyz/crowdsec-01/control
export CROWDSEC_PERF_EXPECTED_STATUS=404
export CROWDSEC_PERF_CONNECT_IP=10.10.20.10
export K3S_SSH_TARGET=rocky@k3s-01.imcherry5778.xyz
export K3S_SSH_KNOWN_HOSTS=<저장소-밖-trusted-known_hosts>

docs/evidence/crowdsec-perf-01/measure-ingress-latency.sh \
  /tmp/crowdsec-perf-01-result
```

스크립트는 다음을 차례로 수행한다.

1. client에서 DNS 포함 fresh connection 1,000건, concurrency 10
2. `--resolve`로 DNS만 고정한 fresh TCP/TLS connection 1,000건, concurrency 10
3. worker 10개가 각자 HTTP/2 연결을 warm-up한 뒤 100건씩 재사용, 총 1,000건을 3회
4. k3s node에서 strict TLS fresh connection 100건
5. 모든 표본의 status, remote IP, HTTP/2와 연결 수 및 전후 live 불변 조건 검증

`time_*`의 차로 DNS, TCP, TLS, 응답 구간을 계산한다. 각 column의 p95는 서로 다른 요청의
값일 수 있으므로 phase p95를 더해 total p95로 해석하면 안 된다.

## 정식 결과

전체 원본 표는 [results.tsv](results.tsv)에 있다.

| mode | count | failures | new connections | p95 total |
|---|---:|---:|---:|---:|
| fresh DNS/TCP/TLS | 1,000 | 0 | 1,000 | 336.934ms |
| fresh TCP/TLS, DNS 고정 | 1,000 | 0 | 1,000 | 360.639ms |
| reuse round 1 | 1,000 | 0 | 0 | 72.517ms |
| reuse round 2 | 1,000 | 0 | 0 | 72.827ms |
| reuse round 3 | 1,000 | 0 | 0 | 72.867ms |
| node fresh TCP/TLS | 100 | 0 | 100 | 15.549ms |

`fresh-resolve`가 `fresh-dns`보다 느린 것은 두 독립 표본의 TCP/TLS tail 변동이며 DNS가
음수 비용이라는 뜻이 아니다. 판단 근거는 각 fresh 표본에서 요청 수와 새 연결 수가
1:1이고, 세 reuse 표본에서는 새 연결이 0이며 p95가 경로 RTT 수준으로 반복됐다는 점이다.

최신 `origin/main` rebase 뒤 같은 스크립트를 다시 실행한 [통합 직전 결과](post-rebase-results.tsv)도
전체 5,100건을 통과했다. 세 reuse round p95는 `73.821ms`, `74.154ms`, `73.666ms`이고
각 1,000건의 실패와 측정 구간 신규 연결은 모두 0이었다. 두 정식 실행 사이에도 Argo,
HCC와 Traefik Pod의 불변 JSON은 같았다. 이 재검증은 2026-08-01T17:04:32+09:00에
시작했고 10회 ping 평균은 `71.000ms`였다.

## 기존 실패의 판정

수정 enablement의 control/WAF 도구는 `seq 1000 | xargs -P10 ... curl` 구조였다. 사전
warm-up도 별도 `curl` 50회였으므로 측정에 사용할 연결 pool을 만들지 못했다. round 1과
2의 WAF 증분 `-1.521ms`, `3.348ms`는 WAF 자체가 작을 가능성을 보이지만, 당시 WAF 절대
p95는 `100ms`를 넘었으므로 rollback 결정은 ADR에 맞았다. 이 진단으로 과거 결과를
소급해 합격 처리하지 않는다.

## 다음 enablement gate

`CROWDSEC-FIX-01`은 다시 적용하기 전에 ADR-0012의 다섯 항목과 적용 시점을 새로 제시해
승인받는다. 기능·exact 예외·control, CPU·RSS, AppSec fail-closed, 기존 ingress 회귀,
Argo rollback·Git revert 기준은 그대로 유지한다. 성능만 다음처럼 보정한다.

- control/WAF 각각 10개 warmed persistent HTTP/2 연결, 1,000건, 3회
- 정상 status·remote IP·HTTP/2·측정 구간 신규 연결 0, 실패율 0%
- WAF p95-control p95 `≤20ms`, WAF p95 `≤100ms`
- cold DNS/TCP/TLS 진단은 별도 기록하고 WAF 처리 gate와 분리

완료 전에는 `CROWDSEC-FIX-01`을 `DONE`이나 `EDGE-01`의 충족 선행으로 취급하지 않는다.
