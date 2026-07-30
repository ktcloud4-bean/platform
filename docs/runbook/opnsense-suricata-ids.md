# OPNsense Suricata alert-only IDS

- 검증일: 2026-07-31
- 작업: `NIDS-01`
- 상태: 적용·재부팅·DMZ 런타임 및 경보 검증 완료

## 목적과 경계

이 절차는 OPNsense에 Suricata PCAP alert-only IDS 기준선을 구성하고 DMZ(`vlan04` / VLAN 40) 논리 프로젝트 VLAN을 관찰 대상으로 지정한다.

다음은 이 절차의 범위가 아니다:

- IPS 모드, drop 동작, Netmap 인라인 구성 활성화 (`NIPS-01` 범위)
- 방화벽 rule·alias·NAT·DHCP·DNS·interface·gateway 변경 (`NET-03`/`NET-04` 범위)
- 부모 인터페이스 `igc2` 또는 WAN `igc1`을 IDS 대상으로 선택하는 구성
- Proxmox·VM·OpenTofu state 변경
- Wazuh·Loki·syslog 원격 전송 구성 (`AUDIT-01`·`WAZUH-01` 범위)

## 검증된 라이브 상태

| 항목 | 2026-07-31 확인 결과 |
|---|---|
| OPNsense | 26.7.1_1 (amd64), FreeBSD 15.1-RELEASE-p1 |
| Suricata 패키지 | `suricata-8.0.6`, HYPERSCAN=on, NETMAP=on |
| 관찰 대상 인터페이스 | DMZ (`opt4` / `vlan04` / VLAN 40), PLATFORM (`opt2` / `vlan02` / VLAN 20) |
| 제외 인터페이스 | `igc2` (부모 trunk), `igc1` (WAN), `vlan01`, `vlan03`, `vlan05` |
| 작동 모드 | PCAP alert-only (IDS live mode), drop 없음, payload 저장 비활성화 |
| HOME_NET 정의 | `10.10.10.0/24,10.10.20.0/24,10.10.30.0/24,10.10.40.0/24,10.10.50.0/24` (프로젝트 VLAN만 지정) |
| 활성화 룰셋 | `opnsense.test.rules`, `emerging-scan.rules`, 사용자 정의 테스트 룰 |
| 영속성 | OPNsense 정상 재부팅 후 서비스 자동 기동, `vlan04` 바인딩, `check-drift.sh` 드리프트 없음 |

## 1차 적용 및 확장 규칙

- **1차 적용 (DMZ vlan04)**: `netbird-01`이 있는 DMZ VLAN에서만 먼저 활성화하고 통신과 경보 탐지를 검증했다.
- **PLATFORM (vlan02) 보류**: `K3S-01` 작업이 완료되었음을 명시적으로 확인하기 전에는 netmap/pcap 인터페이스 조작으로 인한 통신 영향을 방지하기 위해 켜지 않는다.
- **ACCESS / DATA / MGMT 확대 조건**: CPU 및 메모리, 경보 부하를 판정한 후 단계별로 명시적 승인을 거쳐 확대한다.

## 백업 및 롤백

- 백업 사본: `/tmp/nids-01-backup-YVGY82` (mode 0700)
- OPNsense raw config SHA-256: `64d419f230128a286a30ee9f82f401fe41edd0a7542c1a98cdde099add5db70b`
- 1차 Rollback: API/UI로 Suricata disable (`ids.general.enabled=0`) 및 서비스 정지
- 2차 Rollback: PiKVM/OOB에서 작업 직전 revision (`config-1785436080.993.xml`) 복원
