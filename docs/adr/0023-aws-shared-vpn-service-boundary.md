# ADR-0023: AWS shared VPN은 하나로 두고 HR 흐름은 서비스 rule로 제한

- 상태: `Accepted`
- 날짜: 2026-08-11
- 관련 작업: `AWS-NET-01`, `AWS-HR-01`, `NET-04`

## 배경

기존 AWS 착지점은 DATA VLAN만 포함한 policy-based selector로 시작했다. HR EKS를 같은
`10.20.0.0/16` shared VPC에 통합하면서 PLATFORM의 k3s Argo·Pomerium도 사설 AWS 경로를
필요로 했다. DATA와 PLATFORM을 서로 다른 VPN connection으로 나누면 VGW·Customer Gateway는
공유해도 PSK, 터널 상태, 정적 route와 장애 대응을 두 번 운영해야 한다.

## 결정

AWS shared VPC와 온프레미스 사이에는 static routing의 policy-based VPN connection 하나만
유지하고 traffic selector를 `10.10.0.0/16 ↔ 10.20.0.0/16`으로 둔다. 이 selector는
암호화 가능 대역일 뿐 통신 허용 목록이 아니다.

HR 허용은 OPNsense에서 `k3s-01` source `/32`로 한정한다. 필요한 목적지는 Route 53
Resolver inbound endpoint의 DNS TCP/UDP 53, private EKS API TCP 443, internal ALB TCP 80뿐이다.
AWS 보안 그룹도 각각 PLATFORM CIDR, EKS node, 필요한 service endpoint만 다시 제한한다.
OPNsense Unbound가 policy-based source selector로 AWS Resolver를 직접 질의하지 못하는
경우에는 EKS consumer인 `k3s-01`의 port 1053 two-zone relay를 거친다. 이 relay는 일반
재귀 resolver가 아니다.

## 검토한 대안

- DATA와 HR VPN connection을 분리한다: 암호화 대역은 더 좁지만 동일 VPC·동일 사이트에서
  tunnel lifecycle과 복구 절차를 중복하므로 채택하지 않는다.
- 모든 `10.10.0.0/16`에서 AWS 전체 port를 허용한다: 넓은 selector를 방화벽 허용으로
  오인하게 되어 채택하지 않는다.
- OPNsense가 AWS Resolver를 직접 forward한다: live source selector와 맞지 않아 질의가
  전달되지 않았으므로 채택하지 않는다.

## 결과

VPN 단일 장애와 AWS가 제공한 미구성 보조 tunnel이라는 기존 가용성 한계는 유지된다. HR
서비스가 필요로 하는 port가 늘면 public egress나 broad allow로 우회하지 않고 OPNsense rule,
AWS security group, NetworkPolicy와 해당 service endpoint를 함께 검토한다.

## 재검토 조건

두 번째 VPC·온프레미스 사이트·규제상 완전히 분리된 tenant가 생겨 routing domain을 분리하는
편이 더 단순해질 때, 또는 서비스가 중단 불가여서 route-based dual tunnel이 필요할 때다.
