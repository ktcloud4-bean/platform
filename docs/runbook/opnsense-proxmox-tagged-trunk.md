# OPNsense – Proxmox tagged-only trunk 전환 절차

검증일: 2026-07-31. 주소는 `docs/ip-plan.md`, 자동화 경계는 [ADR-0008](../adr/0008-opentofu-provider-and-state-boundary.md)을 따른다.

## 1. 목적과 검증일

OPNsense `igc2` 물리 포트와 Proxmox `vmbr0` 간의 물리 링크를 untagged Phase 1 LAN에서 802.1Q tagged-only trunk로 전환한다. 이 절차는 OPNsense 위에 목표 5개 VLAN(VLAN 10 MGMT, VLAN 20 PLATFORM, VLAN 30 ACCESS, VLAN 40 DMZ, VLAN 50 DATA)의 gateway 주소를 배정하고 Proxmox 관리 주소를 VLAN 10 인터페이스 (`vmbr0.10`)로 안전하게 이동시키는 검증된 절차를 제공한다.

검증일: 2026-07-31

## 2. 전제조건과 접근 권한

- OPNsense root 비밀번호 및 SSH/API 자격증명 (`infra/opnsense/.env`) 보유
- Proxmox root SSH 접근 및 물리 콘솔(PiKVM 등) 복구 경로 확보
- OPNsense OOB 콘솔 복구 경로 (`docs/runbook/opnsense-oob-console-recovery.md`)가 정상 생존함
- 전환 시작 전 백업을 저장소 밖 임시 디렉터리(`/home/imcherry/net02_backup/`)에 `0600` 권한으로 보관:
  - OPNsense `config.xml` 원본 백업
  - Proxmox `/etc/network/interfaces` 원본 사본
- Tailscale Subnet Router (`ds224p`, `10.10.60.2`)가 HOME 세그먼트(`igc3`, `10.10.60.0/24`)에 위치하여 OPNsense VLAN 10 라우팅 시 원격 관리 경로 생존 확인 완료

## 3. 예상 영향과 공유 잠금

- 공유 잠금 `PVE-LIVE` 및 `OPNSENSE-LIVE`를 동시에 단독 소유한다.
- OPNsense `lan` 인터페이스 재할당과 Proxmox `ifreload -a` 전환 순간 수 초간의 관리 통신 단절이 발생한다.
- WAN (`igc1`) 및 HOME (`igc3`, `10.10.60.0/24`)은 변경하지 않으므로 인터넷 접속 및 OOB 경로는 지속 생존한다.

## 4. 실행 순서와 중단 조건

### 4.1 OPNsense VLAN 생성
1. OPNsense REST API 또는 PHP CLI를 사용하여 `igc2` 부모 인터페이스 위에 VLAN 10, 20, 30, 40, 50을 정의한다:
   - VLAN 10 (`vlan01`): tag 10, descr `MGMT`
   - VLAN 20 (`vlan02`): tag 20, descr `PLATFORM`
   - VLAN 30 (`vlan03`): tag 30, descr `ACCESS`
   - VLAN 40 (`vlan04`): tag 40, descr `DMZ`
   - VLAN 50 (`vlan05`): tag 50, descr `DATA`

### 4.2 Proxmox 네트워크 설정 준비 (`interfaces.new`)
1. Proxmox에 `/etc/network/interfaces.new` 파일 작성:

```text
auto lo
iface lo inet loopback

iface nic0 inet manual

auto vmbr0
iface vmbr0 inet static
	bridge-ports nic0
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware yes
	bridge-vids 10 20 30 40 50

auto vmbr0.10
iface vmbr0.10 inet static
	address 10.10.10.10/24
	gateway 10.10.10.1

iface nic1 inet manual

source /etc/network/interfaces.d/*
```

### 4.3 동시 Cutover 실행
1. OPNsense에서 논리 인터페이스 `lan`의 할당 장치를 `igc2`에서 `vlan01` (VLAN 10 장치)로 재할당한다:
   - `$config['interfaces']['lan']['if'] = 'vlan01';`
   - `write_config();` 및 `interfaces_lan_configure();`
