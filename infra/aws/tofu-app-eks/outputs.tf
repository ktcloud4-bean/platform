output "eks_cluster_name" {
  description = "EKS 클러스터 이름"
  value       = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  description = "EKS API Server 엔드포인트"
  value       = aws_eks_cluster.main.endpoint
}

output "eks_cluster_arn" {
  description = "EKS 클러스터 ARN"
  value       = aws_eks_cluster.main.arn
}

output "alb_controller_iam_role_arn" {
  description = "AWS Load Balancer Controller IAM Role ARN"
  value       = aws_iam_role.alb_controller.arn
}

output "employee_service_iam_role_arn" {
  description = "Employee service ServiceAccount의 IRSA role ARN"
  value       = aws_iam_role.employee_service.arn
}

output "hr_service_iam_role_arn" {
  description = "HR service ServiceAccount의 IRSA role ARN"
  value       = aws_iam_role.hr_service.arn
}

output "db_migrate_iam_role_arn" {
  description = "DB migration Job ServiceAccount의 제한된 IRSA role ARN"
  value       = aws_iam_role.db_migrate.arn
}

output "kyverno_admission_iam_role_arn" {
  description = "Kyverno admission controller ServiceAccount의 IRSA role ARN"
  value       = aws_iam_role.kyverno_admission.arn
}

