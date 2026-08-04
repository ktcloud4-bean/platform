# 자원 예산과 정지 기준

기준 측정일: 2026-07-30. 최신 재측정일: 2026-08-03. 이 문서는 `proxmox-01` 한 대의 CPU·RAM·디스크 예산과 정지 기준을 소유한다. 목표 배치는 `architecture.md`, 주소는 `ip-plan.md`, 작업 상태는 `backlog.md`가 계속 소유한다.

## 측정 기준

아래는 VM이 하나도 없는 상태에서 직접 측정한 값이며 예산 계산의 유일한 입력이다. 하드웨어 식별, 설치 선택값과 LVM 배분의 유래는 [`runbook/proxmox-manual-install.md`](runbook/proxmox-manual-install.md)가 소유한다.

| 항목 | 실측 | 확인 명령 |
|---|---|---|
| CPU 스레드 | 20 (1 socket · 14 core · 20 thread) | `lscpu` |
| 코어 구성 | P-core 6개 × 2 스레드 (4800–5000 MHz) + E-core 8개 × 1 스레드 (3700 MHz) | `lscpu -e` |
| RAM 총량 | 62.53 GiB (`MemTotal` 65562308 kB) | `free -m`, `/proc/meminfo` |
| RAM 유휴 사용 | 2.10 GiB, `available` 60.43 GiB | `free -h` |
| Swap | 8.00 GiB, 사용 0 | `free -h` |
| `local` (dir, `pve/root` ext4) | 총 93.93 GiB · 사용 4.13 GiB · 여유 84.99 GiB | `pvesm status` |
| `local` ext4 예약 블록 | 4.80 GiB (5%). 여유에서 이미 빠져 있다 | `tune2fs -l /dev/mapper/pve-root` |
| `local-lvm` (lvmthin `pve/data`) | 총 793.80 GiB · 사용 0.00% | `pvesm status`, `lvs` |
| thin metadata | `data_tmeta` 8.10 GiB · 사용 0.24% · chunk 64 KiB | `lvs`, `lvdisplay pve/data` |
| VG `pve` 여유 | 16.00 GiB — 풀 크기의 2.0% | `vgs` |
| 물리 디스크 | 단일 NVMe 931.5 GB | `lsblk` |
| VM · CT | 0개 | `qm list`, `pct list` |

`pvesm status`의 `local` 총량 93.93 GiB는 `pve/root` LV 96.00 GiB에서 ext4 메타데이터를 뺀 값이고, 여유 84.99 GiB는 여기서 사용량 4.13 GiB와 예약 블록 4.80 GiB를 더 뺀 값이다. 예산에는 여유 값을 쓴다.

## 배분 원칙

1. **RAM은 과할당하지 않는다.** 물리 노드가 하나뿐이라 호스트 OOM은 5개 VM을 동시에 잃는다. 예산은 실제 RAM으로 고정한다.
2. **vCPU는 과할당한다.** CPU 부족은 지연으로 나타나고 되돌릴 수 있다.
3. **디스크 가상 크기는 필요한 만큼만 준다.** 온라인 확장은 되지만 축소는 되지 않는다. thin이라 커도 공짜처럼 보이는 것이 함정이다.
4. **thin 풀은 자동으로 늘어나지 않는다.** `lvm.conf`의 `thin_pool_autoextend_threshold`는 주석 상태(기본값 = 자동확장 없음)이고 VG 여유도 16.00 GiB뿐이다. 실사용률이 유일한 안전 지표다.
5. **상한은 개별 한계이지 합계가 아니다.** 아래 표의 상한을 모든 VM에 동시에 적용할 수 없다. 증설은 남은 여유 안에서 하나씩 한다.
6. **게스트에 swap을 두지 않는다.** k3s 요구사항이자 RAM 예산을 실제 메모리로 고정하기 위한 조건이다. 호스트 swap 8.00 GiB는 비상 완충이며 예산에 포함하지 않는다.

## VM 기준표

`Day 1`은 `VM-01`이 생성할 값이다. `상한`은 CAP 재검토 없이 증설할 수 있는 개별 최대치다.

| VM | vCPU Day 1 | vCPU 상한 | RAM Day 1 | RAM 상한 | 디스크 Day 1 | 디스크 상한 |
|---|---|---|---|---|---|---|
| `k3s-01` | 8 | 14 | 24 GiB | 36 GiB | 200 GiB | 320 GiB |
| `postgres-01` | 4 | 6 | 8 GiB | 12 GiB | 100 GiB | 160 GiB |
| `object-01` | 2 | 4 | 4 GiB | 8 GiB | 200 GiB | 320 GiB |
| `warpgate-01` | 2 | 4 | 2 GiB | 4 GiB | 40 GiB | 80 GiB |
| `netbird-01` | 2 | 4 | 2 GiB | 4 GiB | 32 GiB | 64 GiB |
| **Day 1 합계** | **18** | — | **40 GiB** | — | **572 GiB** | — |

`S3-01`은 기존 VM을 새 VM으로 교체하지 않고 같은 VMID·주소·200 GiB 디스크의
canonical 이름만 `object-01`로 전환했다. 따라서 이번 전환으로 추가되는 vCPU·RAM·thin
프로비저닝은 0이다.

`CAP-03`은 `k3s-01`만 28 GiB로 올려 VM RAM 합계를 44 GiB로 만들었다. 위 Day 1 표는 최초
생성 기준으로 유지하고, 현재 증설값과 실측은 아래 `CAP-03` 기록이 소유한다. QEMU overhead
1 GiB를 더한 적용 후 RAM 회계는 45 GiB다.

VM 분리 근거는 [ADR-0003](adr/0003-service-vm-boundaries.md), 단일 k3s와 local storage 선택은 [ADR-0002](adr/0002-single-node-k3s-and-local-storage.md)를 따른다.

### 공통 VM 옵션

용량 회계에 영향을 주는 항목만 여기서 고정한다. 나머지 VM 옵션은 `IAC-01`·`VM-01`이 소유한다.

| 항목 | 값 | 이유 |
|---|---|---|
| CPU 유형 | `host` | 단일 노드이며 live migration 대상이 없다 |
| NUMA | 비활성 | NUMA 노드가 1개다 |
| vCPU 고정(pinning) | 하지 않는다 | 하이브리드 코어에서 고정은 성능을 보장하지 못하고 스케줄러 여유만 줄인다 |
| ballooning | 사용하지 않는다 (min = max) | 게스트가 보는 메모리가 변하면 k3s의 eviction 임계와 DB 튜닝 전제가 깨진다 |
| KSM | 예산에 포함하지 않는다 | `ksmtuned`는 active지만 `/sys/kernel/mm/ksm/run`은 0이다. 압박 상황의 응급 수단이지 확보된 용량이 아니다 |
| 디스크 discard | `discard=on`, `ssd=1` | 없으면 게스트가 지운 블록이 풀로 돌아오지 않는다 |
| 게스트 trim | `fstrim.timer` 활성 | 회수 경로는 게스트 FS → 가상 디스크 → thin 풀 전부 필요하다 |

하이브리드 코어라 같은 vCPU 수라도 어떤 물리 코어에 배치되는지에 따라 성능이 다르다. 지연에 민감한 요구를 vCPU 수만으로 보장하지 않는다. 이 CPU는 AVX-512를 노출하지 않으므로 P/E 코어 간 이주 자체는 안전하다.

## RAM 예산

| 구분 | 크기 | 근거 |
|---|---|---|
| 물리 RAM | 62.53 GiB | 실측 |
| 호스트 예약 | 6.00 GiB | 유휴 실측 2.10 GiB + 페이지 캐시·업그레이드·복구 작업 여유 |
| QEMU 프로세스 오버헤드 | 1.00 GiB | VM당 0.20 GiB 보수 추정 × 5 |
| VM 배정 (Day 1) | 40.00 GiB | 기준표 합계 |
| **미배정 여유** | **15.53 GiB** | 증설에 쓸 수 있는 전부 |

RAM 상한 열의 합계는 64 GiB로 물리 RAM을 넘는다. 증설 총량은 15.53 GiB이므로 상한은 일부만 선택할 수 있다.

| 지표 | 경고 | 정지 |
|---|---|---|
| 배정 합계 (VM RAM 합 + VM당 0.20 GiB) | 52 GiB | 56.5 GiB |
| 호스트 `free -m`의 `available` | 12 GiB 미만 | 8 GiB 미만 |
| 호스트 swap 사용량 | 0 초과 | 재부팅 없이 지속 |

정지 상태에서는 신규 VM 생성과 RAM 증설을 하지 않는다. 호스트 swap이 쓰이기 시작했다면 이미 과할당이므로 배정을 줄인다.

## vCPU 예산

물리 스레드 20개에 Day 1 배정 18 vCPU는 0.9:1이다. 과할당 절대 상한은 1.5:1인 30 vCPU다.

| 지표 | 경고 | 정지 |
|---|---|---|
| 배정 vCPU 합계 | 24 | 30 |
| 15분 load average | 20 (스레드 수) | 30 지속 |

## `local-lvm` thin 예산

Day 1 프로비저닝 572 GiB는 풀 793.80 GiB의 72.1%다. 즉 **Day 1에는 과할당이 없다.**

