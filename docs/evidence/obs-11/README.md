# OBS-11 node-exporter fleet 증거

2026-08-12에 immutable GitOps revision과 라이브 OPNsense·Ansible 적용을 한 번씩 검증한
결과다. 검증 중 사용한 pointer commit(`obs` child를 작업 SHA로 임시 고정)은 되돌려
squash 대상 diff에 남기지 않았다. Secret 값·자격증명은 기록하지 않았다.

## Read-only 인벤토리

`proxmox-01`(Debian 13/trixie)·`k3s-01`(Rocky 9.8, DaemonSet 재사용 대상)·`postgres-01`·
`object-01`·`warpgate-01`·`netbird-01`(모두 Rocky 9.8) 여섯 대상 모두 TCP 9100이 비어
있었고(`k3s-01`은 기존 `obs-prometheus-node-exporter` DaemonSet이 이미 점유), 나머지
다섯 곳에는 기존 node_exporter unit이 없었다.

## Ansible node_exporter fleet

`infra/ansible/roles/node_exporter_baseline`이 `node_exporter v1.12.1`
(linux-amd64, SHA-256 `b51d8a76aa2a9156a55d501aca6276fae09e262259a5e4e831d2c2222f084e63`)을
checksum 고정 다운로드해 전용 무로그인 서비스 계정과 하드닝한 systemd unit으로 5개
host/guest(`proxmox-01`·`postgres-01`·`object-01`·`warpgate-01`·`netbird-01`)에 선언한다.
1차 적용 뒤 2차 재적용에서 5개 대상 모두 `changed=0`으로 멱등을 확인했다.

적용 중 두 가지 하드닝 결함을 실제 스크레이프 실패로 발견하고 원인을 특정해 고쳤다.

1. `ProcSubset=pid`가 `/proc/stat`·`/proc/meminfo`·`/proc/diskstats`·`/proc/net/dev`·
   `/proc/loadavg`·`/proc/vmstat` 같은 non-PID 최상위 `/proc` 항목을 가려 `cpu`·`meminfo`·
   `diskstats`·`netdev`·`loadavg`·`vmstat`·`stat` collector가 전부 실패했다. 이 옵션을
   제거해 기본 Linux collector가 모두 성공하는 것을 `node_scrape_collector_success`로
   확인했다.
2. `RestrictAddressFamilies`에 `AF_NETLINK`가 없어 `netdev` collector가 netlink socket을
   열지 못했다(`socket: address family not supported by protocol`). `AF_NETLINK`를 추가해
   해결을 확인했다.

## systemd·processes canary 판정 (netbird-01)

| collector | 실측 | 판정 |
|---|---|---|
| `systemd` | `node_systemd_units` 5 series, `node_systemd_socket_*` 36 series, `scrape_duration_seconds` 22.8ms, 실제 유닛 상태 반영 | 확대(fleet 기본값) |
| `processes` | `node_processes_pids=1`, `node_processes_state{state="R"}=1` — 이 role이 유지하는 `ProtectProc=invisible` 아래 node_exporter 자기 프로세스 1개만 보임, 시스템 전체 프로세스 수를 반영하지 못함 | 미확대. 권한(`ProtectProc`)은 약화하지 않고 `normalize-dashboard.jq`가 의존 panel(id 313·314·315: PIDs Number and Limit, Threads Number and Limit, Processes Detailed States) 3개를 제거 |

`node_exporter_baseline` 기본값(`defaults/main.yml`)은 canary 판정을 반영해
`node_exporter_canary_collectors: [systemd]`로 고정했고, 5개 대상 모두 재적용해
`node_scrape_collector_success{collector="systemd"}=1`을 확인했다.

## OPNsense 방화벽

`gitops/tools/obs-11/apply-live.sh`가 `k3s-01`(PLATFORM/`opt2`)→각 대상 TCP 9100 exact
PASS rule 5건(sequence 1003~1007)을 disabled로 stage해 의미값을 읽은 뒤 enable·apply했다.
전부 기존 `NET-04` 비공개 목적지 BLOCK(`opt2` seq=1022)보다 앞선 sequence다.

| 대상 | destination | sequence | PF runtime |
|---|---|---|---|
| `proxmox-01` | `10.10.10.10:9100` | 1003 | `pf_rules=1` |
| `postgres-01` | `10.10.50.10:9100` | 1004 | `pf_rules=1` |
| `object-01` | `10.10.50.20:9100` | 1005 | `pf_rules=1` |
| `warpgate-01` | `10.10.30.10:9100` | 1006 | `pf_rules=1` |
| `netbird-01` | `10.10.40.10:9100` | 1007 | `pf_rules=1` |

적용 직전 `check-drift.sh`에서 이 작업과 무관한 기존 drift(`BOARD-DEMO-02`가 완료
증거로 보고한 Unbound `board` alias rollback이 실제로는 라이브에 반영되지 않은 상태)를
발견했다. 사용자 확인 결과 이미 알려진 상태였으므로 스냅샷만 라이브에 동기화했고(별도
커밋), `board` alias 자체는 이 작업 범위 밖이라 다루지 않았다. 방화벽 rule 적용 뒤
`check-drift.sh --update`로 5건의 rule을 스냅샷에 반영했고 일반 drift 검사가 통과했다.
`k3s-01`에서 다섯 대상 모두 `curl http://<대상>:9100/metrics` HTTP 200을 확인했다.

## Node Exporter Full 대시보드

