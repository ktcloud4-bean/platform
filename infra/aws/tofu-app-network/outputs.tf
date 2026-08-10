output "vpc_id" {
  description = "tofu-network가 소유한 shared VPC ID"
  value       = data.terraform_remote_state.shared_network.outputs.vpc_id
}

output "vpc_cidr" {
  description = "Shared VPC CIDR. HR VPN traffic selector의 AWS 쪽 대역이다."
  value       = data.terraform_remote_state.shared_network.outputs.vpc_cidr
}

output "private_app_subnet_ids" {
  description = "프라이빗 앱 서브넷 ID 목록"
  value       = aws_subnet.private_app[*].id
}

output "private_route_table_ids" {
  description = "VPN root가 on-prem route만 추가할 private route table ID 목록"
  value       = aws_route_table.private[*].id
}

output "private_db_subnet_ids" {
  description = "프라이빗 DB 서브넷 ID 목록"
  value       = aws_subnet.private_db[*].id
}

output "eks_nodes_security_group_id" {
  description = "EKS 노드용 보안 그룹 ID"
  value       = aws_security_group.eks_nodes_sg.id
}

output "rds_security_group_id" {
  description = "RDS용 보안 그룹 ID"
  value       = aws_security_group.rds_sg.id
}

output "eks_cluster_endpoint_security_group_id" {
  description = "Private EKS API endpoint 접근을 제한하는 보안 그룹 ID"
  value       = aws_security_group.eks_cluster_endpoint_sg.id
}

output "internal_alb_security_group_id" {
  description = "Kubernetes internal ALB ingress에 지정할 OpenTofu 소유 security group ID"
  value       = aws_security_group.internal_alb_sg.id
}

output "aws_service_endpoints_security_group_id" {
  description = "AWS PrivateLink endpoint용 보안 그룹 ID"
  value       = aws_security_group.aws_service_endpoints_sg.id
}

output "route53_resolver_inbound_ips" {
  description = "OPNsense Unbound의 EKS AWS DNS conditional forwarder가 사용할 Resolver inbound IP 목록"
  value       = aws_route53_resolver_endpoint.onprem_inbound.ip_address[*].ip
}

output "hr_internal_private_zone_id" {
  description = "Pomerium용 internal ALB 별칭을 소유하는 Route 53 private hosted zone ID"
  value       = aws_route53_zone.hr_internal.zone_id
}
