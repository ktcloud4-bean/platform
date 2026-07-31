# OPNsense ↔ AWS Site-to-Site VPN

- 목적: 온프레미스 DATA VLAN과 AWS 사설 착지점 VPC를 IPsec 터널로 잇는다.
- 검증일: 2026-07-31 (`AWS-NET-01`)
- 소유 결정: [ADR-0011](../adr/0011-aws-site-to-site-vpn-boundary.md)
- AWS 자원 선언: [`infra/aws/tofu-network`](../../infra/aws/tofu-network/README.md)

주소와 대역은 [`ip-plan.md`](../ip-plan.md)가 소유한다. AWS가 할당하는 터널 endpoint와
검증 인스턴스 주소는 매번 달라지므로 이 문서에 고정값으로 적지 않고 `tofu output`에서 읽는다.

## 전제조건과 접근 권한

- `NET-03`의 VLAN bootstrap 방화벽이 적용되어 있고 drift가 없다.
- OPNsense API 자격증명(`OPN_KEY`/`OPN_SECRET`)과 관리 SSH.
- AWS 관리자 자격증명. 이 root가 만드는 자원에는 IAM이 없으므로 전송용 백업 key로는 적용할 수 없다.
- OOB 콘솔 접근. IPsec 자체는 관리 경로를 바꾸지 않지만 방화벽을 건드리므로 복구 경로를 먼저 확인한다.

## 예상 영향과 공유 잠금

- 잠금: `OPNSENSE-LIVE`. 방화벽 규칙과 IPsec 설정을 바꾼다.
- AWS state는 오프사이트 백업 root와 분리되어 있어 그쪽을 사정권에 넣지 않는다.
- **VPN Connection은 존재하는 시간에 비례해 과금된다.** 적용 전에 유지 기간을 결정한다.

## 실행 순서

### 1. AWS 착지점 적용

```bash
cd infra/aws/tofu-network
tofu init -reconfigure -backend-config="path=<저장소 밖 state 경로>"
tofu plan  -var-file=<저장소 밖 tfvars>
tofu apply -var-file=<저장소 밖 tfvars>
```

`customer_gateway_ip`에는 OPNsense WAN의 현재 공인 IPv4를 넣는다. VPN Connection 생성에는
4분 안팎이 걸린다.

### 2. 터널 PSK 회수

```bash
umask 077
tofu output -raw tunnel1_preshared_key > <저장소 밖 경로>/aws-tunnel1.psk
```

값을 화면·셸 기록·로그에 남기지 않는다.

### 3. OPNsense IPsec 구성

OPNsense 26.7은 swanctl 기반 Connections 모델을 쓴다. legacy tunnel 화면이 아니라
`VPN > IPsec > Connections`에 만든다. API로 할 때는 body를 mode `0600` 임시 파일로만 넘겨
PSK가 명령 인자에 남지 않게 한다.

| 대상 | 값 |
|---|---|
| Pre-Shared Key | ident=WAN 공인 IP, remote_ident=터널1 endpoint, type=PSK |
| Connection | IKEv2, proposal `aes256-sha256-modp2048`, MOBIKE 끔, NAT-T 강제 안 함 |
| Connection lifetime | `rekey_time` 28800 (AWS phase1과 동일) |
| Local | auth=psk, id=WAN 공인 IP |
| Remote | auth=psk, id=터널1 endpoint |
| Child | esp proposal 동일, `local_ts`=온프레미스 대역, `remote_ts`=VPC 대역, `rekey_time` 3600 |
| Child 동작 | `start_action=start`, `dpd_action=start` |

그다음 IPsec 일반 설정의 `enabled`를 켜고, **Connections 모델 스위치를 따로 켠다**
(`/api/ipsec/connections/toggle/1`). 이 스위치가 꺼져 있으면 만든 Connection이
`swanctl.conf`에 반영되지 않는다. 마지막으로 서비스를 reconfigure 한다.

### 4. 방화벽

`NET-03`이 각 VLAN에서 RFC1918 목적지를 먼저 차단하므로 AWS 대역도 거기에 걸린다.
AWS 대역 alias를 만들고 **그 차단 규칙보다 앞선 순서**에 허용 규칙을 넣는다.
DATA VLAN 기준으로 차단 규칙이 seq 1320이므로 허용은 1315에 둔다.

역방향(AWS에서 온프레미스로 신규 연결)은 열지 않는다. OPNsense는 IPsec 터널 트래픽에
`pass out on enc0 ... keep state`만 두므로 온프레미스가 개시한 흐름과 그 응답만 통과한다.
이것이 안전한 기본값이며 이 작업은 그 상태로 끝낸다.

## 중단 조건

- `tofu plan`에 예상하지 않은 변경·삭제가 보인다.
- WAN 공인 IP가 tfvars 값과 다르다.
- PSK가 스냅샷이나 로그에 남을 수 있다.
- 관리 경로나 기존 VLAN 통신이 끊긴다.

## 성공 판정

2026-07-31에 아래를 모두 실측했다.

**터널 확립.** OPNsense `swanctl --list-sas`에서 IKE SA `ESTABLISHED`,
Child SA `INSTALLED`, `AES_CBC-256/HMAC_SHA2_256_128/PRF_HMAC_SHA2_256/MODP_2048`,
traffic selector가 온프레미스 대역 ↔ VPC 대역. AWS `describe-vpn-connections`에서
터널1 `UP`, `AcceptedRouteCount` 1, static route `available`. 양쪽 관점이 일치했다.

