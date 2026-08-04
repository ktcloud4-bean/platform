# NetBird 일반 사용자 device group·split DNS·exact ingress route

- 작업: `NB-ENROLL-01`
- 선행: `EDGE-02`, `IAM-01`, `NB-02`, `NET-04`, `POM-01`
- 결정 근거: [ADR-0018](../adr/0018-public-keycloak-frontchannel.md)
- 후속: `IAM-ENROLL-01`
- 현재 실행 상태: **완료, 라이브 적용됨** (2026-08-04)

## 목적과 경계

`EDGE-02`는 외부 신규 장치가 기존 Keycloak `/platform-users` 일상 ID로 NetBird OIDC
로그인을 시작할 수 있는 공개 인증면만 만들었다. `NB-ENROLL-01`은 그 로그인이 실제로
peer를 만든 뒤, `/platform-users` device group이 정확히 `access` Portal의 ingress
경로 하나(TCP 443)와 그 split DNS(TCP/UDP 53)에만 도달하고, 그 밖의 목적지·port와
미소속·특권 전용 ID는 거부되며, offboarding이 실제로 접근을 끊는다는 것을 증명한다.

```text
외부 신규 장치
  → NetBird 실제 OIDC 로그인 (PKCE, Keycloak /platform-users ID + MFA)
  → NetBird peer 등록, JWT groups propagation으로 /platform-users에 자동 배정
  → NetBird overlay
      ├─ split DNS: access.imcherry5778.xyz → netbird-01 dnsmasq → 내부 Unbound
      └─ exact route: k3s-01(10.10.20.10) TCP 443 (OPNsense가 routing peer)
  → Traefik → Pomerium → access Portal
```

## 설계 결정

### subnet route 대신 OPNsense를 NetBird routing peer로

Warpgate가 `EDGE-01`에서 자기 자신에 NetBird agent를 설치해 direct peer가 된 것과
같은 원칙(subnet route를 만들지 않는다)을 따르되, 목적지 호스트(k3s-01)에는 아무것도
설치하지 않는다. 대신 OPNsense 26.7이 25.7.3부터 제공하는 `os-netbird` 공식 플러그인을
설치해 OPNsense 자신을 NetBird의 **Network Router**로 등록한다. OPNsense는 이미 모든
VLAN의 유일한 L3/L4 방화벽이므로, "NetBird로 무엇에 닿을 수 있는가"도 OPNsense가 한
곳에서 통제하는 편이 architecture와 일치한다. k3s-01은 어떤 새 소프트웨어도 설치하지
않는다.

NetBird "Networks" 기능으로 정확히 두 개의 `host` Resource만 선언한다.

| Resource | 주소 | 용도 |
|---|---|---|
| `k3s-01 ingress` | `10.10.20.10/32` | `access` Portal이 붙는 Traefik ingress |
| `Unbound DNS` | `10.10.40.10/32` | netbird-01의 split DNS relay (아래 참고) |

Router는 OPNsense peer 하나(`nb-enroll-01-router` group), `masquerade: true`,
`metric: 9999`다. 각 Resource는 전용 group(`nb-enroll-01-ingress`,
`nb-enroll-01-dns`)에 속하고, 정책은 이 group들을 목적지로 참조한다.

### split DNS를 OPNsense 자신이 아니라 netbird-01에 둔 이유

최초 설계는 DNS 목적지를 OPNsense 자신의 Unbound(`10.10.20.1`)로 뒀다. 그러나 라이브
검증에서 **OPNsense가 routing peer이면서 동시에 목적지인 self-referencing 경로는
패킷을 전달하지 않는** FreeBSD/userspace WireGuard 한계를 재현했다.

- `pfctl -ss`: 해당 흐름의 state가 `SINGLE:NO_TRAFFIC`(질의만 도착, 응답 0)로 고정
- Unbound `logqueries`/`logreplies`를 켜고 확인해도 해당 source의 질의가 로그에
  전혀 나타나지 않음(커널이 로컬 소켓까지 전달하지 않음)
- `masquerade: true/false` 전환, `opt6ip` 매크로 대신 리터럴 overlay IP 사용,
  Unbound 완전 재시작까지 시도했지만 동일하게 실패
- 반면 **다른 호스트**(k3s-01, TCP 443)로의 라우팅은 masquerade 설정과 무관하게
  항상 정상 동작했다 — self-referencing 조합에서만 재현되는 결함이다

