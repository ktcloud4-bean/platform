# OPNsense 운영

OPNsense는 경계 방화벽, VLAN router, NAT, 랩 DNS와 네트워크 IDS를 담당한다. 정확한 인터페이스와 주소는 `docs/ip-plan.md`를 참조한다.

## Git 경계

`config.xml`은 **마스킹한 드리프트 스냅샷**이며 적용 파일이 아니다.

```text
사람이 지원되는 UI/API·설정 라이브러리로 라이브 변경
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

2026-08-03 스냅샷과 라이브 저장 설정을 다시 대조해 다음을 확인했다. 변경 전에는 라이브 드리프트와 목표 적합성을 각각 확인한다.

| 영역 | 기록된 상태 |
|---|---|
| WAN | ISP DHCP, private·bogon 차단 |
| LAN/HOME | 물리 재배치 완료; 주소는 IP 계획 참조 |
| VLAN | LAN=`vlan01`, VLAN 20~50 논리 인터페이스·gateway 저장; 부모 `igc2`는 무주소 tagged-only trunk |
| 방화벽 | VLAN 20~50 최종 IPv4 최소 경계: 배포 host별 gateway DNS·NTP, exact cross-VLAN 서비스, EDGE-01 Warpgate→NetBird control, 비공개·특수용 IPv4 선차단·기록, public TCP 80/443, 나머지 implicit deny |
| Web GUI | HTTPS, LAN listen, Local+TOTP |
| SSH | LAN listen, 공개키 관리 |
| DNS | Unbound recursion, DNSSEC, exact split override; 공인 zone 전체 forwarding 비활성 |
| DHCP | Dnsmasq; 현재 동적·정적 hostname record 없음 |
| Metrics | `os-node_exporter`가 관리 주소에만 bind하고 CPU·meminfo·netdev를 노출; PLATFORM의 k3s-01 TCP 9100 exact PASS 한 건 |
| ACME | Cloudflare DNS-01 wildcard, 자동갱신 cron |
| NAT | automatic outbound NAT |
| IPsec | `AWS-NET-01` swanctl Connections 1개(IKEv2, policy-based, static). PSK는 스냅샷에서 제거된다 |
| IDS | Suricata DMZ (`vlan04`) 및 PLATFORM (`vlan02`) PCAP alert-only 활성화 (`NIDS-01`); `opnsense.test.rules`, `emerging-scan.rules` 및 custom rules 적용 |

2026-07-31 `NET-02R`에서 저장 설정과 재부팅 후 런타임을 대조해 VLAN 10~50 gateway·직접 연결 route, 부모 `igc2` 무주소, tagged 성공·untagged 차단, SSH·strict TLS·DNS·PF·Dnsmasq를 확인했다. `NET-03`의 bootstrap 경계는 2026-08-03 `NET-04`가 아래 최종 경계로 교체했다. 일반 drift 검사가 성공하는 것은 라이브 저장 설정과 마스킹 스냅샷이 같다는 뜻일 뿐이므로, 목표 적합성과 런타임 검증은 계속 별도로 수행한다.

## NET-04 VLAN 최소 경계

- VLAN network 전체가 아니라 현재 배포된 source host만 자기 gateway DNS·NTP를 쓴다.
- `k3s-01`의 PostgreSQL 5432·S3 8333, Warpgate의 Keycloak 443·관리 대상 SSH 22·
  PostgreSQL native relay 5432, NetBird의 Keycloak/control 443과 EDGE-01 Warpgate direct
  peer의 NetBird control 443만
  exact cross-VLAN PASS로 둔다.
- 비공개·특수용 IPv4를 public Web보다 먼저 차단·기록하고, 각 배포 host의 public TCP
  80/443만 허용한다. 나머지는 PF implicit deny다.
- DATA→AWS VPC 전체 프로토콜 임시 허용은 제거했다. 기존 IPsec과 selector는 유지하며
  현재 offsite 흐름은 public AWS API TCP 443을 쓴다.
- 기존 LAN/HOME, automatic NAT, interface·gateway, Suricata, 공개 경계와 IPv6는
  변경하지 않았다.

최종 통신표, rule·alias UUID와 sequence, 만료 객체, hardened 결과, rollback은
[`docs/runbook/opnsense-vlan-firewall-hardening.md`](../../docs/runbook/opnsense-vlan-firewall-hardening.md)가
소유한다. `NET-03` 절차는 bootstrap 당시의 역사 증거로만 보존한다.
EDGE-01이 추가한 Warpgate direct peer control rule과 rollback은
[`docs/runbook/netbird-public-edge.md`](../../docs/runbook/netbird-public-edge.md)가 소유한다.

## OPN-METRICS-01 최소 수집 경로

OPNsense 플러그인 `os-node_exporter`만 설치해 CPU·memory·interface collector를 활성화했다.
API credential이 추가로 필요한 외부 exporter는 사용하지 않는다. PLATFORM의 k3s-01에서
관리 주소 TCP 9100으로 향하는 `opt2` ingress exact PASS 한 건만 NET-04 비공개 목적지 BLOCK
앞에 두며, 다른 관리 UI·VLAN 경계는 열지 않는다. 선언·실측값·UUID 기반 rollback 절차는
[`gitops/apps/obs/README.md`](../../gitops/apps/obs/README.md)가 소유한다.

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
| `tests/test_check_drift.py` | env·TLS·비상 fallback 회귀 테스트 |

원본은 `config.raw.xml`처럼 `.gitignore`가 차단하는 이름으로만 저장하고 작업 후 안전하게 폐기한다.

## 사용

저장소 루트에서 실행한다.

```sh
python3 -m unittest discover -s infra/opnsense/tests -v

