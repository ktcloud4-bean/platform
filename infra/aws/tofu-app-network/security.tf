resource "aws_security_group" "eks_nodes_sg" {
  name        = "${local.name_prefix}-eks-nodes-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = data.terraform_remote_state.shared_network.outputs.vpc_id

  ingress {
    description = "Allow required node and Pod traffic within the HR VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.terraform_remote_state.shared_network.outputs.vpc_cidr]
  }

  # VPC CNI Pod IP는 worker node ENI에 붙는다. 서로 다른 node의 frontend/API Pod 통신은
  # Kubernetes NetworkPolicy가 service별 port를 제한하지만, 이 lower-layer security group도
  # 같은 node SG 안의 data-plane packet을 허용해야 한다. 그렇지 않으면 cross-node Service
  # request가 TCP connect 단계에서 대기해 upstream timeout으로 보인다.
  egress {
    description = "Allow EKS node and VPC CNI Pod data-plane traffic within the node security group"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    description = "Allow node-to-control-plane and intra-VPC communication for admission webhooks"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.terraform_remote_state.shared_network.outputs.vpc_cidr]
  }

  # ECR·S3·STS endpoint와 RDS 규칙은 아래의 특정 목적지만 허용한다.
  egress {
    description     = "HTTPS to explicitly declared AWS PrivateLink endpoints"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.aws_service_endpoints_sg.id]
  }

  egress {
    description     = "HTTPS to the private EKS API endpoint"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_cluster_endpoint_sg.id]
  }

  egress {
    description     = "HTTPS to S3 gateway endpoint"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [aws_vpc_endpoint.s3.prefix_list_id]
  }

  egress {
    description     = "PostgreSQL to the application RDS security group"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.rds_sg.id]
  }

  egress {
    description = "DNS to the VPC resolver only"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["${cidrhost(data.terraform_remote_state.shared_network.outputs.vpc_cidr, 2)}/32"]
  }

  egress {
    description = "TCP DNS to the VPC resolver only"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["${cidrhost(data.terraform_remote_state.shared_network.outputs.vpc_cidr, 2)}/32"]
  }

  # ClusterFirst Pod DNS는 CoreDNS Service를 거쳐 같은 private application subnet의
  # CoreDNS Pod로 DNAT된다. VPC resolver(.2)만 열면 이 hop이 막혀 IRSA와 AWS PrivateLink
  # hostname을 해석할 수 없다. CoreDNS가 배치되는 EKS app subnet의 DNS 두 protocol만 연다.
  egress {
    description = "UDP DNS to CoreDNS Pods in EKS private application subnets"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = var.private_app_subnet_cidrs
  }

  egress {
    description = "TCP DNS to CoreDNS Pods in EKS private application subnets"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = var.private_app_subnet_cidrs
  }

  egress {
    description = "AWS time synchronization for private managed nodes"
    from_port   = 123
    to_port     = 123
    protocol    = "udp"
    cidr_blocks = ["169.254.169.123/32"]
  }

  egress {
    description = "IMDSv2 credential and bootstrap metadata"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["169.254.169.254/32"]
  }

  tags = {
    Name = "${local.name_prefix}-eks-nodes-sg"
  }
}

resource "aws_security_group" "rds_sg" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Security group for RDS PostgreSQL - VPC internal access only"
  vpc_id      = data.terraform_remote_state.shared_network.outputs.vpc_id

  # RDS는 client 연결의 stateful 응답만 필요하므로 새 outbound flow를 만들지 않는다.
  egress = []

  tags = {
    Name = "${local.name_prefix}-rds-sg"
  }
}

# EKS node SG의 RDS egress와 같은 resource에 inline으로 넣으면 두 SG가 순환 참조한다.
# 별도 rule도 source SG/5432 제한은 동일하게 유지한다.
resource "aws_security_group_rule" "rds_from_eks_nodes" {
  type                     = "ingress"
  description              = "Allow PostgreSQL only from EKS nodes and their VPC CNI Pod addresses"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_sg.id
  source_security_group_id = aws_security_group.eks_nodes_sg.id
}