이 결함은 OPNsense·NetBird 플러그인 조합의 커널 레벨 한계로 판단해 이번 작업
범위에서 고치지 않는다. 대신 DNS 응답 지점을 **다른 호스트인 netbird-01**로 옮겨
k3s-01과 동일한 "라우팅 peer가 아닌 다른 호스트로의 exact route" 패턴을 재사용한다.
netbird-01에 최소 `dnsmasq`(Rocky 9 공식 패키지)를 systemd 서비스로 추가해
`imcherry5778.xyz` 질의만 netbird-01의 기존 DMZ gateway(`10.10.40.1`, 이미
허용된 경로)로 조건부 forward한다. k3s-01 자체는 변경하지 않는다.

### NetBird API의 policy 다중 rule 결함

`POST /api/policies`에 rule 여러 개를 한 번에 보내면 이 NetBird 버전은 **첫 rule만
실제로 저장**한다(두 번째 rule 이후 응답에는 `sources`가 `null`로 드롭됨, GET으로
재조회하면 rule이 1개만 남음). `EDGE-01`의 기존 policy들도 모두 rule 1개였던 것과
같은 제약으로 판단해, policy 1개당 rule 1개로 우회한다. `netbird-access-ingress.py`는
이 제약을 반영해 policy 3개(TCP 443, DNS UDP 53, DNS TCP 53)를 각각 만든다.

## 라이브 선언 객체

### OPNsense

| 계층 | 객체 | 값 |
|---|---|---|
| Firmware | `os-netbird-1.3_3`, `netbird-0.74.4` 패키지 | 설치 |
| Interfaces 배정 | `opt6` (NETBIRD) | `if=wt0`, `enable=1`, `ipaddr=none`(NetBird 자체 관리) |
| VPN > NetBird > Settings | firewall.blockInboundConnection=1, routing.accessLan=1, routing.acceptServerRoutes=1, routing.acceptClientRoutes=0, dns.enable=0, ssh.*=0 | client 자체 방화벽은 유지(라우팅·DNS 정상 동작에 필요), OPNsense 자신은 NetBird DNS·SSH를 쓰지 않음 |
| VPN > NetBird > Authentication | managementUrl, one-off setup key(사람용 아님, 이미 소모됨) | headless routing peer 등록 |
| Firewall > Rules (opt6) | 2개, `quick`, `log` | `TCP 443 → 10.10.20.10`, `TCP/UDP 53 → 10.10.40.10`; 그 외 전부 기본 차단 |
| Unbound > ACL | `nb-enroll-01-netbird-overlay` | `allow 100.72.0.0/16`(NetBird overlay 대역만) — netbird-01 dnsmasq가 Unbound에 forward할 때 필요 |

### NetBird (Owner API, `infra/ansible/tools/nb-enroll-01/netbird-access-ingress.py`)

| 객체 | 이름 | 내용 |
|---|---|---|
| Group | `/platform-users` | 기존 JWT-issued group 재사용(새로 만들지 않음) — device group |
| Group | `nb-enroll-01-router` | OPNsense peer 1개 |
| Group | `nb-enroll-01-ingress` | k3s-01 ingress Resource 1개 |
| Group | `nb-enroll-01-dns` | Unbound DNS Resource 1개(주소는 netbird-01) |
| Network | `NB-ENROLL-01 access ingress` | Resource 2개 + Router 1개 |
| Policy | `NB-ENROLL-01 TCP 443` | `/platform-users` → `nb-enroll-01-ingress`, TCP 443, 단방향 |
| Policy | `NB-ENROLL-01 DNS UDP 53` | `/platform-users` → `nb-enroll-01-dns`, UDP 53, 단방향 |
| Policy | `NB-ENROLL-01 DNS TCP 53` | `/platform-users` → `nb-enroll-01-dns`, TCP 53, 단방향 |
| DNS Nameserver Group | `NB-ENROLL-01 access split DNS` | domain=`imcherry5778.xyz`(전체 zone, `NB-ENROLL-01-FIX-01`에서 확장), nameserver=`10.10.40.10:53/udp`, groups=`/platform-users`, primary=false |

### `NB-ENROLL-01-FIX-01`: DNS Nameserver Group 범위가 `access` 하나뿐이던 결함

