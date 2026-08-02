# OPNsense VLAN bootstrap 방화벽

- 검증일: 2026-07-31
- 작업: `NET-03`
- 상태: 적용·재부팅·실제 VLAN source 검증 완료

> 현재 상태(2026-08-03): 이 문서의 rule 16개와 alias 2개는 `NET-04`에서 제거하고
> 실제 배포 host·서비스 기준의 최종 경계로 교체했다. 라이브 통신표와 rollback은
> [`opnsense-vlan-firewall-hardening.md`](opnsense-vlan-firewall-hardening.md)가 소유하며,
> 이 문서는 bootstrap 당시의 역사 증거로만 보존한다.

## 목적과 경계

이 절차는 `docs/ip-plan.md`의 VLAN 20~50에 임시 IPv4 bootstrap 경계를 만든다. 각 VLAN은 자기 OPNsense gateway의 DNS·NTP와 공개 Web 용도의 RFC1918 외 TCP 80/443만 새로 시작할 수 있다. RFC1918 내부 목적지는 Web 허용보다 먼저 차단·기록하고, 나머지는 PF implicit deny에 맡긴다.

다음은 이 절차의 범위가 아니다.

- 기존 LAN/HOME 규칙 축소·삭제·재배열
- DHCP, interface·gateway, DNS record, outbound NAT mode 변경
- 서비스별 포트, 공개 DNS/NAT, VPN, Suricata/IPS
- Proxmox 영속 network 또는 OpenTofu state 변경
- IPv6 broad allow

이 정책은 `NET-04`에서 실제 서비스 통신표로 교체·최소화한다. RFC1918 외 특수용 IPv4 대역을 모두 차단하는 최종 egress 정책은 아니므로 공개 TCP 80/443의 목적지 범위는 후속 작업에서 다시 검토한다.

## 검증된 라이브 상태

| 항목 | 2026-07-31 확인 결과 |
|---|---|
| OPNsense | 26.7.1_1, PF enabled |
| trunk | VLAN 10~50 tagged-only, 부모 `igc2` 무주소 |
| project IPv6 | routed prefix·RA·gateway 없음 |
| DNS/NTP | Unbound TCP/UDP 53, ntpd UDP 123이 project gateway에서 응답 |
| 관리면 | OPNsense SSH·Web GUI와 Proxmox SSH·8006은 MGMT 주소에서 동작 |
| NAT | automatic outbound NAT가 VLAN 20~50 source 처리 |
| 기존 사용자 규칙 | LAN IPv4/IPv6 allow와 HOME IPv4 allow; 의미값·순서 불변 |
| 신규 객체 | alias 2개, 저장 rule 16개, PF 확장 rule 24개 |
| 영속성 | OPNsense 재부팅 후 저장값·PF·서비스·실제 VLAN 검증 동일 |

주소는 이 문서에 복제하지 않고 [`docs/ip-plan.md`](../ip-plan.md)를 참조한다.

## 정책 표

### alias

| 이름 | 형식 | 내용 | 만료 조건 |
|---|---|---|---|
| `NET03_PRIVATE_V4` | network | `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` | `NET-04` 실제 통신표 정책으로 교체 |
| `NET03_BOOTSTRAP_WEB_PORTS` | port | 80, 443 | `NET-04` 실제 통신표 정책으로 교체 |

### interface별 rule

| VLAN/interface | DNS sequence | NTP sequence | RFC1918 BLOCK sequence | Web sequence |
|---|---:|---:|---:|---:|
| PLATFORM/`opt2` | 1000 | 1010 | 1020 | 1030 |
| ACCESS/`opt3` | 1100 | 1110 | 1120 | 1130 |
| DMZ/`opt4` | 1200 | 1210 | 1220 | 1230 |
| DATA/`opt5` | 1300 | 1310 | 1320 | 1330 |

각 interface의 필드는 다음과 같다.

1. `<VLAN net> → <해당 gateway>` TCP/UDP 53 PASS, state keep
2. `<VLAN net> → <해당 gateway>` UDP 123 PASS, state keep
3. `<VLAN net> → NET03_PRIVATE_V4` BLOCK, log
4. `<VLAN net> → any` TCP `NET03_BOOTSTRAP_WEB_PORTS` PASS, state keep
5. 나머지 신규 연결은 implicit BLOCK

