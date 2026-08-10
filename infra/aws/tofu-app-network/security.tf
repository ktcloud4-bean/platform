resource "aws_security_group" "eks_nodes_sg" {
  name        = "${local.name_prefix}-eks-nodes-sg"
  description = "Security group for EKS worker nodes"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow all traffic within the VPC (node-to-node, ALB health checks)"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # ECR·S3·STS endpoint와 RDS 규칙은 아래의 특정 목적지만 허용한다.
  egress {
    description     = "HTTPS to ECR and STS interface endpoints"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.aws_service_endpoints_sg.id]
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

  tags = {
    Name = "${local.name_prefix}-eks-nodes-sg"
  }
}

resource "aws_security_group" "rds_sg" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Security group for RDS PostgreSQL - VPC internal access only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Allow PostgreSQL (5432) from within the VPC only (includes EKS nodes)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # RDS는 client 연결의 stateful 응답만 필요하므로 새 outbound flow를 만들지 않는다.
  egress = []

  tags = {
    Name = "${local.name_prefix}-rds-sg"
  }
}

resource "aws_security_group" "aws_service_endpoints_sg" {
  name        = "${local.name_prefix}-aws-service-endpoints-sg"
  description = "PrivateLink endpoints reachable from EKS private application subnets only"
  vpc_id      = aws_vpc.main.id

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