Grafana.com [Node Exporter Full (ID 1860)](https://grafana.com/grafana/dashboards/1860-node-exporter-full/)
revision 45, upstream SHA-256 `184c6b7409f306da75525d7772f71945b10cea23ad16b5d78c4698ea0ea51986`를
[`normalize-dashboard.jq`](../../../gitops/tools/obs-11/normalize-dashboard.jq)로 정규화했다.
`ds_prometheus` datasource 변수를 제거하고 모든 panel의 datasource UID를 `prometheus`로
고정했으며, `editable: false`·`schemaVersion: 41`로 맞추고 processes collector 의존
panel 3개(위 표)를 제거했다. `job`·`nodename`·`node`(=instance) 변수는 원본 그대로 두어
6개 target의 실제 label(`job=node-exporter`, `instance=<ip>:9100`)과 자연히 일치한다.

`gitops/apps/obs/values-kube-prometheus-stack-01.yaml`의 `dashboardProviders`·
`dashboardsConfigMaps`에 `platform-node-exporter-full` 항목을 추가하고, `install.yaml`은
해당 항목이 만드는 hunk(신규 provider, checksum/config, volumeMounts/volumes)만 수동으로
반영했다. 재렌더링 중 이 작업과 무관한 기존 kubelet 모니터링 values/install.yaml drift
(`kubelet.enabled: true`가 이미 committed 상태지만 install.yaml은 재렌더링되지 않은
상태)를 발견했으나 OBS-11 범위가 아니므로 반영하지 않았다.

## 라이브 검증

작업 브랜치를 최신 `origin/main`(`6cdb8c2445a0575edec07e978f0a48a348b7c412`)에서 분기해
`d1103bc9631cd244b38de1056257fd9c1abcf650`까지 push하고, pointer commit
`248b2bf6112204db26904a43aaab1611b039a42b`에서 `obs` child만 그 SHA로 고정한 뒤
`platform-root`를 pointer SHA로 전환했다. [`verify-live.sh`](../../../gitops/tools/obs-11/verify-live.sh)
한 번으로 다음을 판정했다.

| acceptance | 라이브 증거 | 판정 |
|---|---|---|
| Argo | immutable root `248b2bf`·child `d1103bc` 모두 `Synced/Healthy` | 통과 |
| target up | `up{job="node-exporter"}` 6건 모두 `1` | 통과 |
| CPU·메모리·disk·network 대표 시계열 | `node_cpu_seconds_total`·`node_memory_MemAvailable_bytes`·`node_disk_io_now`·`node_network_receive_bytes_total` 모두 6/6 instance에 존재 | 통과 |
| filesystem 대표 시계열 | fleet 5/6에 존재. `k3s-01`은 기존 `obs-prometheus-node-exporter` DaemonSet의 non-root `securityContext`(`runAsUser: 65534`)가 `/proc/1/mountinfo`를 열 권한이 없어 `open /host/proc/1/mountinfo: permission denied`로 collector가 실패하는 OBS-01 이래의 기존 한계다. `k3s-01`의 기존 DaemonSet은 중복 agent 없이 재사용하는 것이 이 작업의 전제이고, 고치려면 컨테이너를 root로 돌리거나 `CAP_SYS_PTRACE`를 추가해야 해 권한을 약화하지 않는다는 원칙과 충돌한다. 이 작업 범위 밖의 기존 결함으로 판정하고 확대하지 않았다 | 기존 한계로 판정(통과) |
| systemd 대표 시계열 | fleet 5/5(`node_systemd_units`) | 통과 |
| Grafana dashboard | uid `obs-11-node-exporter-full`, `editable=false`, `Platform` 폴더, panel 31개(processes 의존 3개 제외), 실제 panel query(`CPU Busy`)가 서로 다른 두 host에서 서로 다른 실측값(`81.03%`·`59.92%`) 반환 | 통과 |
| 용량 | `prometheus_tsdb_head_series=43,461`(retention 3d/6GiB 불변), Prometheus RSS 391Mi/1Gi limit, Grafana RSS 195Mi/384Mi limit, `k3s-01` available `14,015,164,416`B·swap 0, `proxmox-01` available `20,039,315,456`B·swap 0, thin `data` 사용률 10.30%·`VG` 여유 16.00 GiB 불변 | 통과 |
| 범위 | obs namespace PVC 2개(prometheus·alertmanager) 불변, 신규 Secret·Ingress·공개 DNS/NAT 0건, 외부(WAN) TCP 9100 노출 0건 | 통과 |

검증 뒤 `platform-root`를 `main`으로 되돌렸고 `obs` child도 같은 되돌림으로 literal
`main`(`6cdb8c2445a0575edec07e978f0a48a348b7c412`)의 `Synced/Healthy`로 복귀했다.

## Rollback

- Ansible: `node_exporter_canary_collectors`를 `[]`로 되돌리고 5개 대상에 재적용하거나
  `systemctl disable --now node_exporter`로 정지한다.
- OPNsense: `gitops/tools/obs-11/apply-live.sh rollback <STATE_DIR>`이 5건의 rule을
  disable→apply→delete→apply 순서로 제거하고 `check-drift.sh --update`로 스냅샷을 되돌린다.
- GitOps: 이 작업이 추가한 `gitops/apps/obs/monitoring.yaml`의 `node-exporter-fleet`
  ScrapeConfig, `network-policies.yaml`의 fleet 5건 egress, `dashboard-node-exporter-full.yaml`
  ConfigMap, `values-kube-prometheus-stack-01.yaml`의 `platform-node-exporter-full` provider
  선언과 `install.yaml`의 대응 hunk만 되돌리면 된다.
