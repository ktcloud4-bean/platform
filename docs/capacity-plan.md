# 자원 예산과 정지 기준

측정일: 2026-07-30. 이 문서는 `proxmox-01` 한 대의 CPU·RAM·디스크 예산과 정지 기준을 소유한다. 목표 배치는 `architecture.md`, 주소는 `ip-plan.md`, 작업 상태는 `backlog.md`가 계속 소유한다.

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
| `minio-01` | 2 | 4 | 4 GiB | 8 GiB | 200 GiB | 320 GiB |
| `warpgate-01` | 2 | 4 | 2 GiB | 4 GiB | 40 GiB | 80 GiB |
| `netbird-01` | 2 | 4 | 2 GiB | 4 GiB | 32 GiB | 64 GiB |
| **Day 1 합계** | **18** | — | **40 GiB** | — | **572 GiB** | — |

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
| 프로비저닝 상한 (`CAP-02` 이전) | 714 GiB — 풀의 90%, 과할당 금지 |
| 과할당 절대 상한 (`CAP-02` 이후) | 992 GiB — 1.25:1 |

상한 열을 모두 적용하면 944 GiB로 1.19:1이 된다. 이는 `CAP-02`에서 실사용 데이터를 근거로만 허용한다.

### 실사용 정지 기준

판정은 프로비저닝 합계가 아니라 `lvs -o data_percent pve/data`의 실사용률로 한다.

| 사용률 | 상태 | 조치 |
|---|---|---|
| 60% 미만 | 정상 | — |
| 60–70% | 경고 | 보존기간·이미지 정리, 증설 계획 수립. 신규 대용량 워크로드 보류 |
| 70% 이상 | 정지 | 신규 VM 생성·디스크 확장·`K3S-HEAVY` 배포 금지 |
| 85% 이상 | 비상 | 데이터 투입 중단. `fstrim`으로 회수하고 실패 시 워크로드를 줄인다 |

metadata 사용률은 50%에서 경고, 70%에서 정지한다. 현재 0.24%다.

풀이 소진되면 게스트 쓰기가 실패하고 파일시스템이 손상될 수 있다. `lvextend`로 벌 수 있는 시간은 VG 여유 16.00 GiB, 곧 풀의 2.0%뿐이다. 85%를 비상으로 두는 근거가 이것이다.

## `local` (dir) 예산

`local`은 `/`와 같은 ext4 파일시스템이다. 여기가 차면 `pve-cluster`·`pveproxy`·journald가 함께 실패한다. VM 디스크와 완전히 분리된 예산으로 관리한다.

| 항목 | 예산 | 근거 |
|---|---|---|
| 호스트 OS·PVE 사용 중 | 4.13 GiB | 실측 |
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
- 대용량 저장은 k3s 밖으로 뺀다. Harbor registry backend와 Loki chunk는 `minio-01`의 S3, 관계형 데이터는 `postgres-01`을 쓴다. 이 선택이 무너지면 120 GiB 예산이 가장 먼저 깨진다.
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

## 나머지 VM 디스크 구획

| VM | 총량 | 구획 |
|---|---|---|
| `postgres-01` | 100 GiB | OS 10 · PGDATA 60 · WAL·아카이브 20 · 여유 10 |
| `minio-01` | 200 GiB | OS 10 · 버킷 데이터 170 · 여유 20 |
| `warpgate-01` | 40 GiB | OS 10 · 세션 기록 20 · 여유 10 |
| `netbird-01` | 32 GiB | OS 10 · 제품 DB·로그 12 · 여유 10 |

`minio-01`의 170 GiB는 `k3s-01` PVC 120 GiB와 `postgres-01` 데이터 80 GiB를 받는 착지점이다. 보존 세대 수가 예산을 결정하므로 `BKP-02`–`BKP-04`가 보존기간을 확정할 때 이 값을 다시 본다. `warpgate-01`의 세션 기록도 용량이 아니라 보존기간으로 통제한다.

## 정지 기준 요약

| 지표 | 확인 방법 | 경고 | 정지 |
|---|---|---|---|
| thin 풀 사용률 | `lvs -o data_percent pve/data` | 60% | 70% |
| thin metadata 사용률 | `lvs -o metadata_percent pve/data` | 50% | 70% |
| 호스트 RAM 여유 | `free -m`의 `available` | 12 GiB 미만 | 8 GiB 미만 |
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

## 재검토 시점

- `VM-01` 직후: 실제 배정과 기준표를 대조하고 차이를 기록한다.
- `K3S-HEAVY` 배포 전후: Wazuh·관측 스택은 한 번에 하나씩 올리고 매번 위 지표를 다시 읽는다.
- `CAP-02`: `BKP-05`와 `HEADLAMP-02` 이후 실측으로 전면 재예산한다. 과할당 허용 여부도 여기서 결정한다.
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