| 구분 | 값 |
|---|---|
| 풀 크기 | 793.80 GiB |
| Day 1 프로비저닝 합계 | 572 GiB (72.1%) |
| 미프로비저닝 여유 | 221.8 GiB (27.9%) |
| 기본 프로비저닝 상한 | 714 GiB — 풀의 90%, 과할당 없음 |
| 조건부 과할당 절대 상한 (`CAP-02` 결정) | 992 GiB — 1.25:1 |

상한 열을 모두 적용하면 944 GiB로 1.19:1이 된다. `CAP-02`에서 핵심 서비스와 백업을
배포한 뒤에도 실사용률이 3.00%임을 확인했으므로 1.25:1까지 조건부 과할당을 허용한다.
다만 714 GiB를 넘는 증설은 한 번에 하나씩 하고, thin data·metadata와 게스트 여유가 모두
경고 미만일 때만 진행한다. 992 GiB는 목표가 아니라 절대 상한이다.

### 실사용 정지 기준

판정은 프로비저닝 합계가 아니라 `lvs -o data_percent pve/data`의 실사용률로 한다.

| 사용률 | 상태 | 조치 |
|---|---|---|
| 60% 미만 | 정상 | — |
| 60–70% | 경고 | 보존기간·이미지 정리, 증설 계획 수립. 신규 대용량 워크로드 보류 |
| 70% 이상 | 정지 | 신규 VM 생성·디스크 확장·`K3S-HEAVY` 배포 금지 |
| 85% 이상 | 비상 | 데이터 투입 중단. `fstrim`으로 회수하고 실패 시 워크로드를 줄인다 |

metadata 사용률은 50%에서 경고, 70%에서 정지한다. 최신 실측은 0.33%다.

풀이 소진되면 게스트 쓰기가 실패하고 파일시스템이 손상될 수 있다. `lvextend`로 벌 수 있는 시간은 VG 여유 16.00 GiB, 곧 풀의 2.0%뿐이다. 85%를 비상으로 두는 근거가 이것이다.

## `local` (dir) 예산

`local`은 `/`와 같은 ext4 파일시스템이다. 여기가 차면 `pve-cluster`·`pveproxy`·journald가 함께 실패한다. VM 디스크와 완전히 분리된 예산으로 관리한다.

| 항목 | 예산 | 근거 |
|---|---|---|
| 호스트 OS·PVE 사용 중 | 4.16 GiB | `CAP-02` 실측 |
| ext4 예약 블록 | 4.80 GiB | 사용 불가. 여유 계산에서 이미 제외됨 |
| ISO (`template/iso`) | 15 GiB | Rocky 9 Minimal + PVE ISO + 직전 버전 1개 |
| `snippets`·`import` | 5 GiB | `OS-01`의 cloud-init 자료 |
| `vztmpl` | 0 GiB | LXC를 기본 배치 단위로 쓰지 않는다 ([ADR-0003](adr/0003-service-vm-boundaries.md)) |
| `dump` (vzdump 임시) | 20 GiB | 단발성 1개 VM만. 작업이 끝나면 즉시 지운다 |
| 운영 여유 | 약 45 GiB | 로그·업그레이드·복구용. 정지 기준을 지키기 위한 잔여분 |

| 지표 | 경고 | 정지 |
|---|---|---|
| `df -h /` 사용률 | 70% | 80% (ISO 업로드·vzdump 금지) |

**`local`은 VM 백업의 상시 착지점이 아니다.** 93.93 GiB에 프로비저닝 572 GiB의 이미지 레벨 백업은 들어가지 않는다. `PVE-BKP-01`(두 번째 SSD)이 `DEFERRED`인 동안 VM 전체 백업은 존재하지 않으며, 복구 경로는 선언형 재구축과 앱 레벨 백업(`BKP-01`–`BKP-04`)뿐이다. 이 전제는 데이터 투입 전에 `BKP-05`가 검증한다.

## `k3s-01` 디스크와 PVC 경계

[ADR-0002](adr/0002-single-node-k3s-and-local-storage.md)대로 `local-path`의 PVC 요청량은 디렉터리 하드 쿼터가 아니다. `20Gi`를 요청한 PVC가 그 이상 쓰는 것을 provisioner가 막지 않는다. 그래서 **실효 상한은 `k3s-01`의 가상 디스크 하나뿐**이고, 그 안의 구획은 사람이 지키는 예산이다.

| 구획 | 예산 | 비고 |
|---|---|---|
| OS | 10 GiB | Rocky 9 Minimal, swap 없음 |
| containerd 이미지·컨테이너 로그 | 50 GiB | 이미지 수가 많다. kubelet GC 대상 |
| PVC 예산 (`local-path`) | 120 GiB | 선언 합계의 상한 |
| 미배정 여유 | 20 GiB | 게스트 여유율을 지키기 위한 완충 |

- PVC 선언 합계가 120 GiB를 넘는 배포는 CAP 재검토 없이 하지 않는다.
- namespace `ResourceQuota`의 `requests.storage`는 **선언 합계만** 강제한다. 실사용은 강제하지 못하므로 요청량과 실사용량을 둘 다 본다. `STOR-01`이 capacity 미강제를 실제로 확인한다.
- 게스트 파일시스템 여유가 20% 밑으로 내려가면 사람이 개입한다. kubelet 기본 `nodefs.available<10%` eviction보다 앞선 지점이다.
- 대용량 저장은 k3s 밖으로 뺀다. Harbor registry backend와 Loki chunk는 전용 로컬 S3, 관계형 데이터는 `postgres-01`을 쓴다. 이 선택이 무너지면 120 GiB 예산이 가장 먼저 깨진다.
- Wazuh indexer는 이 예산에 포함하지 않는다. 배치는 `CAP-02` gate에서 결정한다.

### `K3S-01` 기준선 직후 실측 (2026-07-31)

검증용 PVC와 Pod를 제거한 뒤 측정했다. 주소와 VM 하드웨어 값은
[`ip-plan.md`](ip-plan.md)와 `VM-01` 구성을 따른다.

| 지표 | 실측 | 예산·정지 기준 | 판정 |
|---|---|---|---|
| guest root | 총 198.86 GiB · 사용 3.80 GiB · 여유 195.06 GiB · 2% | 여유 25% 미만 경고, 20% 미만 정지 | 정상 |
| `/var/lib/rancher/k3s` | 1.31 GiB | 이미지·로그 50 GiB와 PVC 120 GiB 구획 안에서 관측 | 정상 |
| Node memory | metrics-server 1,266 MiB(5%); OS `available` 21.97 GiB | VM 24 GiB Day 1 | 정상 |
| Node CPU | 39 millicore(0%) | VM 8 vCPU Day 1 | 정상 |
| PVC 선언 합계 | 0 | 96 GiB 경고, 120 GiB 정지 | 정상 |
| Proxmox host `available` | 52.45 GiB | 12 GiB 미만 경고, 8 GiB 미만 정지 | 정상 |
| Proxmox swap | 사용 0 | 0 초과 경고 | 정상 |
| thin data / metadata | 1.15% / 0.27% | 60% / 50% 경고 | 정상 |
| Proxmox `/` | 5% | 70% 경고 | 정상 |

SQLite 파일은 약 10 MiB였고 read-only `quick_check=ok`였다. 초기 기준선의 k3s
데이터 실사용은 1.31 GiB이므로 50 GiB 이미지·로그 구획에 여유가 있지만, 이는 앱
배포 전 값이다. `K3S-HEAVY` 배포 전후에 다시 측정한다.

동적 16 MiB PVC는 Bound 및 재부팅 후 데이터 유지를 통과했다. 삭제 시 기본
local-path helper가 SELinux Enforcing 환경에서 timeout을 냈고 정확한 test 경로를
수동 제거했다. capacity 미강제와 함께 자동 reclaim 동작도 `STOR-01`에서 재검토한다.

### `STOR-01` 검증 자원 정리 후 실측 (2026-07-31)

16Mi 요청 PVC에 32MiB bounded write와 재부팅·자동 reclaim을 검증한 뒤 namespace,
Pod, PVC, PV와 실제 시험 경로를 모두 제거하고 다시 측정했다.

| 지표 | 실측 | 경고 | 정지 | 판정 |
|---|---|---|---|---|
| guest root | 총 198.86 GiB · 사용 3.86 GiB · 여유 195.00 GiB · 2% | 여유 25% 미만 | 여유 20% 미만 | 정상 |
| `/var/lib/rancher/k3s` | 1.26 GiB | 이미지·로그 50 GiB와 PVC 120 GiB 구획 안에서 관측 | 구획 합계·guest 여유 기준 | 정상 |
| Node memory | 1,268 MiB · 5%; OS available 21.94 GiB | VM 24 GiB Day 1 | guest 여유 기준 | 정상 |
| Node CPU | 31 millicore · 0% | VM 8 vCPU Day 1 | 지속 부하 재측정 | 정상 |
| PVC 선언 합계 | 0 | 96 GiB | 120 GiB | 정상 |
| DiskPressure | `False` | — | `True`면 신규 쓰기 중단·원인 회수 | 정상 |

요청 16Mi보다 큰 32MiB 파일 쓰기가 성공해 local-path capacity가 하드 quota가 아님을
확인했다. 이는 64MiB 이하의 제한 시험 결과이며, nodefs 소진이나 kubelet eviction
임계 자체를 시험한 것이 아니다. 자동 삭제 뒤 PVC 선언 합계와 storage child는 0이다.

### `KC-01` 배포 예산