모든 rule은 IPv4(`inet`), inbound, quick이다. description에는 `NET-03`, 임시 bootstrap 목적과 `NET-04` 교체 조건을 남긴다.

## 전제와 중단 조건

1. `docs/backlog.md`에서 선행 완료와 `OPNSENSE-LIVE` 잠금을 확인한다.
2. Git 작업 트리와 main HEAD를 확인하고 작업 ID 전용 branch를 사용한다.
3. OPNsense·Proxmox strict SSH/HTTPS와 PiKVM의 현재 로그인 prompt·입력 경로를 확인한다.
4. 일반 drift가 없어야 한다.
5. 저장 설정과 런타임에서 VLAN interface·route, 부모 무주소, PF, DNS/NTP listen과 automatic NAT를 다시 확인한다.
6. 설치본의 Firewall/Alias MVC controller와 model schema를 읽어 endpoint와 field를 확인한다.

다음이면 쓰기 전에 중단한다.

- 다른 세션이 같은 라이브 잠금을 사용함
- 문서와 라이브의 interface·rule·NAT 의미값이 다름
- project routed IPv6, RA 또는 IPv6 gateway가 발견됨
- automatic NAT가 project source를 처리하지 않음
- PiKVM 복구 경로가 동작하지 않음
- 기존 alias 이름이나 sequence 충돌이 있음

## backup과 rollback 준비

저장소 밖에 `mktemp -d`로 작업 전용 디렉터리를 만들고 mode 0700으로 둔다. 작업 직전 원본 OPNsense config와 Proxmox network 대조 사본은 mode 0600으로 저장하고 내용은 출력하지 않는다. SHA-256, OPNsense `/conf/backup`의 작업 직전 revision, 신규 객체 UUID와 계획 JSON만 작업 기록에 남긴다.

Firewall API에 자동 savepoint rollback이 있다고 가정하지 않는다.

1차 rollback은 기록한 rule UUID만 일괄 disable하고 filter를 적용한 뒤, rule을 역순 삭제한다. alias는 다른 rule이 참조하지 않을 때만 삭제하고 alias를 재구성한다. 관리 경로가 예상과 다르게 끊기면 같은 요청을 반복하지 않는다.

2차 rollback은 PiKVM에서 작업 직전 revision을 복원하는 것이다. 원본 `config.xml`이나 `/tmp/rules.debug`는 apply 입력으로 사용하지 않는다.

## 설치본에서 확인한 API 순서

OPNsense 26.7.1_1 설치본에서 add·toggle·delete는 각각 설정을 즉시 저장하고 revision을 만든다. `alias/reconfigure`와 `filter/apply`는 별도 PF reload다. 자동 transaction은 없다.

정상 적용 순서는 다음과 같다.

1. `POST /api/firewall/alias/add_item` 2회
2. `GET /api/firewall/alias/get_item/{uuid}` 2회로 저장 의미값 대조
3. `POST /api/firewall/alias/reconfigure` 1회
4. `POST /api/firewall/filter/add_rule` 16회, 모두 disabled로 stage
5. `GET /api/firewall/filter/get_rule/{uuid}` 16회와 전체 search로 필드·기존 규칙 불변 대조
6. `POST /api/firewall/filter/toggle_rule/{uuid,...}/1` 1회
7. 모든 저장 규칙을 다시 대조
8. `POST /api/firewall/filter/apply` 1회
9. PF 문법, 생성 순서, 런타임 rule·counter 확인

저장 필드가 계획과 다르면 `set_rule`로 즉석 수정하지 않고 신규 UUID만 rollback한다. API HTTP 성공만으로 완료하지 않는다. API 자격증명은 command argument나 environment 상속 대신 mode 0600 임시 curl config로 전달하고 TLS 검증을 끄지 않는다.

## 실제 VLAN 검증

Proxmox 영속 설정은 수정하지 않는다. `.200-.254` 실험 범위에서 충돌이 없는 주소를 확인한 뒤 VLAN 10 MGMT 대조군과 VLAN 20·30·40·50 client용 임시 namespace/veth를 만든다. host veth는 `vmbr0`에 연결하고 해당 VLAN 하나만 PVID/untagged membership으로 둔다.