최초 적용은 `domain=access.imcherry5778.xyz` 하나만 등록했다. 그런데 Pomerium은 보호
Route 전부(`access` 포함)의 로그인 리다이렉트를 `authenticate_service_url:
https://k3s-01.imcherry5778.xyz` 하나로 통일해서 쓴다(`gitops/apps/pomerium/pomerium-conf.yaml`).
이 이름이 이 Nameserver Group의 domain 범위 밖이라 NetBird 전용 client(Tailscale 등
다른 경로 없이)는 `access`에는 도달해도 로그인 리다이렉트 단계에서 전부 막혔다. `access`
403 curl 검증만으로는 이 결함이 드러나지 않고, 실제 브라우저로 로그인 리다이렉트 전체를
타야 재현됐다.

`netbird-01`의 `dnsmasq` relay는 애초에 `imcherry5778.xyz` 전체 zone을 조건부 forward하도록
구성되어 있어(`server=/imcherry5778.xyz/10.10.40.1`), 고치는 데 새 인프라가 필요 없었다.
Nameserver Group의 domain 값을 `access.imcherry5778.xyz`에서 `imcherry5778.xyz`로 넓히는
한 필드 변경만으로 충분했다. exact route(Resource 2개)·정책 3개·group은 그대로다.

라이브 검증(2026-08-05, Tailscale 완전 비활성 상태의 NetBird 전용 client에서): 수정 전
`k3s-01`·`sso`·`shuffle`·`headlamp` 등은 미해석, 수정 후 전부 `10.10.20.10`으로 해석.
`curl -L https://access.imcherry5778.xyz/`의 전체 redirect chain(`access` → `k3s-01`
`.pomerium/sign_in` → `sso` Keycloak `/realms/platform/.../auth` → `200`)이 Tailscale 없이
NetBird만으로 끝까지 통과했다.

`Default`(All↔All) 정책은 `EDGE-01`에서 이미 비활성화된 상태를 그대로 유지한다. 이번
작업은 그 정책을 건드리지 않았다.

### netbird-01

| 파일 | 내용 |
|---|---|
| `/etc/dnsmasq.d/nb-enroll-01.conf` | `no-resolv`, `server=/imcherry5778.xyz/10.10.40.1` 조건부 forward만; 다른 도메인은 upstream이 없어 응답하지 않음 |
| `dnsmasq.service` | enabled, active |

netbird-01의 기존 NetBird control/relay/management 컨테이너·Traefik·인증서는 이번
작업에서 변경하지 않았다.

## 완료 증거

백로그 원문: "랩 밖 신규 client가 `/platform-users` ID·MFA로 사용자 소유 peer를
만들고 내부 DNS와 ingress HTTPS exact route로 `access`에 도달, 미소속·특권 전용 ID와
허용 밖 목적지·port 거부, 사람용 setup key 0건, session revoke·사용자 차단·peer 삭제
뒤 재접근 거부와 임시 자원 0건."

