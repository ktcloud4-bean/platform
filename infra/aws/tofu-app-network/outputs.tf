output "vpc_id" {
  description = "생성된 VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록"
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "프라이빗 앱 서브넷 ID 목록"
  value       = aws_subnet.private_app[*].id
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
