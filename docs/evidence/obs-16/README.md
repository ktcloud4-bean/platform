# OBS-16 SeaweedFS·NetBird native metrics 증거

2026-08-13에 SeaweedFS와 NetBird의 이미 내장된 Prometheus endpoint를 관리망에서만
수집하고, PostgreSQL·SeaweedFS·NetBird가 실제 운영 화면과 경보 규칙의 소비처를 갖도록
검증한 결과다. Secret, S3 credential, OIDC token과 peer identity는 기록하지 않는다.

## 노출·권한 경계

- SeaweedFS master·volume·filer·S3는 `object-01` 관리 주소 `10.10.50.20`의
  TCP 9325·9326·9327·9328에만 bind한다. master·volume·filer의 systemd sandbox에는
  `10.10.20.10/32`만 추가해 host 내부 응답과 cross-VLAN 수집 경계를 함께 만족시킨다.
- NetBird management metrics는 `netbird-01` 관리 주소 `10.10.40.10:9090`에만 Docker
  publish한다. Traefik, public DNS, NAT와 별도 metrics credential은 추가하지 않는다.
- OPNsense `opt2` ingress는 k3s-01에서 위 다섯 endpoint만 exact TCP PASS로 둔다.
  생성 UUID·sequence·PF runtime은 완료 시점 snapshot과 함께 기록한다.

## 운영 소비처

- Grafana read-only `Service Native Metrics` (`obs-16-service-native-metrics`) dashboard가
  PostgreSQL reachability/transaction, SeaweedFS volume 사용량·여유·disk error, NetBird
  management stream·peer status update와 6개 target health를 표시한다.
- `NativeMetricsTargetDown`은 세 job 전체의 5분 `up=0`,
  `PostgreSQLDatabaseMetricsDown`은 `pg_up=0`을 경보로 만든다. baseline firing은 0건이어야
  하며 의도적 장애를 만들지 않는다.

## rollback

1. `infra/ansible/playbooks/seaweedfs-metrics-rollback.yml`과
   `netbird-metrics-rollback.yml`로 listener/publish만 제거한다.
2. OBS-16 GitOps 선언(`ScrapeConfig`, Prometheus egress, dashboard, alert rule)을 원복한다.
3. `gitops/tools/obs-16/apply-firewall.sh rollback <STATE_DIR>`로 생성 UUID 다섯 개만
   disabled → apply → delete → apply 순서로 제거하고 drift snapshot을 갱신한다.

기존 S3 TCP 8333, NetBird public relay/control, PostgreSQL exporter와 node_exporter는
rollback 대상이 아니다.

## 완료 증거 (2026-08-13)

| 항목 | 결과 |
|---|---|
| OPNsense·경로 | `opt2` exact PASS 5건: object-01 TCP 9325(master)·9326(volume)·9327(filer)·9328(S3), netbird-01 TCP 9090. PF runtime 각 1건 이상이며 Git snapshot drift는 clean |
| Prometheus | `up=1`: PostgreSQL 1, SeaweedFS master·volume·filer·S3 4, NetBird management 1. 대표 series는 PostgreSQL transaction 9개, SeaweedFS volume `used` 양수, NetBird connected stream metric 1개 |
| Grafana | `obs-16-service-native-metrics`가 read-only 8 panel로 provision됐다. 기존 Core Services의 PostgreSQL 3 panel도 실제 exporter series만 조회한다. Grafana Pod UID는 적용 전후 동일해 재기동하지 않았다 |
| 경보 | `NativeMetricsTargetDown`·`PostgreSQLDatabaseMetricsDown` firing 0건. 의도적 장애는 만들지 않았다 |
| immutable GitOps | 검증 root `333ebbfce0495d9df2bcca71397ccbebb045f708`, obs 선언 `50dfe7b0ce6160059dc88f7ffc0e2ce0ef8523e5`에서 `Synced/Healthy`; 종료 시 `platform-root`·`obs`를 main `3d9701cb02a42b8f967f670fd8373345000429fa` `Synced/Healthy`로 복구 |
