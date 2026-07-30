# Proxmox VE 수동 설치

검증일: 2026-07-30. 주소는 `docs/ip-plan.md`, 자동화 경계는 [ADR-0001](../adr/0001-proxmox-bootstrap-reproducibility.md)이 소유한다.

## 목적

공식 ISO 그래픽 installer로 유일한 물리 노드에 Proxmox VE 기준선을 만들고, 재부팅까지 검증된 선택값을 고정한다. `AUTO-01`의 answer file 템플릿은 이 문서에서 검증된 값만 옮긴다. 일반 client가 신뢰하는 관리 인증서는 설치 완료 판정에 섞지 않고 후속 `PVE-ACME-01`이 소유한다.

## 전제와 영향

- `PVE-LIVE` 잠금을 단독으로 소유한다.
- 대상 디스크의 기존 OS는 완전히 삭제된다. 이번 설치는 기존 Rocky Linux 9를 지웠다.
- PiKVM 등 독립 콘솔로 화면·키보드·가상 부팅 매체를 제어할 수 있다.
- installer는 임시 DHCP 주소로 뜨고, 최종 주소는 Management Network 화면에서 사람이 덮어쓴다. 임시 주소는 문서에 배정으로 올리지 않는다.
- OPNsense와 VLAN은 이 절차에서 바꾸지 않는다. Phase 1 untagged LAN을 그대로 쓴다.
- **power off를 하지 않는다.** 원격 전원 투입 경로가 없다. 재시작은 `systemctl reboot`만 쓴다.

## 대상 하드웨어

설치 후 실측한 값이다. 재설치 때 대상을 식별하는 기준으로 쓴다.

| 항목 | 값 |
|---|---|
| CPU | 13th Gen Intel Core i7-13700H, 1 socket / 14 core / 20 thread |
| RAM | 62 GiB |
| 설치 디스크 | NVMe `SHGP31-1000GM` (SK hynix Gold P31 1TB), 931.5 GB |
| 관리 NIC | `igc` 드라이버, MAC `e8:9c:25:8a:f1:17` |
| 미사용 NIC | 무선 `wlp3s0`, MAC `a4:f9:33:c6:f3:c2`. 프로젝트 데이터 플레인 밖이며 `DOWN`으로 둔다 |
| 부팅 모드 | UEFI |
| 설치 매체 | PiKVM 가상 광학 드라이브, ISO label `PVE` |
| 설치 결과 | Proxmox VE 9.2.0 / pve-manager 9.2.2 / kernel 7.0.2-6-pve / Debian 13 |

디스크가 하나뿐이어도 Target Harddisk 드롭다운에는 가상 광학 드라이브가 함께 보인다. 모델명과 용량으로 판별한다.

## 설치 화면 선택값

| 화면 | 항목 | 선택값 |
|---|---|---|
| EULA | — | 동의 |
| Target Harddisk | 대상 | 위 표의 NVMe. 설치 매체(`Optical Drive`)나 다른 디스크를 고르지 않는다 |
| Harddisk options | Filesystem | `ext4` |
| | hdsize | installer가 감지한 전체 용량 그대로. 줄이면 그만큼 미사용으로 버려진다 |
| | swapsize · maxroot · minfree · maxvz | 전부 빈칸. 빈칸이 자동 배분이다 |
| Location and Time Zone | Country | `Korea, Republic of` (영문 입력) |
| | Time zone | `Asia/Seoul`. Country 입력 시 자동 반영되며 눈으로 확인한다 |
| | Keyboard Layout | `U.S. English`. 한글 키보드도 물리 배열은 US다 |
| Administration Password | Password | 콘솔에서 사람이 직접 입력한다. 기록·전달하지 않는다 |
| | Email | 운영자 알림 주소. `root@pam` 사용자에 반영된다 |
| Management Network | Management Interface | 링크가 올라온 유선 NIC. 위 표의 MAC과 대조한다 |
| | Hostname (FQDN) | `ip-plan.md` DNS 표의 `proxmox-01` 이름. installer 기본값 `pve.<도메인>`을 **반드시 교체한다** |
| | IP Address (CIDR) | `ip-plan.md` 고정 배정의 `proxmox-01` 주소와 `/24`. 임시 DHCP 주소를 교체한다 |
| | Gateway · DNS Server | `ip-plan.md`의 LAN gateway |
| | Pin network interface names | 체크 유지 |
| Summary | — | 대상 디스크·filesystem·hostname·IP를 다시 읽고 나서 Install |

### Pin network interface names

