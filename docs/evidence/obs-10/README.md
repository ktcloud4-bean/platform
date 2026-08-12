# OBS-10 Traefik Traffic Drill-down 사전 인벤토리

2026-08-11에 실행한 read-only Prometheus 인벤토리 결과다. 이 결과는 대시보드 적용 전 한 번만
판정했으며, synthetic traffic·Traefik 설정·HelmChartConfig·Pod·ServiceMonitor·NetworkPolicy·PVC·Secret·Ingress는
변경하지 않았다.

| 확인 항목 | 결과 | 판정 |
|---|---:|---|
| Prometheus active target (`job=traefik` 또는 `service=traefik`) | 0 | 미수집 |
| Prometheus metric name `traefik_*` | 0 | 미수집 |
| Traefik Service port | `web:80`, `websecure:443` | metrics port 없음 |
| Traefik container metric args | `--entryPoints.metrics.address=:9100/tcp`, `--metrics.prometheus=true`, `--metrics.prometheus.entrypoint=metrics` | metric entrypoint는 실행 중 |

Traefik은 metric entrypoint를 실행하지만 Prometheus가 읽을 private Service/ServiceMonitor 경로가 없으므로,
공식 dashboard ID 17346을 가져오거나 `OBS-05`의 세 요약 패널 link를 바꾸지 않았다. 지금 적용하면
정상적인 빈 상태가 아니라 모든 요구 패널이 `No data`가 된다.

따라서 `OBS-10`은 `TRAEFIK-METRICS`를 선행으로 추가해 `BLOCKED`로 전환했다. 후속 작업은 기존
외부 serving Service에 TCP 9100을 열지 않고 private metrics Service와 정확한 scrape 경계만 만든 뒤,
실제 metric label 이름을 다시 인벤토리한다. `OBS-10`은 그 결과를 사용해 dashboard를 vendor한다.

인벤토리 직후 literal `main`의 `platform-root`와 `obs`는 모두 revision
`1f69277155265b76522ad40dbac18f8cd805fee8`에서 `Synced/Healthy`였다.

## 2026-08-12 재개 인벤토리와 vendoring 범위

`TRAEFIK-METRICS` 완료 뒤 read-only Prometheus inventory를 한 번 다시 실행했다. `job=traefik`
target은 `up=1` 한 건이었고, 필요한 native metric의 series 수와 **label 이름만** 다음과 같이
확인했다. label 값, request path, client IP, 사용자, 인증 header는 조회하거나 저장하지 않았다.

| metric | series | 확인한 label 이름 |
|---|---:|---|
| `traefik_entrypoint_requests_total` | 87 | `code`, `entrypoint`, `method`, `protocol` 등 |
| `traefik_entrypoint_request_duration_seconds_bucket` | 435 | 위 label과 `le` |
| `traefik_router_requests_total` | 35 | `router`, `service`, `code`, `method`, `protocol` 등 |
| `traefik_service_requests_total` | 108 | `service`, `code`, `method`, `protocol` 등 |

`histogram_quantile` 기반 p95/p99, entrypoint별 QPS·상태군, router/service별 `topk` 대표
query는 모두 하나 이상의 결과를 냈다. 따라서 upstream [Traefik Official Standalone Dashboard
ID 17346 revision 9](https://grafana.com/grafana/dashboards/17346-traefik-official-standalone-dashboard/)의
download SHA-256 `3ad329d2737120f32f67aab083f245b554ea5c4ec8378feee7196ef6bb9f7da9`를 고정 기준으로
삼았다.

그 템플릿에서 QPS·HTTP 상태/5xx·p95/p99·entrypoint/router/service 상위 항목만 남기고,
datasource는 `prometheus` UID로 고정했다. 기존 `obs-05-core-services` ConfigMap은 이미 Grafana
file provider가 읽는 volume이므로, 새 `traefik-traffic.json` key를 같은 volume에 추가해 Grafana나
Traefik Pod를 재기동하지 않는다. OBS-05의 세 Traefik summary panel은 새 dashboard로 가는 단일
Markdown link로 교체한다. metric이 없을 때 값을 꾸미는 `or vector(0)` fallback은 새 dashboard에
넣지 않는다.

## Immutable live 검증

검증 root pointer `e8c0bc9e4c4f812d7cc588126ff89698671b70d1`와 OBS config
`8603a27a231e4f170bcbf93f90a0d81c8933accc`에서 `platform-root`·`obs` 모두
`Synced/Healthy`를 확인했다. Grafana API의 read-only model은 다음을 모두 만족했다.

- UID `obs-10-traefik-traffic`, Prometheus UID `prometheus`, schema 41, panel 7개/query 8개
- QPS, HTTP status/5xx ratio, p95/p99, Top entrypoint/router/service만 존재
- 변수는 실측 label의 `entrypoint`, `router`, `service`뿐이며 `or vector(0)` 및 민감 label 참조 없음
- OBS-05는 Traefik summary metric query 0건과 새 UID로 가는 Markdown link 1건

검증 전후 Traefik Pod UID는 `c92e3e28-a355-480d-a7c4-c3f6bb83a8ca`, Grafana Pod UID는
`c8a4428b-4f8c-4803-bf01-1e7f418e5e1c`로 같았다. `obs`의 Service 9, ServiceMonitor 11,
NetworkPolicy 13, PVC 2, Secret 9, Ingress 0도 변함없었다. root는 검증 뒤 literal `main`
`32a82b8791f46f40cac51fa69b68f48fe923a6f3`으로 복구했다.