project client에는 TCP echo listener를 두고 MGMT에서 같은 destination/port가 열려 있음을 먼저 증명한다. `vlan-verify run --profile bootstrap`의 BLOCK은 900초 이내의 다른 source `ALLOW PASS` control과 정확히 같은 layer·protocol·destination·port를 참조해야 한다.

각 project VLAN에서 확인할 항목은 다음과 같다.

- ALLOW: 실제 source/interface route, gateway UDP DNS, TCP DNS 연결과 실제 DNS/TCP 응답, gateway NTP, 공개 TCP 80/443, strict TLS, HTTPS 성공
- BLOCK: OPNsense MGMT 22/443, Proxmox MGMT 22/8006, HOME gateway NTP, 대표 다른 project VLAN listener
- stateful: MGMT에서 각 project listener로 시작한 payload와 응답 일치

timeout이나 connection refused만으로 BLOCK을 확정하지 않는다. 같은 VLAN 통신은 OPNsense 차단 증거로 부르지 않는다.

검증이 끝나면 자신이 기록한 listener PID만 종료하고 자신이 만든 namespace/veth만 제거한다. 이름이 이미 있던 자원은 삭제하지 않는다. 전후 `/etc/network/interfaces` SHA-256이 같고 임시 자원이 모두 없어야 한다.

## 재부팅과 drift

첫 검증이 모두 통과하고 PiKVM 복구 화면이 살아 있을 때만 OPNsense를 정상 재부팅한다. Proxmox는 재부팅하지 않는다. 60초 안에 원격 복귀를 확인하지 못하면 추가 조작과 재부팅을 멈추고 PiKVM 화면을 확인한다.

새 boot time을 확인한 뒤 저장 rule·alias, PF 런타임, DNS/NTP, NAT, SSH/TLS와 네 VLAN의 전체 bootstrap plan을 다시 실행한다. 부팅 직후 ntpd가 `stratum=0`이면 성공으로 승격하지 않는다. upstream peer가 선택된 뒤 새 control evidence와 project 검증을 만든다.

마지막에는 일반 drift로 차이를 확인한다. 정규화 diff가 신규 alias/rule과 필수 저장 메타데이터 외 내용을 포함하면 `--update`하지 않는다. 의도한 차이만 승인한 뒤 일반 검사에서 `드리프트 없음`을 확인한다.

## 2026-07-31 검증 기록

- 적용 직후와 재부팅 후 각각 MGMT ALLOW control 16개가 PASS했다.
- VLAN 20·30·40·50은 각 실행에서 19/19 PASS했다. VLAN별 6개 BLOCK 모두 최신 control과 일치했다.
- MGMT에서 네 project listener로 시작한 TCP payload와 stateful 응답이 적용 직후·재부팅 후 각각 4/4 일치했다.
- 별도 DNS/TCP protocol probe가 네 gateway에서 유효한 A 응답을 반환했다.
- 저장 rule 16개가 PF에서 24개로 정확히 확장됐고 검증 후 24개 모두 packet counter가 증가했다.
- 기존 LAN/HOME 규칙, automatic NAT, interface·route, DHCP와 관리 listen 의미값은 변하지 않았다.
- OPNsense 재부팅 시 strict SSH의 60초 내 복귀는 확인하지 못해 추가 조작을 중단했다. PiKVM에서 정상 부팅을 확인한 뒤 새 boot time과 strict SSH/TLS를 확인하고 전체 검증을 재개했다.
- 부팅 직후 첫 HOME NTP control은 upstream 미선택 상태의 `stratum=0`이라 `INCONCLUSIVE`로 보존했다. 동기화 후 새 control과 전체 VLAN 검증은 PASS했다.
- 임시 namespace·veth·listener를 제거했고 Proxmox 영속 network hash가 유지됐다.
- 재부팅 후 OPNsense drift가 없음을 확인했다.

## 시크릿과 증거 보존

API key/secret, private key, 원본 config, 공인 WAN 주소와 인증서·SSH fingerprint를 Git·명령 인자·일반 로그·완료 보고에 남기지 않는다. 원본 backup과 UUID 기록은 저장소 밖 mode 0700 디렉터리에 보존한다. Git에는 정규화·마스킹된 `infra/opnsense/config.xml`만 둔다.