Keycloak 상시 Pod의 scheduler 기준 유효 request는 CPU 250m·RAM 1GiB이고 limit는 CPU 2·RAM
2GiB다. Vault Agent init request 10m·32MiB는 상시 container와 동시에 실행되지 않아 더 큰
상시 request가 Pod 유효값이 된다. 최초 bootstrap Job도 같은 250m·1GiB를 일시 사용하고 완료
후 실행 자원을 소비하지 않는다.

Keycloak 데이터는 `postgres-01`에 두므로 KC-01이 추가하는 PVC는 0개다. 최초 배포 후 실제
working set, node `available`, image·container 로그 증가량을 다시 기록한다. 상시 working set이
1.5GiB를 넘거나 node `available`이 8GiB 아래면 replica·heap·limit을 늘리지 않고 원인을 먼저
분류한다.

### `POM-01` 배포 예산

Pomerium Core all-in-one 한 replica의 scheduler 기준 상시 request는 CPU 100m·RAM 256Mi이고
limit는 CPU 1·RAM 1GiB다. Vault Agent init request 10m·32MiB는 상시 container와 동시에
실행되지 않아 Pod 유효 request는 상시 Pomerium 값이다. Dashy 한 replica는 CPU 50m·RAM
128Mi request, CPU 500m·RAM 512Mi limit다. 따라서 POM-01 전체 상시 request는 CPU 150m·RAM
384Mi, limit 합계는 CPU 1.5·RAM 1.5GiB다.

Pomerium Databroker와 session은 메모리이며 Envoy 추출용 256Mi, data 64Mi `emptyDir`와 8Mi
메모리 볼륨 두 개를 사용한다. Dashy는 설정을 read-only ConfigMap에서 읽고 64Mi `emptyDir`
두 개만 사용한다. 두 Deployment 모두 PVC 요청은 0개다.

최초 배포와 groups/Portal/session 검증 뒤 실제 working set, node `available`, guest disk와
container log 증가량을 기록한다. Pomerium working set이 768Mi 또는 Dashy가 384Mi를 넘거나
Node memory가 기존 정지 기준에 접근하면 replica·limit을 늘리지 않고 Envoy·session·빌드
자산·log 사용량을 먼저 분류한다.

## 나머지 VM 디스크 구획

| VM | 총량 | 구획 |
|---|---|---|
| `postgres-01` | 100 GiB | OS 10 · PGDATA 60 · WAL·아카이브 20 · 여유 10 |
| `object-01` | 200 GiB | OS 10 · 버킷 데이터 170 · 여유 20 |
| `warpgate-01` | 40 GiB | OS 10 · 세션 기록 20 · 여유 10 |
| `netbird-01` | 32 GiB | OS 10 · 제품 DB·로그 12 · 여유 10 |

`object-01`의 170 GiB는 `k3s-01` PVC 120 GiB와 `postgres-01` 데이터 80 GiB를 받는
착지점이다. 보존 세대 수가 예산을 결정하므로 `BKP-02`–`BKP-04`가 보존기간을 확정할
때 이 값을 다시 본다. `warpgate-01`의 세션 기록도 용량이 아니라 보존기간으로
통제한다.

## 정지 기준 요약

| 지표 | 확인 방법 | 경고 | 정지 |
|---|---|---|---|
| thin 풀 사용률 | `lvs -o data_percent pve/data` | 60% | 70% |
| thin metadata 사용률 | `lvs -o metadata_percent pve/data` | 50% | 70% |
| 호스트 RAM 여유 | `free -m`의 `available` | 12 GiB 미만 | 8 GiB 미만 |
| `k3s-01` RAM 여유 | 게스트 `free -m`의 `available` | 12 GiB 미만 | 8 GiB 미만 |
| RAM 배정 합계 | 구성 합 + VM당 0.20 GiB | 52 GiB | 56.5 GiB |
| vCPU 배정 합계 | 구성 합 | 24 | 30 |
| 호스트 부하 | `uptime` 15분 load | 20 | 30 지속 |
| `/` 사용률 | `df -h /` | 70% | 80% |
| `k3s-01` 게스트 여유 | 게스트 `df` | 25% 미만 | 20% 미만 |
| PVC 선언 합계 | `kubectl get pvc -A` | 96 GiB | 120 GiB |

정지는 "지금 있는 것을 끄라"가 아니라 "더 늘리지 말고 원인을 줄여라"다. 어떤 지표든 정지 구간에 들어가면 신규 VM, 디스크 확장, `K3S-HEAVY` 배포를 멈추고 회수·보존기간·워크로드 축소를 먼저 한다.

## `VM-01` 직후 실측 (2026-07-31)

VM 5대를 생성하고 각각 한 번씩 재부팅한 뒤 측정했다. 기준표와의 차이는 없다.

| 지표 | 기준표 예상 | `VM-01` 직후 실측 | 경고 | 정지 | 판정 |
|---|---|---|---|---|---|
| 배정 vCPU 합계 | 18 | 18 | 24 | 30 | 정상 |
| RAM 배정 합계 | 41.00 GiB | 41.00 GiB | 52 | 56.5 | 정상 |
| 호스트 `available` | — | 55.0 GiB | 12 GiB 미만 | 8 GiB 미만 | 정상 |
| 호스트 swap 사용 | 0 | 0 | 0 초과 | 지속 사용 | 정상 |
| thin 프로비저닝 합계 | 572 GiB (72.1%) | 572 GiB | — | 714 GiB 상한 | 정상 |
| thin 실사용률 | — | 0.96% | 60% | 70% | 정상 |
| thin metadata | — | 0.26% | 50% | 70% | 정상 |
| VG `pve` 여유 | 16.00 GiB | 16.00 GiB | — | — | 변화 없음 |
| `/` 사용률 | — | 5% | 70% | 80% | 정상 |
| 15분 load average | — | 0.24 | 20 | 30 지속 | 정상 |

디스크 실사용이 프로비저닝 572 GiB 대비 0.96%에 그치는 것은 full clone이 thin 볼륨을 유지하고 게스트가 아직 비어 있기 때문이다. **프로비저닝 합계가 아니라 이 실사용률이 정지 판정의 기준이다.** 게스트 root 파일시스템은 Day 1 크기로 확장됐고(각각 99·199·199·39·31 GiB) 사용률은 2~4%다.

어떤 지표도 경고 구간에 들어가지 않았으므로 후속 서비스 작업의 자원 gate는 열려 있다.

### `WG-01` 검증 자원 정리 후 실측 (2026-07-31)

Warpgate 기준선을 적용하고 재부팅·격리 복원 검증까지 마친 뒤, 임시 대상 계정과
복원 인스턴스·임시 백업을 제거하고 측정했다.

| 지표 | 실측 | 경고 | 정지 | 판정 |
|---|---|---|---|---|
| `warpgate-01` guest root | 총 39 GiB · 사용 1.4 GiB · 4% | 여유 25% 미만 | 여유 20% 미만 | 정상 |
| `/var/lib/warpgate` | 680 KiB (기록 16 KiB) | 세션 기록 20 GiB 구획 안에서 관측 | 구획 합계·guest 여유 기준 | 정상 |
| `warpgate-01` 메모리 | `available` 1,436 MiB / 총 1,771 MiB | VM 2 GiB Day 1 | guest 여유 기준 | 정상 |
| 호스트 `available` | 50.5 GiB | 12 GiB 미만 | 8 GiB 미만 | 정상 |
| 호스트 swap 사용 | 0 | 0 초과 | 지속 사용 | 정상 |
| thin data / metadata | 1.47% / 0.28% | 60% / 50% | 70% / 70% | 정상 |
| 호스트 `/` 사용률 | 5% | 70% | 80% | 정상 |
| 15분 load average | 0.23 | 20 | 30 지속 | 정상 |
| 배정 vCPU / RAM 합계 | 18 / 41.00 GiB | 24 / 52 GiB | 30 / 56.5 GiB | 변화 없음 |

`warpgate-01`의 40 GiB 구획(OS 10 · 세션 기록 20 · 여유 10)은 유지된다. 이 시점의
세션 기록은 검증 세션 4건뿐이므로 실제 증가율은 운영 사용이 시작된 뒤 다시 본다.
세션 기록은 용량이 아니라 보존기간으로 통제하며, 선언한 값은
[WG-01 runbook](runbook/warpgate-privileged-access.md)이 소유한다.

## 재측정 절차

읽기 전용이며 `PVE-LIVE` 잠금이 필요하지 않다. 주소는 `ip-plan.md`의 `proxmox-01` 값을 쓴다.

```sh
ssh root@<proxmox-01> '
  lscpu | grep -E "^(CPU\(s\)|Core|Socket|Thread|Model name)"
  free -m
  pvesm status
  lvs -o lv_name,lv_size,data_percent,metadata_percent pve/data
  vgs -o vg_name,vg_size,vg_free --units g
  df -h /
  uptime
  qm list
'
```

### `NB-01` 배포 직후 실측 (2026-07-31)

Ansible 배포 및 재부팅 검증 완료 뒤 측정했다. 컨테이너 3개(netbird-traefik, netbird-server, netbird-dashboard)가 systemd unit 자동 시작 후 Up 상태였다.