체크하면 installer가 MAC에 인터페이스 이름을 고정하는 link 파일을 만든다. 위치는 `/etc/systemd/network/`가 아니라 **`/usr/local/lib/systemd/network/50-pmx-nic<N>.link`** 다.

- `nic0` — 유선 NIC에 적용된다. pin이 없으면 `enp2s0`이 됐을 이름이다.
- `nic1` — 무선 NIC의 MAC으로도 파일이 생성되지만 `[Match] Type=ether`가 무선(`wlan`)과 맞지 않아 적용되지 않는다. 그 결과 `/etc/network/interfaces`에 실체 없는 `iface nic1 inet manual` 항목이 남는다. `auto`가 없어 부팅 시 활성화를 시도하지 않으므로 무해하다.

유지하는 이유는 복구 경로다. 커널이나 하드웨어 변경으로 인터페이스 이름이 바뀌면 `vmbr0`의 `bridge-ports`가 깨져 유일한 관리 경로를 잃고, 남는 복구 수단은 콘솔뿐이다.

## 실행 순서와 중단 조건

1. 독립 콘솔에서 화면·키보드와 가상 부팅 매체를 확인한다.
2. 그래픽 installer를 부팅한다.
3. 위 표대로 화면별 값을 입력한다.
4. Summary에서 대상 디스크·filesystem·hostname·IP를 다시 읽는다.
5. 재부팅 전에 부팅 순서를 확인한다. `efibootmgr`의 1순위가 디스크 항목이어야 하고 가상 광학 드라이브는 그 뒤여야 한다. 확실히 하려면 콘솔에서 가상 매체를 detach한다.
6. 아래 성공 판정을 모두 통과시킨다.
7. 한 번 재부팅하고 같은 판정을 반복한다.

Install을 누르기 전에 다음 중 하나라도 있으면 멈추고 `Previous`로 되돌린다.

- Target Harddisk에 예상 모델·용량이 아닌 장치가 선택되어 있다.
- Summary의 hostname 또는 IP가 `ip-plan.md`와 다르다.
- 최종 관리 주소가 이미 다른 장비에서 응답한다.

Install 이후에는 되돌릴 수 없다.

## 성공 판정

관리 워크스테이션에서. 주소는 `ip-plan.md`의 `proxmox-01` 값을 넣는다.

아래 `-k`는 설치 직후 PVE Cluster Manager CA 기준선을 확인하기 위한 의도된 예외다. `PVE-ACME-01` 완료 후의 정상 운영과 OpenTofu 검증에는 사용하지 않는다.

```sh
ping -c 3 <proxmox-01>
curl -sk -o /dev/null -w '%{http_code}\n' https://<proxmox-01>:8006/
curl -sk https://<proxmox-01>:8006/ | grep -oE '<title>[^<]*</title>'
echo | openssl s_client -connect <proxmox-01>:8006 2>/dev/null | openssl x509 -noout -subject
ssh root@<proxmox-01> true
```

호스트에서.

```sh
hostname -f
ip -4 -br addr show; ip route show; cat /etc/resolv.conf
ip -br link show
pveversion
systemctl is-active pve-cluster pvedaemon pveproxy pvestatd
systemctl --failed
pvesm status
findmnt -n -o SOURCE,TARGET,FSTYPE /
timedatectl
efibootmgr | grep -E '^Boot(Order|Current)|^Boot0'
```

통과 기준은 다음과 같다.

| 항목 | 기대값 |
|---|---|
| HTTPS 8006 | `200`, `Server: pve-api-daemon/3.0`, `<title>`에 hostname |
| 서버 인증서 | `CN`이 `ip-plan.md`의 `proxmox-01` FQDN. 발급자는 PVE Cluster Manager CA (자체 서명) |
| SSH | TCP 22 응답, 실제 로그인 성공 |
| `hostname -f` | `ip-plan.md`의 `proxmox-01` FQDN |
| 주소·경로·DNS | `vmbr0`에 고정 주소 `/24`, 기본 경로와 nameserver가 LAN gateway, `search`가 랩 도메인 |
| 인터페이스 이름 | `nic0`이 `UP,LOWER_UP`, `vmbr0`이 같은 MAC |
| 서비스 | `pve-cluster` · `pvedaemon` · `pveproxy` · `pvestatd` 전부 `active` + `enabled` |
| `systemctl --failed` | 0 units |
| 스토리지 | `local`(dir)과 `local-lvm`(lvmthin) 모두 `active` |
| root filesystem | `/dev/mapper/pve-root`, `ext4` |
| 시각 | `Asia/Seoul (KST, +0900)`, NTP active, 동기화됨 |
| 부팅 순서 | 1순위가 디스크의 `\EFI\proxmox\shimx64.efi` |

