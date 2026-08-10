# 사설 착지점 VPC.
# 이 VPC에는 인터넷 gateway도 NAT gateway도 없다. 유일한 외부 경로가 VPN이라는 것이
# "대상 대역만 통신"과 "인터넷 기본 경로 불변"을 구조로 강제한다.
# 계정의 default VPC와 CloudTrail bucket 등 기존 자원은 선언하지도 import하지도 않는다.
resource "aws_vpc" "onprem_link" {
  cidr_block = var.vpc_cidr

  # HR의 Interface VPC Endpoint Private DNS를 위해 VPC DNS를 모두 켠다.
  # 인터넷 gateway와 public IP가 없으므로 공개 접근 경로는 만들지 않는다.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = local.vpc_name
  }
}

resource "aws_subnet" "private_a" {
  vpc_id            = aws_vpc.onprem_link.id
  cidr_block        = var.private_subnet_cidr
  availability_zone = var.availability_zone

  # 공인 IP를 자동 배정하지 않는다. 붙일 IGW가 없으므로 의미도 없지만
  # 기본값에 기대지 않고 명시한다.
  map_public_ip_on_launch = false

  tags = {
    Name = local.subnet_name
  }
}

resource "aws_vpn_gateway" "main" {
  vpc_id = aws_vpc.onprem_link.id

  tags = {
    Name = "${var.name_prefix}-vgw"
  }
}

# 이 VPC의 유일한 route table이다. 기본 route table을 그대로 두지 않고
# 명시적으로 선언해 어떤 경로가 존재하는지 한곳에서 읽히게 한다.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.onprem_link.id

  tags = {
    Name = "${var.name_prefix}-private"
  }
}

# 온프레미스 대역만 VGW로 보낸다. 0.0.0.0/0 경로는 만들지 않는다.
# VPC 안에서 인터넷으로 나가는 경로가 없다는 것이 이 root의 의도된 경계다.
resource "aws_route" "to_onprem" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = var.onprem_cidr
  gateway_id             = aws_vpn_gateway.main.id
}

resource "aws_route_table_association" "private_a" {
  subnet_id      = aws_subnet.private_a.id
  route_table_id = aws_route_table.private.id
}

# 기본 security group을 비워 둔다. AWS는 VPC마다 all-allow 기본 SG를 만드는데,
# 선언하지 않으면 그 상태가 그대로 남는다. 규칙 0개로 고정한다.
resource "aws_default_security_group" "locked" {
  vpc_id = aws_vpc.onprem_link.id

  tags = {
    Name = "${var.name_prefix}-default-locked"
  }
}
