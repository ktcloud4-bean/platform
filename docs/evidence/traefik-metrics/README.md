# TRAEFIK-METRICS private Prometheus scrape 증거

2026-08-12에 immutable GitOps revision으로 한 번 검증한 결과다. 검증 중 생성한
private scrape 리소스와 router label 설정은 cleanup pointer로 prune한 뒤 literal `main`으로
복구했다. metric label 값, Secret 값, request path와 client IP는 기록하지 않았다.

| 확인 항목 | 결과 | 판정 |
|---|---|---|
| immutable Argo 상태 | root `1eb27f97ed7594750bb0390b2e46b9086045eb27`, ingress/obs `803ec8f4c6d03f0af3b3cbdfd936521ffa6b1812`, 모두 `Synced/Healthy` | 통과 |
| Traefik 설정·노출 경계 | router label 활성, header label 0, `traefik-metrics`는 selector가 Traefik Pod인 `ClusterIP:9100` 하나, 기존 external Service는 `web:80`, `websecure:443` 유지 | 통과 |
| Prometheus 경로 | `release=obs` ServiceMonitor와 Prometheus→Traefik TCP 9100 exact egress, target `up=1` | 통과 |
| native metric | entrypoint 4, histogram 20, router 4, service 4 series; p95/p99 존재 | 통과 |
| 허용 label 이름 | entrypoint: `code`, `entrypoint`, `method`, `protocol`; router: `code`, `method`, `protocol`, `router`, `service`; service: `code`, `method`, `protocol`, `service` | 통과 |
| 민감 label | `path`, `client_ip`, `user`, `authorization`, `header` 없음 | 통과 |
| 용량 | head series `30442→30578`, Prometheus working set `382730240→406847488` bytes, k3s available RAM `14377861120→14172504064` bytes, swap `0` | 통과 |
| 범위 | kube-system Service `3→4`, obs ServiceMonitor `10→11`, NetworkPolicy `13`, PVC `2`, Secret `9`, Ingress `0` | 통과 |

정적 검증으로 `bash -n`(적용·검증기), ingress/obs/root kustomize render와 `git diff --check`도
통과했다.

## Rollback

cleanup root `22691506b50cc89f02371db270a9ccbc7a9908a8`에서 private Service,
ServiceMonitor, Prometheus egress 추가 규칙, Traefik router label 설정이 제거됐음을 확인했다.
그 뒤 literal `main` revision `a6d785cefbd65c67e690a161e5ae68fdee39c210`에서
`platform-root`, `ingress`, `obs` 모두 `Synced/Healthy`로 복구됐다.