| 지표 | 실측 | 예산·정지 기준 | 판정 |
|---|---|---|---|
| guest root | 총 31 GiB · 사용 2.7 GiB · 여유 29 GiB · 9% | 여유 25% 미만 경고, 20% 미만 정지 | 정상 |
| VM RAM (total / available) | 1,771 MiB / 1,256 MiB | Day 1 2 GiB | 정상 |
| netbird-traefik 메모리 | 110.7 MiB | — | 정상 |
| netbird-server 메모리 | 71.7 MiB | — | 정상 |
| netbird-dashboard 메모리 | 30.2 MiB | — | 정상 |
| 컨테이너 3개 합계 | 212.6 MiB | RAM 2 GiB 내 | 정상 |
| 재부팅 후 자동 시작 | netbird-compose.service enabled + active | 재부팅 유지 필수 | 통과 |
| HTTPS (TLS 443) | HTTP/2 200, Let's Encrypt 와일드카드 인증서 | — | 통과 |
| API 인증 거부 | HTTP 401 (인증 없이 접근 시) | — | 통과 |
| STUN UDP 3478 | 0.0.0.0:3478 LISTEN | — | 통과 |
| /oauth2 OpenID Discovery | HTTP 200 | — | 통과 |
| 잘못된 로그인 거부 | "Invalid Email Address or password." 반환 | — | 통과 |
| 올바른 로그인 | HTTP 303 + auth code redirect | — | 통과 |
| 백업 파일 크기 | 25 KiB (설정·DB·인증서 포함) | — | 정상 |

### `S3-01` 정리·재부팅 뒤 실측 (2026-07-31)

SeaweedFS S3 호환성 시험(총 payload 6,291,528 bytes)과 시험 bucket·version·identity
정리를 마치고 `object-01`만 재부팅한 뒤 측정했다. VMID 151·2 vCPU·4 GiB RAM·200 GiB
disk의 배정은 불변이다.

| 지표 | 실측 | 경고·정지 기준 | 판정 |
|---|---|---|---|
| `object-01` guest root | 총 198.86 GiB · 사용 2.71 GiB · 여유 196.15 GiB · 2% | 여유 25% 미만 경고, 20% 미만 정지 | 정상 |
| SeaweedFS 영속 경로 합계 | 77,918 bytes (master 1,623 · volume 40,913 · filer 35,382) | 버킷 데이터 170 GiB 구획 안에서 관측 | 정상 |
| guest memory (total / available) | 3.57 GiB / 2.96 GiB | Day 1 4 GiB | 정상 |
| 호스트 `available` | 47.66 GiB | 12 GiB 미만 / 8 GiB 미만 | 정상 |
| 호스트 swap 사용 | 0 | 0 초과 경고 | 정상 |
| thin data / metadata | 1.79% / 0.29% | 60% / 50% 경고, 70% / 70% 정지 | 정상 |
| 호스트 `/` 사용률 | 5% | 70% / 80% | 정상 |
| 15분 load average | 0.21 | 20 / 30 지속 | 정상 |
| 배정 vCPU / RAM / thin 프로비저닝 | 18 / 41.00 GiB / 572 GiB | 24 / 52 GiB / 714 GiB 상한 | 정상 |

단일 VM·단일 thin-backed disk이므로 이 수치는 HA 또는 물리 장애 복구 증거가 아니다.
`BKP-04`의 AWS S3 오프사이트 사본과 이후 복구 drill이 별도로 필요하다.

### `BKP-03` 7세대·오프사이트 검증 뒤 실측 (2026-08-01)

PostgreSQL physical archive·manifest와 Vault Raft snapshot·manifest를 각각 7세대 유지하고,
두 bucket의 AWS 사본 byte 검증을 끝낸 뒤 측정했다.

| 지표 | 실측 | 경고·정지 기준 | 판정 |
|---|---|---|---|
| `object-01` guest root | 총 213,524,656,128 bytes · 사용 3,294,466,048 · 여유 210,230,190,080 · 2% | 여유 25% 미만 경고, 20% 미만 정지 | 정상 |
| SeaweedFS 영속 경로 | master 3,028 · volume 84,536,184 · filer 107,437 bytes | 버킷 데이터 170 GiB 구획 안에서 관측 | 정상 |
| guest memory | 총 3,833,053,184 · available 2,961,133,568 bytes | Day 1 4 GiB | 정상 |
| volume slot | max 10 · 할당 10 · free 0 · ID `1`, `10`~`18` | 새 collection 전 기존 volume 삭제·재사용 금지 | 관측 필요 |
| 서비스 | master·volume·filer·S3 active, offsite job success | 백업·전송 성공 필수 | 정상 |

`free=0`은 디스크가 찼다는 뜻이 아니라 현재 collection에 volume slot 10개가 모두 할당됐다는
뜻이다. 기존 volume은 계속 object를 담을 수 있다. 새 collection이 필요하면 이 값을 자동으로
낮추거나 volume을 재사용하지 말고, disk 여유와 의존 서비스 재시작 영향을 다시 승인받아 올린다.

### `CAP-02` 핵심 서비스 배포 후 실측 (2026-08-02)

`BKP-05`와 `HEADLAMP-02` 완료 뒤 2026-08-02 11:54–11:56 KST에 읽기 전용으로
측정했다. Proxmox 명령은 한 SSH 세션에, 각 게스트 명령은 게스트별 한 세션에 묶었다.

| Proxmox 지표 | 실측 | 경고 | 정지 | 판정 |
|---|---|---|---|---|
| CPU / 15분 load | 20 thread / 0.30 | 20 | 30 지속 | 정상 |
| RAM total / available | 62.53 / 41.30 GiB | available 12 GiB 미만 | available 8 GiB 미만 | 정상 |
| swap 사용 | 0 / 8.00 GiB | 0 초과 | 지속 사용 | 정상 |
| `local` | 총 93.93 · 사용 4.16 · 여유 84.96 GiB; `/` 5% | `/` 70% | `/` 80% | 정상 |
| `local-lvm` data / metadata | 23.81 / 793.80 GiB · 3.00% / 0.33% | 60% / 50% | 70% / 70% | 정상 |
| VG `pve` 여유 | 16.00 GiB | — | — | 변화 없음 |
| VM 배정 합계 | 실행 VM 5대 · 18 vCPU · RAM 회계 41.00 GiB · disk 572 GiB | 24 vCPU / 52 GiB | 30 vCPU / 56.5 GiB | 정상 |

| VM | vCPU / 15분 load | RAM total / available | guest root 총량 / 사용 / 여유 | 판정 |
|---|---|---|---|---|
| `k3s-01` | 8 / 0.15 | 23,771 / 20,050 MiB | 198.86 / 9.90 / 188.96 GiB · 5% | 정상 |
| `postgres-01` | 4 / 0.00 | 7,680 / 7,206 MiB | 98.86 / 2.08 / 96.78 GiB · 3% | 정상 |
| `object-01` | 2 / 0.00 | 3,655 / 2,842 MiB | 198.86 / 3.02 / 195.84 GiB · 2% | 정상 |
| `warpgate-01` | 2 / 0.00 | 1,771 / 1,426 MiB | 38.86 / 1.53 / 37.33 GiB · 4% | 정상 |
| `netbird-01` | 2 / 0.00 | 1,771 / 1,261 MiB | 30.86 / 2.80 / 28.06 GiB · 10% | 정상 |

게스트 swap은 5대 모두 0이다. `k3s-01`의 `/var/lib/rancher/k3s`는 6.67 GiB다.
metrics-server가 응답한 실행 Pod 22개의 순간 사용량은 다음과 같다.

| namespace | Pod 수 | CPU | memory |
|---|---:|---:|---:|
| `argocd` | 7 | 34m | 611 MiB |
| `crowdsec-01` | 3 | 3m | 121 MiB |
| `headlamp` | 1 | 1m | 20 MiB |
| `keycloak` | 1 | 1m | 653 MiB |
| `kube-system` | 5 | 6m | 268 MiB |
| `pomerium` | 2 | 16m | 100 MiB |
| `vault` | 1 | 4m | 147 MiB |
| `velero` | 2 | 2m | 148 MiB |
| **합계** | **22** | **67m** | **2,068 MiB** |

같은 시점의 Node 사용량은 173m / 4,426 MiB이고 guest `available`은 19.58 GiB다.
PVC 요청 합계는 5.125 GiB(`crowdsec-db-pvc` 1 GiB, `traefik` 128 MiB,
`vault-data` 4 GiB)로 96 GiB 경고까지 90.875 GiB가 남았다.

stop/go 판정은 **GO**다. `SCM-01`·`REG-01`·`QUALITY-01`·`AWX-01`은 현재 여유로
각각 순차 배포를 시작할 수 있다. 이는 네 앱의 최종 동시 사용량을 사전 보장한다는 뜻이 아니며,
각 작업은 배포 직후 같은 지표를 읽고 다음 작업 진행 여부를 판정한다. 현 배치에서 추가 Pod가
먼저 소비하는 경계는 `k3s-01` RAM이다. guest `available`은 12 GiB 경고까지 7.58 GiB,
8 GiB 정지까지 11.58 GiB 남아 있어 CPU·guest disk·PVC보다 먼저 재검토할 가능성이 높다.

### `AWX-01` 배포 직후 실측 (2026-08-02)

16:11 KST의 최종 완료 증거 실행에서 읽었다. 배포 직전 guest `available`은
17,970 MiB였고 12 GiB 경고선 위라 적용 gate는 **GO**였다.