**정방향 통신.** OPNsense가 VLAN gateway 주소를 소스로 보낸 ICMP 3/3과 HTTP marker 응답,
이어 실제 VM(`object-01`)에서도 ICMP 3/3(RTT 약 6.9ms)과 marker 응답을 확인했다.
ICMP만이 아니라 payload로 판정했다. SA 카운터가 in/out 양쪽에서 증가해 트래픽이 실제로
터널을 지난 것을 확인했다.

**대상 대역만.** traffic selector 밖 출발지(PLATFORM·ACCESS gateway)에서 같은 목적지로
보낸 ICMP는 100% 손실이었고, 실제 VM(`k3s-01`, PLATFORM)에서도 TCP·HTTP가 실패했다.
모든 BLOCK은 같은 시점 `object-01`의 성공을 대조 증거로 두었다.

**역방향.** AWS 인스턴스에서 온프레미스로 오는 신규 연결은 기본 상태에서 도달하지 않는다.
경로 자체가 살아 있음을 보이려고 임시로 좁은 허용 규칙(VPC 대역 → 특정 호스트의 특정 TCP
포트)을 넣었을 때는 연결과 payload가 온프레미스 listener에 도착했고, 규칙을 제거한 뒤
100초(재시도 3회분) 동안 0건이었다. 같은 시점 정방향은 계속 성공했다. 규칙은 제거한 상태로
끝냈다.

**인터넷 기본 경로 불변.** 기본 경로는 계속 WAN gateway이고, 커널 라우팅 테이블에 VPC
대역 항목이 생기지 않았다(policy-based라 IPsec 정책만 사용). VPC에는 인터넷 gateway가 없다.

**재부팅 후.** OPNsense를 재부팅하자 부팅 34초 뒤 IKE·Child SA가 자동으로 다시 확립됐고
같은 selector·알고리즘이었다. 정방향 통신, PLATFORM 차단, 기본 경로, AWS 대역 허용 규칙,
`enc0` 인바운드 규칙 부재가 모두 재부팅 전과 같았다.

**장애 격리와 복구.** IPsec 서비스를 내리자 AWS 사설 경로만 끊겼고 DNS·인터넷 HTTPS(200)·
관리 SSH·기본 경로는 영향이 없었다. 서비스를 다시 올리자 통신이 복구됐다.

**정리와 드리프트.** 검증 인스턴스와 보안 그룹 5개를 제거했고 최종 `tofu plan`은 무변경이다.
온프레미스 임시 listener와 파일도 제거했다. 스냅샷을 갱신한 뒤 실제 PSK 문자열로 검색해
평문이 남지 않은 것을 확인했고 일반 drift 검사는 무변경이었다.

## 알려진 한계

- 터널 2는 AWS 쪽에만 존재하고 온프레미스에 구성하지 않았다. AWS가 터널 1을 유지보수하는
  동안 단절될 수 있다. 이 경로는 필수 서비스 경로가 아니다.
- WAN이 ISP DHCP 임대 주소다. 주소가 바뀌면 터널이 끊기고, Customer Gateway 교체와
  OPNsense remote 주소 수정을 함께 해야 복구된다.
- DATA VLAN 허용 규칙은 프로토콜·포트를 좁히지 않은 임시 규칙이다. 실제 서비스가 정해지면
  `NET-04`가 통신표로 다시 판정한다.
- 이 검증은 경로가 동작함을 보인 것이지 그 위에 올릴 서비스를 검증한 것이 아니다.

## 실패 시 원상복구

**터널만 내리기.** OPNsense에서 IPsec 서비스를 멈추면 AWS 경로만 끊기고 나머지는 유지된다.
이것이 가장 빠른 완화다.

**AWS 쪽 비용 정지.** `create_vpn_connection=false`로 apply 하면 VPN Connection이 사라지고
VPC·서브넷·VGW만 남는다. 과금 자원이 0이 된다.

```bash
tofu apply -var-file=<저장소 밖 tfvars> -var 'create_vpn_connection=false'
```

**주의: 다시 열면 PSK와 터널 endpoint가 새로 발급된다.** 같은 OPNsense 설정으로는 붙지
않으므로 PSK를 다시 회수하고 Connection의 remote 주소와 Pre-Shared Key를 갱신해야 한다.
연결을 자주 껐다 켤 계획이면 이 재구성 비용을 감안한다.

**OPNsense 설정 되돌리기.** Connections의 child·remote·local·connection과 Pre-Shared Key를
지우고, Connections 모델 스위치와 IPsec 일반 설정을 원래대로 되돌린 뒤 reconfigure 한다.
방화벽에서는 AWS 허용 규칙과 alias를 제거하고 적용한다. AWS 쪽만 지우고 OPNsense 설정을
남기면 터널이 영원히 재연결을 시도하므로 두 쪽을 함께 되돌린다.

**전체 폐기.** `tofu destroy`는 이 root의 자원만 지운다. 오프사이트 백업 bucket은 다른
state가 소유하므로 사정권에 들어오지 않는다. plan으로 먼저 확인한다.

## 남기면 안 되는 출력

- tunnel pre-shared key. state·plan 파일·`tofu output`의 원문.
- AWS 계정 ID, WAN 공인 IP가 들어간 tfvars.
- OPNsense API key/secret.
- 원본 `config.raw.xml`. 정규화 전에는 PSK와 사용자 해시를 포함한다.