# 방법 1: 프로세스 환경변수
export OPN_KEY='...'
export OPN_SECRET='...'
infra/opnsense/scripts/check-drift.sh

# 방법 2: 저장소 밖 env 파일 (기본 경로)
install -d -m 700 "${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}/opnsense"
umask 077
cat >"${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}/opnsense/env" <<'EOF'
OPN_KEY=
OPN_SECRET=
EOF
# 값을 채운 뒤 실행한다. 경로 지정 없이 이 파일을 읽는다.
infra/opnsense/scripts/check-drift.sh

# 다른 경로를 쓰려면 명시한다. OPN_*가 아닌 값은 읽거나 자식 프로세스로 export하지 않는다.
infra/opnsense/scripts/check-drift.sh --env-file <저장소 밖 mode 0600 파일>

# 라이브 차이가 정당하고 런타임 검증까지 끝난 경우만
infra/opnsense/scripts/check-drift.sh --update
infra/opnsense/scripts/check-drift.sh
```

env 파일 기본 경로는 `$KTC_SECRET_ROOT/opnsense/env`다. `KTC_SECRET_ROOT`를 지정하지
않으면 `~/secrets/ktcloud4-bean`을 쓴다. 필요한 항목은 `OPN_KEY`와 `OPN_SECRET` 둘이며,
`OPN_URL`과 `OPN_CACERT`는 선택이라 기본 동작으로 충분하면 파일에 두지 않는다.

이미 export된 값이 env 파일보다 우선한다. env 파일은 셸로 `source`하지 않고
허용된 `OPN_*`만 파싱하며, 소유자는 현재 사용자이고 group/other 권한은 없어야
한다. 실제 값, 다운로드한 원본 XML과 diff의 시크릿을 셸 기록·CI log·Git에
남기지 않는다. API key/secret은 임시 mode `0600` curl 설정으로만 전달하고
명령 인자나 자식 프로세스 환경에 넣지 않는다.

## TLS와 비상 연결

기본 연결은 `docs/ip-plan.md`의 OPNsense canonical hostname과 시스템 trust
store로 인증서를 검증한다. 현재 공인 wildcard 인증서에는 `OPN_CACERT`가
필요하지 않다. 사설 CA로 바꾼 경우에만 읽을 수 있는 CA 파일을 지정한다.

DNS만 고장났다면 인증서 검증을 끄지 않는다. canonical hostname은 유지하고
현재 IP 계획에서 확인한 주소를 명시해 curl의 연결 대상만 바꾼다.

```sh
infra/opnsense/scripts/check-drift.sh --connect-ip '<현재 OPNsense IP>'
```

인증서 자체가 만료되거나 교체 중이라 엄격한 검증이 불가능한 비상 상황에서만
대상 URL과 `--insecure`를 함께 명시한다. 스크립트는 API 자격증명 노출 위험을
경고하며, 검증하지 않은 응답을 승인하지 못하도록 `--insecure --update`를
거부한다. 정상 운영 명령이나 `.env`에 insecure 모드를 저장하지 않는다.

```sh
OPN_URL='https://<현재 OPNsense IP>' \
  infra/opnsense/scripts/check-drift.sh --insecure
