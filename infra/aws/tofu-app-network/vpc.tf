# HR workload는 `tofu-network`가 이미 소유한 10.20.0.0/16 shared VPC에만 둔다. 이
# root가 VPC·default security group을 다시 선언하거나 import하면 legacy DATA VPN state와
# 소유권이 겹치므로, HR 전용 subnet·route table·endpoint·security group만 소유한다.
resource "aws_subnet" "private_app" {
  count             = length(var.private_app_subnet_cidrs)
  vpc_id            = data.terraform_remote_state.shared_network.outputs.vpc_id
  cidr_block        = var.private_app_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = false

  tags = {
    Name                                                 = "${local.name_prefix}-private-app-subnet-${local.azs[count.index]}"
    "kubernetes.io/role/internal-elb"                    = "1"
    "kubernetes.io/cluster/${local.name_prefix}-cluster" = "shared"
  }
}

resource "aws_subnet" "private_db" {
  count             = length(var.private_db_subnet_cidrs)
  vpc_id            = data.terraform_remote_state.shared_network.outputs.vpc_id
  cidr_block        = var.private_db_subnet_cidrs[count.index]
  availability_zone = local.azs[count.index]

  map_public_ip_on_launch = false

  tags = {
    Name = "${local.name_prefix}-private-db-subnet-${local.azs[count.index]}"
  }
}

# local route만 가진 private route table이다. VPN root가 생성하는 on-prem route 외에
# default route를 추가하지 않는다.
resource "aws_route_table" "private" {
  count  = length(local.azs)
  vpc_id = data.terraform_remote_state.shared_network.outputs.vpc_id

  tags = {
    Name = "${local.name_prefix}-private-rt-${local.azs[count.index]}"
  }
}

resource "aws_route_table_association" "private_app" {
  count          = length(aws_subnet.private_app)
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "private_db" {
  count          = length(aws_subnet.private_db)
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# NAT 없이 EKS node/IRSA/ALB controller가 필요로 하는 AWS API만 PrivateLink로 제공한다.
resource "aws_vpc_endpoint" "aws_service" {
  for_each = {
    ecr_api              = "ecr.api"
    ecr_dkr              = "ecr.dkr"
    sts                  = "sts"
    rds                  = "rds"
    ec2                  = "ec2"
    elasticloadbalancing = "elasticloadbalancing"
    secretsmanager       = "secretsmanager"
  }

  vpc_id              = data.terraform_remote_state.shared_network.outputs.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private_app[*].id
  security_group_ids  = [aws_security_group.aws_service_endpoints_sg.id]
  private_dns_enabled = true

  tags = {
    Name = "${local.name_prefix}-${each.key}-endpoint"
  }
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = data.terraform_remote_state.shared_network.outputs.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = {
    Name = "${local.name_prefix}-s3-endpoint"
  }
}

# OPNsense Unbound가 private EKS API FQDN을 AWS authoritative resolver에 전달하는
# 이중 AZ inbound endpoint다. public DNS, NAT, 고정 host override는 만들지 않는다.
resource "aws_route53_resolver_endpoint" "onprem_inbound" {
  name               = "${local.name_prefix}-onprem-inbound"
  direction          = "INBOUND"
  security_group_ids = [aws_security_group.route53_resolver_inbound_sg.id]

  dynamic "ip_address" {
    for_each = aws_subnet.private_app

    content {
      subnet_id = ip_address.value.id
    }
  }

  tags = {
    Name = "${local.name_prefix}-onprem-inbound"
  }
}
