# OPNsense WAN을 가리키는 Customer Gateway.
# ISP DHCP 임대 주소이므로 이 값이 바뀌면 터널이 끊긴다. 주소가 바뀌면
# 변수를 갱신해 이 자원을 교체하고 OPNsense 쪽 remote 주소도 함께 맞춘다.
resource "aws_customer_gateway" "onprem" {
  type       = "ipsec.1"
  ip_address = var.customer_gateway_ip

  # static routing이라 BGP 세션을 맺지 않지만 AWS가 필수로 요구하는 필드다.
  bgp_asn = var.customer_gateway_bgp_asn

  tags = {
    Name = "${var.name_prefix}-opnsense"
  }
}

# Site-to-Site VPN.
# 이 root의 상시 비용은 사실상 전부 이 자원 하나에서 나온다(연결 시간당 과금).
# create_vpn_connection 을 닫으면 VPC·서브넷·VGW만 남고 과금 자원이 0이 된다.
resource "aws_vpn_connection" "onprem" {
  count = var.create_vpn_connection ? 1 : 0

  vpn_gateway_id      = aws_vpn_gateway.main.id
  customer_gateway_id = aws_customer_gateway.onprem.id
  type                = "ipsec.1"

  # BGP를 쓰지 않는다. 동적 경로를 학습하지 않으므로 터널이 온프레미스나 VPC의
  # 기본 경로를 바꿀 수 없다. "인터넷 기본 경로 불변"을 구성으로 보장하는 부분이다.
  static_routes_only = true

  # traffic selector를 양쪽 대역으로 좁힌다. 이 두 줄이 policy-based 구성의 핵심이며
  # 지정한 대역 밖의 트래픽은 IPsec SA 자체에 실리지 않는다.
  # 기본값 0.0.0.0/0을 그대로 두면 터널이 모든 목적지를 받아들인다.
  local_ipv4_network_cidr  = var.onprem_cidr
  remote_ipv4_network_cidr = var.vpc_cidr

  # 알고리즘을 명시해 OPNsense 쪽 제안과 정확히 맞춘다. 기본값에 맡기면 AWS가
  # 넓은 후보 집합을 광고하고, 어떤 조합으로 합의됐는지 사후에만 알 수 있다.
  tunnel1_ike_versions                 = ["ikev2"]
  tunnel1_phase1_encryption_algorithms = ["AES256"]
  tunnel1_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase1_dh_group_numbers      = [14]
  tunnel1_phase2_encryption_algorithms = ["AES256"]
  tunnel1_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel1_phase2_dh_group_numbers      = [14]
  tunnel1_dpd_timeout_action           = "restart"

  tunnel2_ike_versions                 = ["ikev2"]
  tunnel2_phase1_encryption_algorithms = ["AES256"]
  tunnel2_phase1_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase1_dh_group_numbers      = [14]
  tunnel2_phase2_encryption_algorithms = ["AES256"]
  tunnel2_phase2_integrity_algorithms  = ["SHA2-256"]
  tunnel2_phase2_dh_group_numbers      = [14]
  tunnel2_dpd_timeout_action           = "restart"

  tags = {
    Name = "${var.name_prefix}-onprem"
  }
}

# static routing이므로 온프레미스 대역을 VPN에 명시 등록한다.
# 이 경로가 있어야 AWS가 해당 목적지를 터널로 보낸다.
resource "aws_vpn_connection_route" "onprem" {
  count = var.create_vpn_connection ? 1 : 0

  vpn_connection_id      = aws_vpn_connection.onprem[0].id
  destination_cidr_block = var.onprem_cidr
}