| 지표 | 배포 직후 실측 | stop 기준 | 판정 |
|---|---:|---:|---|
| `k3s-01` guest available / swap | 15,598 / 0 MiB | available 12 GiB 미만 경고·8 GiB 미만 정지, swap 사용 시 재검토 | 정상 |
| `k3s-01` guest `/` 사용 | 8% | 75% 경고 | 정상 |
| k3s Node CPU / memory | 782m(9%) / 7,840 MiB(32%) | guest available 경계를 우선 적용 | 정상 |
| PVC 수 | 4개 | 요청 합계와 guest disk 경계를 함께 관측 | 정상 |
| Proxmox available / swap | 34,428 / 0 MiB | available 12 GiB 미만, swap 사용 | 정상 |
| `local-lvm` data / metadata | 4.08% / 0.37% | 60% / 50% | 정상 |
| Proxmox `/` 사용 | 5% | 70% | 정상 |

배포 직후 stop/go 판정은 **GO**다. `k3s-01` guest available은 12 GiB 경고선까지
3,310 MiB가 남았다. AWX 완료 증거의 job은 cluster 내부 verifier만 사용했으므로 이 측정은
실제 운영 VM의 cross-VLAN SSH 허용이나 부하를 증명하지 않는다.

### `REG-01` 배포 직후 실측 (2026-08-02)

Harbor 완료 증거와 격리 복원 자원을 제거한 뒤 측정했다. registry layer는 k3s PVC가 아니라
`object-01`의 SeaweedFS S3에 남는다.

| 지표 | 실측 | 경고·정지 기준 | 판정 |
|---|---|---|---|
| `k3s-01` guest `/` | 사용 12% · `/var/lib/rancher/k3s` 19,750 MiB | 여유 25% 미만 경고, 20% 미만 정지 | 정상 |
| `k3s-01` guest available | 12,391 MiB | 12 GiB 미만 경고, 8 GiB 미만 정지 | 정상 |
| PVC 요청 합계 / Harbor PVC | 45.125 GiB / 0개 | 96 GiB 경고, 120 GiB 정지 | 정상 |
| k3s DiskPressure | `False` | `True`면 신규 쓰기 중단 | 정상 |
| Proxmox available / swap | 28,854 / 0 MiB | available 12 GiB 미만, swap 사용 | 정상 |
| Proxmox load15 / `/` | 0.76 / 5% | 20·70% 경고, 30 지속·80% 정지 | 정상 |
| thin data / metadata | 4.97% / 0.40% | 60% / 50% 경고, 70% / 70% 정지 | 정상 |
| `object-01` guest root | 총 213,524,656,128 · 사용 3,248,504,832 · 여유 210,276,151,296 bytes · 2% | 여유 25% 미만 경고, 20% 미만 정지 | 정상 |
| SeaweedFS 영속 경로 | 72,027,946 bytes | 버킷 데이터 170 GiB 구획 안에서 관측 | 정상 |
| SeaweedFS volume slot | max 15 · 할당 12 · free 3; Harbor ID `19`, `20` | 기존 volume 삭제·max 하향 금지, guest 여유 기준 | 정상 |

Harbor가 layer를 쓴 뒤에도 Harbor PVC는 0개이고 SeaweedFS `harbor-registry` collection에
writable volume 2개가 생겼으므로 S3 backend 경계가 유지됐다. 모든 stop 기준 밖이어서
다음 배포는 **GO**다. 다만 guest available 12,391 MiB는 12 GiB 경고선보다 103 MiB만 높아
다음 `K3S-HEAVY` 또는 공급망 workload는 배포 직전 같은 지표를 다시 읽는다.

### `SCAN-01` 배포·scan 실행 실측 (2026-08-02)

최종 라이브 검증의 배포 직전, 배포 직후, pass agent 실행 중을 같은 `free -m`의
`available` 값으로 측정했다. metrics-server가 짧게 실행된 agent의 container 표본을 내기 전에
Pod가 종료돼 Trivy container 단독값은 분리하지 못했으며, 아래 runtime 차이는 jnlp·Buildah·
Trivy·ORAS 네 container와 build 작업을 합친 보수적 상한이다.

| 지표 | 실측 | 경고·정지 기준 | 판정 |
|---|---:|---:|---|
| `k3s-01` 배포 직전 available | 11,781 MiB | 12 GiB 미만 경고, 8 GiB 미만 정지 | 경고 구간 |
| 선언 배포 직후 available / swap | 11,585 / 0 MiB | 동일, swap 사용 시 재검토 | **GO** |
| pass agent 실행 중 available | 11,283 MiB | 8 GiB 미만 정지 | **GO** |
| runtime available 감소 | 배포 직후 대비 302 MiB | 8 GiB 정지선까지 여유 확인 | 정상 |
| PVC 요청 합계 / Trivy cache | 66.125 / 1 GiB | 96 GiB 경고, 120 GiB 정지 | 정상 |

scanner 추가 뒤에도 available은 정지선보다 3,091 MiB 높고 swap은 0이며 PVC 요청은
기존 65.125 GiB에서 정확히 1 GiB만 늘었다. `SCAN-01` stop/go는 **GO**다. 다만 이미
12 GiB 경고 구간이므로 후속 `SIGN-01`은 적용 직전 같은 RAM을 먼저 읽는다.

### `LOKI-01` 배포 전·후 및 저장 증가량 실측 (2026-08-03)

최종 immutable 선언을 배포하기 직전과 직후에 정지 기준을 각각 한 번 측정하고, 같은 배포의
S3 저장량을 30분 고정창으로 한 번 관측했다. Loki는 chunk를 `object-01` SeaweedFS S3에
저장하며 local-path PVC를 추가하지 않는다.

| 지표 | 실측 | 경고·정지 기준 | 판정 |
|---|---:|---:|---|
| `k3s-01` 배포 직전 available | 11,289,554,944 bytes (10,766.559 MiB) | 12 GiB 미만 경고, 8 GiB 미만 정지 | 경고 구간 |
| 배포 직후 available / 감소량 | 10,812,805,120 / 476,749,824 bytes (10,311.895 / 454.664 MiB) | 8 GiB 미만 정지 | **GO** |
| swap / guest root 여유 | 0 / 85% | swap 사용 재검토, 여유 20% 미만 정지 | 정상 |
| PVC 요청 합계 / Loki PVC | 66.125 GiB / 0개 | 96 GiB 경고, 120 GiB 정지 | 정상 |
| S3 관측창 | `01:23:08Z`–`01:53:13Z`, 1,805초 | 짧은 고정 관측창 | 완료 |
| S3 저장량 | 118,301→272,996 bytes, 증가 154,695 bytes | retained chunk 14 GiB 이하 | 정상 |
| 저장 후 증가량 일 환산 | 7,404,792 bytes/일 | 2 GiB/일 이하 | 정상 |

배포 직후 available은 정지선보다 2,119.895 MiB 높고 PVC 선언 합계는 변하지 않아
`LOKI-01` stop/go는 **GO**다. retained chunk와 일 환산 증가량은 hard cap보다 충분히 작다.

### `OBS-01` 배포 전·후 실측 (2026-08-03)

최신 main을 포함한 immutable root와 child에서 node·PVC·backup·certificate·Loki·Alloy 지표와
Alertmanager 실제 전달을 한 번 검증한 최종 성공 실행 값이다. 검증 뒤 child와 PVC는 시작 main
SHA로 rollback했으며 아래 값은 다음 main sync의 예상 기준선이다.

| 지표 | 실측 | 경고·정지 기준 | 판정 |
|---|---:|---|---|
| `k3s-01` 배포 직전 available | 10,273,751,040 bytes (9,797.812 MiB) | 12 GiB 미만 경고, 8 GiB 미만 정지 | 경고 구간 |
| 배포 직후 available / 감소량 | 9,978,179,584 / 295,571,456 bytes (9,515.934 / 281.879 MiB) | 8 GiB 미만 정지 | **GO** |
| swap / guest root 여유 | 0 bytes / 84% | swap 사용, root 여유 20% 미만 | 정상 |
| PVC 요청 합계 / OBS-01 | 75.125 / 9 GiB | 96 GiB 경고, 120 GiB 정지 | 정상 |
| Prometheus / Alertmanager PVC | 8 / 1 GiB | OBS-01 합계 10 GiB 이하 | 정상 |
| Prometheus running retention | 3일 / 6 GiB | PVC 8 GiB보다 작은 size cap | 정상 |

배포 직후 available은 8 GiB 정지선보다 1,323.93 MiB 높다. Wazuh 16 GiB를 더하면 PVC 선언
합계는 91.125 GiB로 96 GiB 경고선까지 4.875 GiB만 남으므로 `WAZUH-01`은 16 GiB와 index
overhead를 다시 판정하고, 부족하면 replica나 disk가 아니라 수집 source와 retention을 먼저 줄인다.
이후 상한을 넘으면 PVC·bucket을 늘리지 않고 허용 event class를 줄인다.

### `WAZUH-01` 배포 전 capacity gate (2026-08-03)