resource "aws_security_group" "aws_service_endpoints_sg" {
  name        = "${local.name_prefix}-aws-service-endpoints-sg"
  description = "PrivateLink endpoints reachable from EKS private application subnets only"
  vpc_id      = data.terraform_remote_state.shared_network.outputs.vpc_id

  ingress {
    description = "HTTPS from EKS private application subnets"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.private_app_subnet_cidrs
  }

  # Interface endpoint는 inbound request의 stateful response만 보낸다.
  egress = []

  tags = {
    Name = "${local.name_prefix}-aws-service-endpoints-sg"
  }
}

resource "aws_security_group" "eks_cluster_endpoint_sg" {
  name        = "${local.name_prefix}-eks-cluster-endpoint-sg"
  description = "Private EKS API access only from PLATFORM management CIDR and EKS nodes"
  vpc_id      = data.terraform_remote_state.shared_network.outputs.vpc_id

  ingress {
    description = "HTTPS from the on-premises Pomerium and Argo management VLAN"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.onprem_management_cidr]
  }

  # managed node ENI와 VPC CNI Pod IP는 EKS control plane SG ID를 Terraform root
  # 경계 밖으로 전달하지 않는다. HR shared VPC 안의 HTTPS 하나만 열어 node bootstrap과
  # Pod API access를 허용한다.
  ingress {
    description = "HTTPS from HR shared VPC nodes and Pods"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.terraform_remote_state.shared_network.outputs.vpc_cidr]
  }

  # EKS control-plane이 admission webhook, metrics-server 등을 위해 worker node 및 Pod로
  # 아웃바운드 연결할 수 있도록 node SG로의 egress를 허용한다.
  egress {
    description = "Allow control plane to communicate with worker nodes and webhooks"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.terraform_remote_state.shared_network.outputs.vpc_cidr]
  }

  tags = {
    Name = "${local.name_prefix}-eks-cluster-endpoint-sg"
  }
}

# ALB lifecycle는 Kubernetes Ingress가 소유하지만 ingress source SG 자체는 수명·경계를
# 명확히 하기 위해 OpenTofu가 소유한다. backend node SG는 이미 VPC 내부 ingress만 허용하므로
# Controller가 동적 SG rule을 추가하지 않도록 Ingress에서 manage-backend-security-group-rules=false
# 를 함께 선언한다.
resource "aws_security_group" "internal_alb_sg" {
  name        = "${local.name_prefix}-internal-alb-sg"
  description = "Internal HR ALB accepts HTTP only from on-prem PLATFORM over IPsec"
  vpc_id      = data.terraform_remote_state.shared_network.outputs.vpc_id

  ingress {
    description = "HTTP from on-prem Pomerium through the dedicated HR VPN"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.onprem_management_cidr]
  }

  egress {
    description     = "HTTP to HR frontend targets only"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes_sg.id]
  }

  tags = {
    Name = "${local.name_prefix}-internal-alb-sg"
  }
}


# Route 53 Resolver inbound endpoint는 OPNsense Unbound가 EKS private endpoint의
# AWS DNS zone만 조건부 질의할 때 사용한다. endpoint IP를 host override로 고정하지 않아
# endpoint 교체에도 EKS API 이름 해석 경계를 유지한다.
resource "aws_security_group" "route53_resolver_inbound_sg" {
  name        = "${local.name_prefix}-route53-resolver-inbound-sg"
  description = "Route 53 Resolver inbound DNS only from PLATFORM Unbound"
  vpc_id      = data.terraform_remote_state.shared_network.outputs.vpc_id

  ingress {
    description = "UDP DNS from the on-premises PLATFORM resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [var.onprem_management_cidr]
  }

  ingress {
    description = "TCP DNS from the on-premises PLATFORM resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [var.onprem_management_cidr]
  }

  # Resolver inbound endpoint는 질의의 stateful 응답만 보낸다.
  egress = []

  tags = {
    Name = "${local.name_prefix}-route53-resolver-inbound-sg"
  }
}