| 증거 | 검증 방법과 결과 |
|---|---|
| 사용자 소유 peer 생성 | 격리된 Docker container(호스트의 wlo1/실제 인터넷 경유, `--dns 1.1.1.1`; NetBird·Tailscale 인터페이스 미포함)에서 pinned `netbird` v0.73.0(서버와 동일 버전) 실행. `netbird login --no-browser`는 headless 환경에서 기본적으로 Device Authorization Grant를 시도해 사전 존재 결함(아래 참고)에 걸리므로, 실제 데스크톱 사용자를 재현하기 위해 `XDG_CURRENT_DESKTOP` 설정으로 PKCE flow를 강제했다. 출력된 실제 authorization URL을 Cloudflare edge(`104.21.83.164`)로 GET하고 `/platform-users` 일상 ID `imcherry5778`의 비밀번호+TOTP로 로그인 폼·MFA를 완료해, netbird 데몬이 자신의 localhost:53000 콜백에서 code를 받아 실제 peer를 등록했다(`netbird status`: `Management: Connected`, `Peers count: 1/1 Connected`). |
| 내부 DNS로 `access` 도달 | 등록된 peer에서 `getent hosts access.imcherry5778.xyz` → `10.10.20.10`(split DNS 정상), `curl https://access.imcherry5778.xyz/` → `HTTP 302`(Pomerium이 Keycloak 로그인으로 리다이렉트하는 정상 미인증 응답) |
| 미소속 ID 거부 | `headlamp-no-group`(그룹 없음) 계정으로 Keycloak 로그인은 성공하지만 그 access token으로 NetBird API 호출 시 `401 token invalid` |
| 특권 전용 ID 거부 | `imcherry-admin`(`/platform-privileged`만 보유) 계정도 동일하게 Keycloak 로그인은 성공하지만 NetBird `401 token invalid` |
| 허용 밖 목적지 거부 | 같은 peer에서 NetBird가 광고하지 않는 `postgres-01:5432`, `object-01:8333`은 라우팅 자체가 없어 즉시 `No route to host` |
| 허용 밖 port 거부 | 같은 목적지 k3s-01의 `22`, `6443`(라우팅은 있지만 PF가 443만 허용)은 timeout(silent drop) |
| 사람용 setup key 0건 | 이번 작업에서 만든 유일한 setup key는 OPNsense routing peer 등록용 one-off(usage_limit 1)이며 사용 즉시 소모(`valid: false`)됐다. 실제 사용자 peer는 전부 interactive OIDC로만 등록했다 |
| session revoke·사용자 차단·peer 삭제 뒤 재접근 거부 | (1) Keycloak Admin API로 `imcherry5778`의 모든 세션 revoke(`204`). (2) NetBird Owner API로 해당 사용자 `is_blocked=true`. (3) 등록된 peer를 API로 삭제. 이후 그 peer의 저장된 로그인 상태로 재연결 시도 → `PermissionDenied: peer login has expired, please log in once more`. 차단 상태에서 완전히 새로 등록을 시도해도 peer record는 생기지만 `connected: false`로 실제 통신은 되지 않는다 |
| 임시 자원 0건 | 검증용 peer 2개·setup key(headless)·Docker container·Unbound 디버그 ACL/로깅을 모두 제거·원복했다. `imcherry5778`은 실제 운영자의 상시 사용 계정이라 검증 뒤 NetBird 차단 해제·소속 group 복원·기존 peer(`fedora`) 재연결까지 확인했다 |

## 사전 존재 결함 (이번 작업에서 발견, 고치지 않음)

NetBird v0.73.0/0.74.x 클라이언트의 `netbird up`/`netbird login`은 Linux에서
`DESKTOP_SESSION`·`XDG_CURRENT_DESKTOP` 환경변수가 모두 없으면(전형적인 headless
서버) 무조건 OAuth Device Authorization Grant로 로그인한다. 이 랩의 `netbird-client`는
`pkce.code.challenge.method=S256`을 필수로 요구하는데, NetBird의 device code 요청은
`code_challenge_method`를 보내지 않아 Keycloak이 `400 Missing parameter:
code_challenge_method`로 거부한다. 실제 데스크톱 환경(GNOME/KDE/macOS/Windows나
NetBird 트레이 앱)에서는 PKCE flow를 쓰므로 이 결함에 영향받지 않으며, `NB-ENROLL-01`의
완료 증거도 이 경로로 검증했다. 완전히 headless한 사람 장치(모니터 없는 서버 등)로
interactive 등록이 필요해지면 별도 FIX 작업에서 `pkce.code.challenge.method`를
선택적으로 완화할지 검토한다 — 이번 작업 범위에서는 다루지 않는다.

## Rollback

1. NetBird: 위 표의 Policy 3개·Nameserver Group·Network(Resource·Router 포함)·
   전용 Group 3개를 API로 삭제한다(`netbird-access-ingress.py rollback`). `/platform-users`
   JWT group과 `Default` 정책은 건드리지 않는다.
2. OPNsense: Firewall Rules 2개(`opt6`)를 disable 후 삭제. VPN > NetBird에서
   `authentication/down` 호출 뒤 Authentication·Settings를 초기값으로 되돌리거나
   `os-netbird` 패키지를 제거한다. Interfaces 배정에서 `opt6`를 disable(운영자가
   직접 GUI에서 최종 삭제 확인). Unbound ACL(`nb-enroll-01-netbird-overlay`)을 삭제한다.
3. netbird-01: `systemctl disable --now dnsmasq`, `/etc/dnsmasq.d/nb-enroll-01.conf` 제거,
   `dnf remove dnsmasq`(다른 용도로 쓰지 않는 경우).
4. `EDGE-01`의 recovery group·policy, `EDGE-02`의 공개 인증면은 이 rollback의 대상이
   아니다.

이 rollback은 신규 device 등록 경로만 제거한다. 이미 이 경로로 등록된 실제 사용자
peer는 대상 사용자별로 `NB-ENROLL-01`이 아니라 `IAM-MIG-01`/평상시 offboarding
절차로 개별 처리한다.
