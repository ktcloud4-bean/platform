# OPNsense 운영

OPNsense는 경계 방화벽, VLAN router, NAT, 랩 DNS와 네트워크 IDS를 담당한다. 정확한 인터페이스와 주소는 `docs/ip-plan.md`를 참조한다.

## Git 경계

`config.xml`은 **마스킹한 드리프트 스냅샷**이며 적용 파일이 아니다.

```text
사람이 UI 또는 승인된 API로 라이브 변경
              ↓
서비스·route·PF·DNS를 라이브 검증
              ↓
check-drift.sh --update로 스냅샷 승인
              ↓
일반 check-drift.sh로 무변경 확인
```

- `--update`는 라이브 장비를 바꾸지 않고 저장소 스냅샷만 갱신한다.
- `config.xml`을 편집해도 OPNsense에 반영되지 않는다.
- `/usr/local/etc` 같은 생성 파일을 직접 고치면 서비스 재구성 때 사라진다.
- 베어메탈 드리프트는 자동 교정하지 않는다.

## 현재 스냅샷

2026-07-29 커밋 기준으로 다음이 기록돼 있다. 변경 전에는 라이브 드리프트를 다시 확인한다.

| 영역 | 기록된 상태 |
|---|---|
| WAN | ISP DHCP, private·bogon 차단 |
| LAN/HOME | 물리 재배치 완료; 주소는 IP 계획 참조 |
| VLAN | 아직 없음; Phase 1 untagged LAN |
| Web GUI | HTTPS, LAN listen, Local+TOTP |
| SSH | LAN listen, 공개키 관리 |
| DNS | Unbound recursion, DNSSEC, forwarding 비활성 |
| DHCP | Dnsmasq; 로컬 domain record를 Unbound와 연계 |
| ACME | Cloudflare DNS-01 wildcard, 자동갱신 cron |
| NAT | automatic outbound NAT |
| IDS | Suricata 비활성; PCAP alert-only 목표는 `NIDS-01` |

현재 Phase 1 방화벽 규칙은 최종 VLAN 정책이 아니다. 목표 행렬과 전환 gate는 `docs/ip-plan.md`와 `docs/backlog.md`가 소유한다.

## IDS 경계

Suricata는 VLAN과 테스트 VM이 준비된 `NIDS-01`에서 처음 활성화한다. 이 작업은 탐지만 소유하며 방화벽 차단 정책을 함께 바꾸지 않는다.

- 기본 모드는 PCAP alert-only다.
- WAN이 아니라 실제 내부 자산을 식별할 수 있는 논리 프로젝트 VLAN을 주 관찰 지점으로 쓴다.
- `PLATFORM`과 `DMZ`부터 시작해 부하와 중복 경보를 확인한 뒤 `ACCESS`, `DATA`, `MGMT`로 넓힌다.
- `HOME_NET`은 `docs/ip-plan.md`의 프로젝트 VLAN만 참조하고 HOME은 포함하지 않는다.
- 물리 trunk 부모와 그 VLAN 자식을 동시에 IDS 대상으로 선택하지 않는다.
- payload 원문 저장은 기본 비활성으로 두고, 로컬 경보는 용량이 제한된 rotation을 유지한다.
- Wazuh 도입 후에는 OPNsense Wazuh Agent가 IDS 이벤트를 Wazuh에 직접 전달한다. Loki를 중계 경로로 쓰지 않는다.

IPS는 기준선이 아니다. `NIPS-01`이 채택될 때만 정상 트래픽·오탐·처리량·Netmap 부모 인터페이스·hardware offloading·장애와 rollback을 별도로 검증한다. IDS/Wazuh 장애가 PF, DNS, 라우팅이나 로컬 복구를 중단시키면 안 된다.

## 파일

| 경로 | 역할 |
|---|---|
| `config.xml` | 승인된 마스킹 스냅샷 |
| `scripts/normalize.py` | 시크릿·변동 노이즈 제거 |
| `scripts/check-drift.sh` | 라이브 다운로드·정규화·diff |
| `tests/test_normalize.py` | 마스킹 회귀 테스트 |

원본은 `config.raw.xml`처럼 `.gitignore`가 차단하는 이름으로만 저장하고 작업 후 안전하게 폐기한다.

## 사용

저장소 루트에서 실행한다.

```sh
python3 -m unittest discover -s infra/opnsense/tests -v

export OPN_KEY='...'
export OPN_SECRET='...'
infra/opnsense/scripts/check-drift.sh

# 라이브 차이가 정당하고 런타임 검증까지 끝난 경우만
infra/opnsense/scripts/check-drift.sh --update
infra/opnsense/scripts/check-drift.sh
```

환경변수 값, 다운로드한 원본 XML과 diff의 시크릿을 셸 기록·CI log·Git에 남기지 않는다.

## 변경 절차

1. `docs/backlog.md`에서 선행 작업과 `OPNSENSE-LIVE` 잠금을 확인한다.
2. 일반 drift check로 시작 상태를 확인한다.
3. UI 또는 공식 API에서 최소 변경만 stage한다.
4. 적용 전 독립 복구 경로와 rollback 값을 확인한다.
5. 라이브 API 응답만 보지 말고 interface, route, PF, DNS와 실제 client 요청을 검증한다.
6. 정당한 최종 상태만 `--update`하고 테스트를 실행한다.

API 요청 timeout은 성공이나 실패의 증거가 아니다. 인터페이스 전환으로 관리 경로가 끊긴 것일 수 있으므로 OOB에서 라이브 상태를 판정한다.

## DNS 경계

- Unbound는 재귀 해석기이며 외부 forwarding을 사용하지 않는다.
- Dnsmasq는 DHCP와 동적 로컬 이름을 담당하고 별도 포트에서 Unbound와 연결된다.
- Kubernetes CoreDNS는 Pod·Service 이름만 담당한다. 랩 DNS를 k3s로 옮기지 않는다.
- 내부 zone과 같은 공인 이름은 split DNS override를 명시적으로 관리한다.
- OPNsense wildcard 인증서 개인키를 다른 계층에 배포하지 않는다.

## 패키지와 사용자

- 기능은 OPNsense plugin으로만 설치한다. 셸의 임의 `pkg install`은 펌웨어 수명주기에서 유실된다.
- SSH 공개키는 GUI 사용자 설정에 넣는다. 파일시스템의 `authorized_keys` 직접 편집은 덮어써질 수 있다.
- 원본 backup에는 사용자 해시, TOTP, API key, DNS token과 TLS private key가 포함된다고 가정한다.

## 복구 독립성

다음 연동은 하지 않는다.

- Keycloak을 OPNsense의 유일한 인증으로 사용
- Warpgate를 OPNsense의 유일한 관리 경로로 사용
- OPNsense에 NetBird 같은 overlay agent 설치
- 원격 세션만 가진 상태에서 관리 IP·물리 할당·기본 방화벽 변경

OPNsense, Keycloak과 overlay가 동시에 중단돼도 PiKVM/콘솔과 로컬 관리자로 복구할 수 있어야 한다.