재부팅 후에는 `uptime -s`가 바뀐 것을 확인하고 위 판정을 전부 반복한다. 부팅 직후 몇 초간 ICMP가 빠질 수 있으므로 재시도로 판정한다.

## 실측 자원 배분

`ext4`를 고르면 LVM 위에 설치되고, 빈칸으로 둔 값들은 아래처럼 배분된다.

| 대상 | 크기 | 비고 |
|---|---|---|
| `pve/swap` | 8.00 GiB | RAM이 62 GiB여도 installer 기본 상한이 8 GiB다 |
| `pve/root` | 96.00 GiB | `/`, ext4. `local` 스토리지가 여기 있다. `maxroot` 기본은 `hdsize/4`이지만 **96 GiB 상한**이 걸린다 |
| `pve/data` | 793.80 GiB | `local-lvm` LVM-thin 풀. VM 디스크 |
| VG 여유 | 16.00 GiB | `minfree` 기본값 |
| `local` (dir) | 약 93.9 GiB, 설치 직후 약 85 GiB 여유 | ISO·컨테이너 템플릿·백업 |
| `local-lvm` (lvmthin) | 약 793.8 GiB, 사용 0% | |

파티션은 `1007 KiB EF02` + `1024 MiB EF00`(`/boot/efi`, vfat) + `930 GiB 8E00`(LVM)이다.

이 값과 20 vCPU · 62 GiB RAM을 기준으로 정한 VM별 예산과 정지 기준은 [`capacity-plan.md`](../capacity-plan.md)가 소유한다. `local-lvm`은 thin 풀이라 과할당이 가능하므로 요청량이 아니라 실제 사용량을 감시한다 ([ADR-0002](../adr/0002-single-node-k3s-and-local-storage.md)).

## 알려진 잔여물

| 항목 | 판단 |
|---|---|
| `/etc/network/interfaces`의 `iface nic1 inet manual` | 실체 없는 항목. `auto`가 없어 무해하다. `NET-02`가 bridge를 편집할 때 무시한다 |
| `vmbr0`에 `bridge-vlan-aware`·`bridge-vids` 없음 | Phase 1 untagged가 맞다. `NET-02`가 tagged-only trunk로 바꾼다 |
| 웹 UI의 PVE Cluster Manager CA 인증서 | 설치 기준선에서는 예상 동작이다. 브라우저 경고 제거·DNS-01·자동 갱신·strict TLS 전환은 [`PVE-ACME-01`](../backlog.md)이 소유하며 완료 전까지 잔여물이다 |
| `lsblk`의 `sr0` | 가상 설치 매체가 아직 붙어 있다는 뜻이다. 부팅 순서만 확인하면 재부팅은 안전하고, 확실히 하려면 detach한다 |

## 중단과 복구

설치 전 상태로 되돌리는 경로는 없다. 이 절차의 되돌림 단위는 "공식 ISO로 같은 값 재설치"다.

1. 관리 주소가 응답하지 않으면 콘솔에서 `ip -br link`로 인터페이스 이름과 carrier를 확인하고 `/etc/network/interfaces`의 `bridge-ports`와 대조한다.
2. 이름이 어긋나면 `/usr/local/lib/systemd/network/50-pmx-nic0.link`의 MAC과 실제 MAC을 확인한다.
3. 서비스 장애는 `systemctl --failed`와 `journalctl -b -p err`로 좁힌다.
4. 부팅이 설치 매체로 넘어가면 `efibootmgr`로 순서를 되돌리거나 가상 매체를 detach한다.
5. 어떤 경우에도 power off를 하지 않는다.

## 시크릿과 남기지 않는 출력

- root 비밀번호는 콘솔에서 사람이 입력한다. 대화·로그·명령줄·Git에 남기지 않는다.
- 검증용 SSH 접근은 공개키 인증으로 전환한다. 비밀번호를 스크립트나 명령 인자에 넣지 않는다.
- `/etc/pve`의 인증서 개인키, `/etc/ssh`의 host key와 스토리지 자격증명은 커밋하지 않는다.
- ACME DNS token을 설치 answer, 생성 ISO, 셸 기록 또는 이 runbook에 넣지 않는다. 설치 후 입력·저장 경계는 [ADR-0009](../adr/0009-proxmox-native-acme-management-tls.md)을 따른다.
- 디스크·NIC 시리얼 등 식별자는 필요한 최소만 남긴다. 이 문서는 모델명과 관리 NIC의 MAC만 소유한다.