13:32 KST에 `K3S-HEAVY` 최초 적용 전에 읽기 전용으로 한 번 측정했다. Wazuh resource를
배포하지 않았으므로 post 값과 index 관측창은 없다. 배포 예상치는
[Wazuh 공식 Kubernetes 최소 요구량](https://documentation.wazuh.com/current/deployment-options/deploying-with-kubernetes/kubernetes-conf.html)의
가용 메모리 3 GiB를 사용했다. dashboard를 뒤로 미루거나 single-node로 줄여도 이 공식
최소값 아래를 용량 근거로 사용하지 않는다.

| 지표 | 배포 전 실측·예상 | 경고·정지 기준 | 판정 |
|---|---:|---|---|
| `k3s-01` available | 9,946,275,840 bytes (9.263 GiB) | 12 GiB 미만 경고, 8 GiB 미만 정지 | 경고 구간 |
| 8 GiB 정지선까지 RAM 여유 | 1,356,341,248 bytes (1.263 GiB) | Wazuh 최소 3 GiB를 수용해야 함 | 부족 |
| Wazuh 최소 3 GiB 적용 후 예상 available | 6,725,050,368 bytes (6.263 GiB) | 8,589,934,592 bytes (8 GiB) 이상 | **STOP** |
| 정지선 대비 예상 부족량 | 1,864,884,224 bytes (1.737 GiB) | 0 이하여야 함 | 부족 |
| swap / guest root 여유 | 0 bytes / 84% | swap 사용, root 여유 20% 미만 | 정상 |
| PVC 요청 합계 / Wazuh 예상 | 75.125 / 16 GiB | 96 GiB 경고, 120 GiB 정지 | 정상 |
| Wazuh 포함 예상 PVC 합계 | 91.125 GiB | 96 GiB 미만 | 정상, 4.875 GiB 여유 |

RAM 하나가 정지선을 깨므로 `WAZUH-01`은 정상 중단했다. replica·heap·PVC·disk를 늘리거나
공식 최소 아래로 줄이지 않았고, 선언·Kubernetes API audit·OPNsense agent·라이브 자원은
변경하지 않았다. 재진입 최소 조건은 배포 전 available 11 GiB(11,811,160,064 bytes) 이상,
swap 0, guest root 여유 20% 이상, Wazuh 포함 PVC 합계 96 GiB 미만이다. 이 조건을 만든
선행 capacity 회수 또는 RAM 재배정은 해당 소유 작업에서 처리하고 `WAZUH-01`은 그 뒤 같은
배포 전 gate부터 다시 시작한다.

### `CAP-03` RAM 증설 승인 전 실측 (2026-08-03)

13:50 KST에 strict SSH 읽기 전용 조회와 현재 OpenTofu state의 refresh plan으로 측정했다.
apply와 VM 재부팅 전 값이며, post 열은 4 GiB 차이를 단순 반영한 예상치다. 실제 완료
판정은 승인된 apply와 정상 재부팅 뒤 같은 지표를 한 번 재측정해 이 표에 추가한다.

| 지표 | 적용 전 실측 | 적용 후 목표·예상 | 경고·정지 기준 | 판정 |
|---|---:|---:|---:|---|
| Proxmox RAM 총량 / available | 67,136,507,904 / 29,864,136,704 bytes (62.526 / 27.813 GiB) | available 약 23.813 GiB | available 12 GiB 미만 경고, 8 GiB 미만 정지 | **GO** |
| Proxmox swap 사용 | 0 bytes | 0 bytes | 0 초과 재검토, 지속 사용 정지 | 정상 |
| VM RAM 회계 | 41 GiB (VM 40 + overhead 1) | 45 GiB (VM 44 + overhead 1) | 52 GiB 경고, 56.5 GiB 정지 | **GO**, 경고선까지 7 GiB |
| host load15 / root 사용률 | 0.52 / 5% | 실측 대상 | 20·70% 경고, 30·80% 정지 | 정상 |
| thin data / metadata | 5.76% / 0.43% | 변화 없음 | 60%·50% 경고, 각 70% 정지 | 정상 |
| VMID 120 memory / balloon | 24,576 / 0 MiB | 28,672 / 0 MiB | `k3s-01` 상한 36 GiB, balloon 금지 | **GO** |
| `k3s-01` 총 RAM / available | 24,926,670,848 / 9,857,167,360 bytes (23.215 / 9.180 GiB) | available 약 14,152,134,656 bytes (13.180 GiB) | Wazuh 재진입 11 GiB | **GO**, 2.180 GiB 예상 여유 |
| Wazuh 최소 3 GiB 반영 후 available | — | 약 10,930,909,184 bytes (10.180 GiB) | 8 GiB 정지 | **GO**, 2.180 GiB 예상 여유 |
| guest swap / root 여유 | 0 bytes / 84% | 실측 대상 | swap 사용 재검토, root 여유 20% 미만 정지 | 정상 |
| PVC 요청 / Wazuh 포함 예상 | 75.125 / 91.125 GiB | 변화 없음 | 96 GiB 경고, 120 GiB 정지 | 정상, 경고선까지 4.875 GiB |

baseline plan은 state resource 5개 모두 `no-op`, 비통과 check 0건이었다. 증설 선언의
허용 plan은 VMID 120의 `memory.dedicated 24576→28672` 한 건만
`0 add, 1 change, 0 destroy`여야 한다. CPU·disk·NIC·다른 VM·PVC 변화나 replace가 있으면
apply하지 않는다. 상세 승인 영향과 rollback은
[`k3s-01 RAM 증설 runbook`](runbook/k3s-ram-expansion.md)이 소유한다.

### `CAP-03` RAM 증설 전·후 실측 (2026-08-03)

수정 승인 binary plan을 실제 state에 한 번 적용하고, OS 재부팅으로 pending memory가 활성화되지
않은 원인을 확인한 뒤 승인된 cold start 한 번으로 VMID 120의 RAM을 활성화했다. 적용 전 값은
최종 apply 직전, 적용 후 값은 Vault·CrowdSec·Falco 재부팅 복구와 임시 검증 자원 제거 뒤의
완료 증거 실행이다.

| 지표 | 적용 전 실측 | 적용 후 실측 | 경고·정지 기준 | 판정 |
|---|---:|---:|---:|---|
| Proxmox RAM 총량 / available | 67,136,507,904 / 29,862,977,536 bytes (62.526 / 27.812 GiB) | 67,136,507,904 / 35,921,670,144 bytes (62.526 / 33.455 GiB) | available 12 GiB 미만 경고, 8 GiB 미만 정지 | **GO** |
| Proxmox swap 사용 | 0 bytes | 0 bytes | 0 초과 재검토, 지속 사용 정지 | 정상 |
| VM RAM 회계 | 41 GiB (VM 40 + overhead 1) | 45 GiB (VM 44 + overhead 1) | 52 GiB 경고, 56.5 GiB 정지 | **GO**, 경고선까지 7 GiB |
| host load15 / root 사용률 | 0.73 / 5% | 0.52 / 5% | 20·70% 경고, 30·80% 정지 | 정상 |
| thin data / metadata | 5.76% / 0.43% | 5.82% / 0.43% | 60%·50% 경고, 각 70% 정지 | 정상 |
| VMID 120 memory / balloon | 24,576 / 0 MiB | 28,672 / 0 MiB | `k3s-01` 상한 36 GiB, balloon 금지 | **GO** |
| `k3s-01` 총 RAM / available | 24,926,670,848 / 9,916,096,512 bytes (23.215 / 9.235 GiB) | 29,154,533,376 / 16,839,221,248 bytes (27.152 / 15.683 GiB) | Wazuh 재진입 11 GiB | **GO**, 재진입선 위 4.683 GiB |
| Wazuh 최소 3 GiB 반영 후 available | 6,694,871,040 bytes (6.235 GiB) | 13,617,995,776 bytes (12.683 GiB) | 8 GiB 정지 | **GO**, 정지선 위 4.683 GiB |
| guest swap / root 사용률 | 0 bytes / 16% | 0 bytes / 16% | swap 사용 재검토, root 여유 20% 미만 정지 | 정상 |
| PVC 요청 / Wazuh 포함 예상 | 75.125 / 91.125 GiB | 75.125 / 91.125 GiB | 96 GiB 경고, 120 GiB 정지 | 정상, 경고선까지 4.875 GiB |

최종 guest boot ID는 `4e745572-8cf3-4bd2-91c2-a572ad45a382`, k3s `/readyz=ok`, Node
`Ready`, Vault `sealed=false`, swap 0이다. Falco 재생성 회귀 뒤 Pod는 새 UID에서 Ready·restart
0이고 inotify 초기화 오류와 신규 `runAsNonRoot` admission 거부는 0건이었다. PVC는 9개,
요청 합계 75.125 GiB로 불변이다.

최종 OpenTofu refresh plan
`31a4985740727cc53b89d7b5d29b62d45a1ddc66def45f238c1fef68ab8a34d4`는 mode `0600`으로
저장소 밖에 있으며 state resource 5개가 모두 `no-op`, 변경 0건, 비통과 check 0건이다. plan
전후 state SHA-256은
`b6275be5d8ea2ffcdc5cb327c2a31857ea219f445581d0eaffb9828f2cbf68ea`로 불변이다. RAM·swap·disk·
PVC gate가 모두 정지선 안이므로 `WAZUH-01` 재진입 판정은 **GO**다.

### `WAZUH-01` 배포 전·후 실측 (2026-08-03)

`CAP-03` RAM 증설 뒤 같은 배포 전 gate부터 다시 시작해 **GO**로 판정하고 배포했다. 배포 전
값은 Argo 동기화 직전, 배포 후 값은 고정 관측창 907초가 끝난 완료 증거 실행이다. 두 값 모두
[`verify-live.sh`](../gitops/tools/wazuh-01/verify-live.sh)가 같은 방법으로 읽었다.

| 지표 | 배포 전 실측 | 배포 후 실측 | 경고·정지 기준 | 판정 |
|---|---:|---:|---:|---|
| `k3s-01` available | 17,130,917,888 bytes (15.955 GiB) | 14,584,446,976 bytes (13.583 GiB) | 12 GiB 경고, 8 GiB 정지 | **GO**, 정지선 위 5.583 GiB |
| Wazuh 배포로 인한 available 감소 | — | 2,546,470,912 bytes (2.372 GiB) | 공식 최소 3 GiB 이내 | 정상 |
| guest swap 사용 | 0 bytes | 0 bytes | 0 초과 재검토 | 정상 |
| guest root 여유 | 84% | 82% | 20% 미만 정지 | 정상 |
| PVC 요청 합계 | 80,664,854,528 bytes (75.125 GiB) | 97,844,723,712 bytes (91.125 GiB) | 96 GiB 경고, 120 GiB 정지 | 정상, 경고선까지 4.875 GiB |
| Wazuh PVC 선언 | — | indexer 15 GiB + manager 1 GiB = 16 GiB | 합계 16 GiB 상한 | 정상, 상한 일치 |

고정 관측창 907초의 실제 index 저장 증가량과 보존 기간 환산은 다음과 같다. 환산은
증가량을 일 단위로 늘린 뒤 각 코드의 보존 기간을 곱한 값이며 상한 판정에만 쓴다.

| 코드 | 창 증가량 | 일 환산 | 일일 상한 | 기간 환산 | 기간 상한 | 판정 |
|---|---:|---:|---:|---:|---:|---|
| `D30` | 63,386 bytes | 6,038,093 bytes (5.758 MiB) | 256 MiB | 181,142,790 bytes (0.169 GiB) | 7.5 GiB | 정상, 상한의 2.25% |
| `A90` | 231,392 bytes | 22,042,192 bytes (21.021 MiB) | 96 MiB | 1,983,797,280 bytes (1.848 GiB) | 8.4375 GiB | 정상, 상한의 21.90% |
| 전체 | 294,778 bytes | — | — | 2,164,940,070 bytes (2.016 GiB) | 16 GiB | 정상, 상한의 12.60% |

`D30`이 상한의 2.25%에 머무는 것은 `NIDS-01`이 fingerprint 없이 `any -> any`로 등록한
사용자 정의 테스트 시그니처 3건을 중앙 저장에서 제외했기 때문이다. 제외 전 OPNsense
Suricata는 2.06 alert/s(약 177,826건/일, `eve.json` 225 MB/일)를 냈고 그중 99.87%가 이 3건이라
그대로 저장하면 `D30` 상한을 넘는다. 경계와 근거는
[`gitops/apps/wazuh/README.md`](../gitops/apps/wazuh/README.md)가 소유한다.

`A90`은 Kubernetes API audit이며 `level: Metadata` 전량 수집은 raw 135.6 MiB/일로 상한의
141%였다. control plane 내부 주체의 조정 트래픽을 제외하고 credential·권한 경계 쓰기와
비-system 주체의 모든 요청만 남겨 raw 8.33 MiB/일로 줄인 뒤 배포했다. 정책 본문은
[`infra/ansible/roles/k3s_baseline/files/audit-policy.yaml`](../infra/ansible/roles/k3s_baseline/files/audit-policy.yaml)가
소유한다.

`local-path`는 PVC 요청량을 강제하지 않는다. 16 GiB는 선언·회계 상한이고 실제 저장 상한은
Wazuh indexer의 `D30`·`A90` ISM 보존 정책과 위 환산 판정이 지킨다.

### `CAP-04` Shuffle 진입 capacity gate (2026-08-03)

20:28 KST에 `SOAR-01` 배포 전 용량을 읽기 전용으로 측정했다. [Shuffle 공식 self-hosted
설치 가이드](https://github.com/Shuffle/Shuffle/blob/main/.github/install-guide.md)는 자체
OpenSearch를 포함한 기본 설치에 available RAM 최소 4 GB를 요구한다. 단위 혼용으로 최소값을
낮추지 않도록 이를 4 GiB로 보수적으로 잡았으므로 `SOAR-01` 진입선은 `k3s-01`의 8 GiB
available 정지선 + Shuffle 최소 4 GiB = **12 GiB**(12,884,901,888 bytes)다. Shuffle은
Wazuh indexer를 공유하지 않고 자기 OpenSearch를 별도 Stateful workload로 배포한다.

Proxmox 한 번의 strict SSH 호출 안에서 host 값과 QEMU guest agent 조회를 묶었지만 설치된
정책이 `guest-exec`를 금지해 guest 구간만 실행 전 중단됐다. host를 다시 읽지 않고 52초 뒤
`k3s-01` strict SSH 한 번으로 누락된 guest·PVC 값만 보완했다. 두 호출 모두 읽기 전용이며
OpenTofu, VM 전원, Kubernetes object와 Vault에는 변경이 없다.

| 지표 | 현재 실측·배정 | 경고·정지 또는 진입 기준 | 판정 |
|---|---:|---:|---|
| Proxmox RAM 총량 / available | 67,136,507,904 / 27,532,869,632 bytes (62.526 / 25.642 GiB) | available 12 GiB 미만 경고, 8 GiB 미만 정지 | 정상 |
| Proxmox swap 사용 | 0 bytes | 0 초과 재검토, 지속 사용 정지 | 정상 |
| VM RAM 회계 | 45 GiB (VM 44 + overhead 1) | 52 GiB 경고, 56.5 GiB 정지 | **GO**, 경고선까지 7 GiB |
| host load15 / root 사용률 | 0.70 / 5% | 20·70% 경고, 30·80% 정지 | 정상 |
| thin data / metadata | 6.23% / 0.44% | 60%·50% 경고, 각 70% 정지 | 정상 |
| `k3s-01` 총 RAM / available | 29,154,533,376 / 14,481,977,344 bytes (27.152 / 13.487 GiB) | 진입선 12 GiB | **GO**, 진입선 위 1.487 GiB |
| Shuffle 최소 4 GiB 반영 후 예상 available | 10,187,010,048 bytes (9.487 GiB) | 8 GiB 정지 | **GO**, 정지선 위 1.487 GiB |
| guest swap / root 사용률 | 0 bytes / 18% | swap 사용 재검토, root 여유 20% 미만 정지 | 정상 |
| PVC 요청 합계 | 91.125 GiB | 96 GiB 경고, 120 GiB 정지 | 정상, 경고선까지 4.875 GiB |
| Shuffle PVC 배정 | OpenSearch 16 GiB + file data 4 GiB = 20 GiB | read-only PoC의 선언 합계 상한 | 배정 |
| Shuffle 포함 예상 PVC 합계 | 111.125 GiB | 96 GiB 경고, 120 GiB 정지 | **경고·GO**, 정지선까지 8.875 GiB |

Shuffle의 공식 최소값은 RAM만 명시하고 storage 최소값은 고정하지 않는다. 20 GiB는 공식값이
아니라 Wazuh 원본 event를 중복 보존하지 않는 read-only PoC의 로컬 상한이다. `SOAR-01`은
OpenSearch 16 GiB와 file data 4 GiB를 넘겨 선언하지 않고, 배포 직전 현재 PVC 합계 + 20 GiB가
120 GiB 미만인지 다시 판정한다. 96 GiB 초과는 재예산 경고지만 배포 금지는 아니며, 120 GiB에
닿으면 배포를 중단한다.

현재 available이 12 GiB 진입선을 넘으므로 `k3s-01` 32 GiB 증설 조건은 성립하지 않았다.
`locals.tf`, OpenTofu state, VM 전원과 Vault를 바꾸지 않았고 live 변경은 0이다. 최종 OpenTofu
plan `31a59bdd3c3e5363b0e2d0ced701afbc3a47b35dd84d86e6022db2aa4f28a59b`은 state resource
5개 모두 `no-op`, 변경·비통과 check 0건이다. plan 전후 state SHA-256은
`b6275be5d8ea2ffcdc5cb327c2a31857ea219f445581d0eaffb9828f2cbf68ea`로 불변이다.

### `CAP-05` RAM 증설 적용 전·후 실측 (2026-08-04)

`WAZUH-02`가 `SOAR-01` 진입선 12 GiB에 169,750,528 bytes 미달로 확인한 뒤, 같은 조건을
재확인하고 `k3s-01`을 28 GiB에서 32 GiB로 올렸다. 적용 전 값은 OpenTofu plan 생성 직전,
적용 후 값은 cold start·Vault·CrowdSec 복구와 최종 refresh plan까지 끝난 완료 증거
실행이다.

| 지표 | 적용 전 실측 | 적용 후 실측 | 경고·정지 또는 진입 기준 | 판정 |
|---|---:|---:|---:|---|
| Proxmox available / swap | 25,124,044,800 bytes (23.394 GiB) / 0 bytes | 32,170,692,608 bytes (29.960 GiB) / 0 bytes | available 12 GiB 미만 경고, 8 GiB 미만 정지 | **GO** |
| host load15 / root 사용률 | 0.86 / 5% | 1.12 / 5% | 20·70% 경고, 30·80% 정지 | 정상 |
| thin data / metadata | 6.89% / 0.47% | 6.93% / 0.47% | 60%·50% 경고, 각 70% 정지 | 정상 |
| VM RAM 회계 | 45 GiB (VM 44 + overhead 1) | 49 GiB (VM 48 + overhead 1) | 52 GiB 경고, 56.5 GiB 정지 | **GO**, 경고선까지 3 GiB |
| VMID 120 memory / balloon | 28,672 / 0 MiB | 32,768 / 0 MiB | `k3s-01` 상한 36 GiB, balloon 금지 | **GO** |
| `k3s-01` 총 RAM / available | 29,154,533,376 / 12,710,690,816 bytes (27.152 / 11.837 GiB) | 33,382,391,808 / 18,511,921,152 bytes (31.089 / 17.244 GiB) | `SOAR-01` 진입선 12 GiB(12,884,901,888 bytes) | 적용 전 **미달**(174,211,072 bytes 부족) → 적용 후 **GO**, 진입선 위 5,627,019,264 bytes(5.240 GiB) |
| guest swap / root 사용률 | 0 bytes / 20% | 0 bytes / 20% | swap 사용 재검토, root 여유 20% 미만 정지 | 정상 |
| PVC 요청 합계(11개) | 97,844,723,712 bytes (91.125 GiB) | 97,844,723,712 bytes (91.125 GiB) | 96 GiB 경고, 120 GiB 정지 | 불변, 경고선까지 4.875 GiB |

적용 직전 real state의 harmless refresh(게스트 agent가 보고하는 `ipv4_addresses`·
`mac_addresses` 배열 순서만 재정렬, 다른 속성 diff 0건)로 최초 승인 plan
`553a8fcebf5c53c7f200d6183c7baaa97f2c7d5a3fae5366447c6a8e3ecf4ba8`이 stale해졌다. 같은
state에서 다시 만든 plan `dc5d2d9bb8f11908b3887fe871f66eefd7819c3c731cb51178f772ee2bcafaae`은
승인 범위와 동일하게 VMID 120의 `memory.dedicated 28672→32768` 한 건만 `0 add, 1 change,
0 destroy`였다. state SHA-256은 `f91f85cb0dec985f5ac84ac32957a9328e9684ea0bfceb60467122f5bc8974a7`
(serial 5, rollback 지점)에서 `d42951947dc3c08d0295bda8614d943abbf09ff843bbdb4b27b6d65221634bc7`
(serial 6)로 바뀌었고, OpenTofu 자체 pre-apply backup(`c42ee0f95ea72ca431b3c5443e964aabd04fecf1a24e5b5739ca935d6f9d317f`,
serial 5)을 저장소 밖 mode `0600` 사본으로 이중 보관했다.

Proxmox `qm pending`이 `cur memory: 28672`·`new memory: 32768`로 나뉘어 있어 `CAP-03`과
같이 정상 재부팅으로는 활성화되지 않음을 먼저 확인했다. guest `sudo shutdown -h now`로
정상 종료한 뒤 VMID 120을 cold start했다. boot ID는
`4e745572-8cf3-4bd2-91c2-a572ad45a382`에서 `5ebae80a-04a7-4765-a2c7-e8b9c037500d`로
바뀌었고, k3s는 재기동 직후 `active`, Node `Ready`였다. Vault는 `KMS-01`이 도입한 AWS KMS
auto-unseal(`Seal Type: awskms`)로 별도 키 입력 없이 `Sealed: false`·`HA Mode: active`가
됐다.

재부팅이 모든 Pod를 한 번씩 재시작하며 `CAP-03`에서 이미 관측된 것과 같은 계열의 결함이
재현됐다. `crowdsec-appsec` Deployment의 init container
`extract-crowdsec-01-crs-snapshot`이 새 sandbox에서 exit code 1로 실패해 `crowdsec`
Application이 `Progressing`에 머물렀다(스크립트가 표준출력을 `/dev/null`로 버려 정확한
실패 지점은 로그에 남지 않았다). `CAP-03`과 동일하게 정확한 Pod 한 건만 삭제해
ReplicaSet이 새 sandbox로 재생성하게 하자 다음 시도에서 Ready가 됐다. `kube-system`의
`helper-pod-delete-pvc-*` 여러 개가 SELinux 권한 거부로 반복 실패·재생성되는 현상도
관측했으나, 이는 `K3S-01` 완료 보고가 이미 남긴 local-path 삭제 helper의 SELinux 환경
한계와 같은 계열이며 이번 재부팅이 새로 만든 결함이 아니다. 두 현상 모두 PVC 선언·Argo
동기화 대상·capacity gate에는 영향이 없어 `CAP-05` 범위에서 고치지 않았다.

최종 refresh plan `02cb0bd3683c401596fa91ac7baacb7b4fa5da6ddbab54bca5ee87ff0865fd1d`은
state resource 5개 모두 `no-op`, 변경·비통과 check 0건이며 plan 전후 state SHA-256은
`d42951947dc3c08d0295bda8614d943abbf09ff843bbdb4b27b6d65221634bc7`로 불변이다. Argo
Application 22개는 모두 `Synced/Healthy`(commit `dfdd2c29091d40de146a1ba725af69a7fb42f69d`)로
돌아왔다. `k3s-01` available이 `SOAR-01` 진입선 12 GiB를 5.240 GiB 웃도므로 `SOAR-01` 진입
판정은 **GO**다. 상세 절차와 rollback은
[`k3s-01 RAM 증설 runbook`](runbook/k3s-ram-expansion.md)이 소유한다.

### `SOAR-DASH-01` 배포 직전 capacity gate (2026-08-04)

`CAP-05` 완료로 `SOAR-01`(현 `SOAR-DASH-01`) 진입선을 충족한 직후, 실제 Shuffle 배포 직전에
읽기 전용으로 재측정했다. 전용 SSH known_hosts와 Proxmox root 계정으로 확인했으며 이 호출은
아무 상태도 바꾸지 않는다.

| 지표 | 실측 | 경고·정지 또는 진입 기준 | 판정 |
|---|---:|---:|---|
| Proxmox available / swap | 29,789,491,200 bytes (27.746 GiB) / 0 bytes(8 GiB 중) | available 12 GiB 미만 경고, 8 GiB 미만 정지 | 정상 |
| host load15 / thin data·metadata | 0.58 / 6.94%·—(local dir 4.44%) | 20·70% 경고, 30·80% 정지 / 60%·50% 경고, 각 70% 정지 | 정상 |
| `k3s-01` available | 17,841,184,768 bytes (16.617 GiB) | `SOAR-DASH-01` 진입선 12 GiB(12,884,901,888 bytes) | **GO**, 진입선 위 4.937 GiB |
| guest swap / root 사용률 | 0 bytes / 20%(161G/199G avail) | swap 사용 재검토, root 여유 20% 미만 정지 | 정상 |
| PVC 요청 합계(11개, 실측) | 97,844,723,712 bytes (91.125 GiB) | 96 GiB 경고, 120 GiB 정지 | 불변 |
| Shuffle PVC 배정(opensearch 16Gi + backend-files 4Gi) | 20 GiB | dashboard-only PoC 선언 합계 상한(`CAP-04`가 잡은 값 그대로 재사용) | 배정 |
| Shuffle 배포 후 예상 PVC 합계 | 111.125 GiB | 96 GiB 경고, 120 GiB 정지 | **경고·GO**, 정지선까지 8.875 GiB |
| Argo Application(22개) | 전량 `Synced/Healthy` | — | 정상 |

`CAP-04`가 계산한 진입선(available 12 GiB)과 PVC 20 GiB 상한은 Shuffle 엔진(backend·frontend)과
전용 OpenSearch를 배포할 때 실제로 소비되는 값이므로 그대로 재사용한다. orborus·worker는 이
배포에 포함하지 않아(SOAR-01 워크플로 단계 범위) 추가 RAM·PVC를 소비하지 않는다. 어느 지표도
경고선을 새로 넘기지 않아 배포를 진행한다.

## 재검토 시점

- `VM-01` 직후: 실제 배정과 기준표를 대조하고 차이를 기록한다.
- `K3S-HEAVY` 배포 전후: Wazuh·관측 스택은 한 번에 하나씩 올리고 매번 위 지표를 다시 읽는다.
- `SCM-01`·`REG-01`·`QUALITY-01`·`AWX-01` 직후: 한 번에 하나씩 위 지표를 다시 읽고 다음 배포의 stop/go를 판정한다.
- 하드웨어 변경: 두 번째 SSD 장착(`PVE-BKP-01`), RAM 증설, 물리 노드 추가.

## 이 문서가 소유하지 않는 것

| 내용 | 단일 원본 |
|---|---|
| 주소·VLAN·DNS | [`ip-plan.md`](ip-plan.md) |
| 서비스 배치와 역할 경계 | [`architecture.md`](architecture.md) |
| 작업 상태와 의존성 | [`backlog.md`](backlog.md) |
| 하드웨어 식별·설치 선택값·LVM 배분의 유래 | [`runbook/proxmox-manual-install.md`](runbook/proxmox-manual-install.md) |
| 단일 k3s와 local storage를 고른 이유 | [ADR-0002](adr/0002-single-node-k3s-and-local-storage.md) |
| VM을 나눈 이유 | [ADR-0003](adr/0003-service-vm-boundaries.md) |