```

## OPN-DRIFT-01 검증 기록

검증일은 2026-07-30이다. 합성 자격증명과 가짜 curl을 사용한 회귀 테스트
15개로 env allowlist·권한·비밀 비상속, strict TLS, DNS 우회, insecure 경고와
`--insecure --update` 거부를 확인했다. `bash -n`, `shellcheck`와 전체
`unittest`가 통과했다.

라이브 장비에는 쓰기 요청을 하지 않았다. canonical hostname을 시스템 trust
store로 검증한 경로와 `ip-plan.md`의 현재 IP로 DNS만 우회한 경로에서 각각
설정을 내려받았고, 둘 다 승인된 `config.xml`과 드리프트가 없었다. 별도 HTTPS
검증도 HTTP `200`, 인증서 검증 결과 `0`, Let's Encrypt가 발급한 wildcard
인증서를 확인했다. insecure 경로는 실제 API 자격증명으로 실행하지 않고 합성
테스트로만 검증했다. 실제 env 파일과 자격증명은 Git 변경에 포함되지 않았다.

## 변경 절차

1. `docs/backlog.md`에서 선행 작업과 `OPNSENSE-LIVE` 잠금을 확인한다.
2. 일반 drift check로 저장 설정과 스냅샷의 일치 여부를 확인한다.
3. `docs/ip-plan.md`의 목표와 저장 설정·런타임 interface/route를 별도로 대조한다.
4. 지원되는 UI/API 또는 설치본의 설정 라이브러리에서 최소 변경만 stage한다. 설정 라이브러리를 쓸 때는 라이브 버전의 include·저장·reconfigure 경로를 먼저 확인한다.
5. 적용 전 독립 복구 경로와 rollback 값을 확인한다.
6. 라이브 API 응답만 보지 말고 저장 설정, interface, route, PF, DNS와 실제 client 요청을 검증한다.
7. 정당한 최종 상태만 `--update`하고 테스트를 실행한다.

API 요청 timeout은 성공이나 실패의 증거가 아니다. 인터페이스 전환으로 관리 경로가 끊긴 것일 수 있으므로 OOB에서 라이브 상태를 판정한다.

## DNS 경계

- Unbound는 재귀 해석기이며 외부 forwarding을 사용하지 않는다.
- Dnsmasq는 DHCP를 담당하고 별도 포트에서 실행한다. 공인 zone 전체를 Dnsmasq로
  forward하지 않는다.
- Kubernetes CoreDNS는 Pod·Service 이름만 담당한다. 랩 DNS를 k3s로 옮기지 않는다.
- 내부 zone과 같은 공인 이름은 split DNS override를 명시적으로 관리한다.
- OPNsense wildcard 인증서 개인키를 다른 계층에 배포하지 않는다.

2026-07-31 `INGRESS-01`에서 `imcherry5778.xyz` 전체를 Dnsmasq로 보내던 Unbound
query-forward row를 비활성화했다. Dnsmasq는 같은 이름을 local zone으로 취급하므로
미등록 공개 이름에 NXDOMAIN, apex SOA·NS에 빈 NODATA를 반환했고, 이는 DNS-01 zone
discovery를 막았다. Unbound의 `transparent` local zone과 exact host override는 유지해
등록된 내부 A/PTR·alias만 사설 주소로 응답하고, 나머지 SOA·NS·미등록 이름은 공개
권위 계층으로 재귀한다.

현재 Dnsmasq lease·host·static mapping이 모두 0개라 이 변경으로 사라지는 실제 동적
이름은 없다. 향후 DHCP lease hostname 조회가 필요하면 공인 apex를 다시 forward하지
말고 `docs/ip-plan.md`에서 별도 내부 DHCP subdomain을 먼저 확정한 뒤 그 subdomain만
연결한다. 임의 이름을 만들거나 공개 SOA·NS를 로컬에 복제하지 않는다. rollback은 기존
query-forward row를 다시 활성화하고 Unbound를 재구성하는 것이다.

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

이 경로의 검증된 절차, 성공 판정과 제약은 [`docs/runbook/opnsense-oob-console-recovery.md`](../../docs/runbook/opnsense-oob-console-recovery.md)가 소유한다. OOB 콘솔이 살아 있는 상태는 위 금지 항목의 "원격 세션만 가진 상태"에 해당하지 않는다. 다만 OOB가 랩 밖 네트워크 뒤에 있으면 그 경로가 끊기는 장애에서는 다시 현장 접근이 필요하다.