2. Proxmox에서 `cp /etc/network/interfaces.new /etc/network/interfaces && ifreload -a`를 실행하여 런타임에 VLAN-aware bridge 및 `vmbr0.10` 관리 IP 적용.
3. 부모 `igc2` 인터페이스에서 untagged IP 주소를 완전 제거한다:
   - `ifconfig igc2 inet 10.10.10.1 delete`

### 4.4 OPNsense 추가 VLAN 20/30/40/50 설정
1. OPNsense `opt2` ~ `opt5` 인터페이스를 추가하고 static IPv4 배정:
   - `opt2` (`vlan02`): descr `PLATFORM`, ipaddr `10.10.20.1/24`
   - `opt3` (`vlan03`): descr `ACCESS`, ipaddr `10.10.30.1/24`
   - `opt4` (`vlan04`): descr `DMZ`, ipaddr `10.10.40.1/24`
   - `opt5` (`vlan05`): descr `DATA`, ipaddr `10.10.50.1/24`
2. MVC Filter 및 방화벽 룰 재구성을 실행한다:
   - `filter_configure();`
   - `configctl filter reload`

중단 조건:
- OPNsense 또는 Proxmox 접근이 1분 이상 복구되지 않으면 추가 조작을 멈추고 콘솔(PiKVM)에서 즉시 복구 절차로 넘어간다.

## 5. 성공 판정

1. **VLAN Gateway 및 관리 접근**:
   - `10.10.10.1` (VLAN 10 gateway) 도달 가능.
   - Proxmox `https://proxmox-01.imcherry5778.xyz:8006/` strict TLS (PVE-ACME-01 공인 인증서, 검증 우회 없이) 정상 응답.
   - Proxmox SSH (`10.10.10.10:22`) 접속 정상.
   - OPNsense Unbound DNS canonical FQDN 해석 정상 (`opnsense.imcherry5778.xyz` -> `10.10.10.1`, `proxmox-01.imcherry5778.xyz` -> `10.10.10.10`).
   - OPNsense `vlan01`~`vlan05` 인터페이스 및 직접 연결 라우트 생성 완료.
2. **Untagged 차단**:
   - 부모 `igc2`에 IPv4 주소 및 논리 할당 없음 확인 (`igc2 clean, no IPv4.`).
   - Proxmox `vmbr0` (untagged)에 임시 IP 부여 시 `10.10.10.1` 통신 100% loss (L2 미전달 관측).
   - 대조군 tagged `vmbr0.10` 통신 0% loss (정상 도달).
   - 임시 인터페이스 완벽 삭제 및 제거 재확인 (`Clean`).
3. **재부팅 검증**:
   - OPNsense 재부팅 (`configctl system reboot`) 후 1항 항목 재검증 통과.
   - Proxmox VE 재부팅 (`systemctl reboot`) 후 1항 항목 재검증 통과.
4. **Drift 없음**:
   - `infra/opnsense/scripts/check-drift.sh --update` 승인 및 `check-drift.sh` 무변경 (`드리프트 없음 ✓`, exit code 0) 확인.

## 6. 실패 시 원상복구

1. **OPNsense 복구**:
   - OOB 콘솔 로그인 (`root`) -> `1) Assign interfaces`에서 `lan`을 `igc2`로 원복.
   - 콘솔 `2) Set interface IP address`에서 `lan` 주소 `10.10.10.1/24` 복구.
   - 콘솔 `13) Restore a backup`에서 작업 전 원본 백업(`/home/imcherry/net02_backup/opnsense_config.xml.bak`) 복원.
2. **Proxmox 복구**:
   - 물리 콘솔(PiKVM) 로그인 -> `/home/imcherry/net02_backup/proxmox_interfaces.bak`을 `/etc/network/interfaces`로 복원.
   - `ifreload -a` 또는 `systemctl restart networking` 실행.
   - **power off를 절대 수행하지 않는다.**

## 7. 시크릿과 보존하면 안 되는 출력

- OPNsense 원본 백업(`opnsense_config.xml.bak`), root 비밀번호, API Key/Secret, OOB 자격증명은 저장소 밖 `/home/imcherry/net02_backup/` (`0600` 권한)에 보관하며 작업 완료 후 안전하게 폐기한다.
- SSH 호스트키 지문 및 WAN 공인 주소는 공유/커밋 시 마스킹 처리한다.
