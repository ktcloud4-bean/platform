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
