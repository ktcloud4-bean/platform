output "ecr_frontend_repository_url" {
  description = "Frontend ECR 저장소 URL"
  value       = aws_ecr_repository.service["frontend"].repository_url
}

output "ecr_employee_service_repository_url" {
  description = "Employee service ECR 저장소 URL"
  value       = aws_ecr_repository.service["employee-service"].repository_url
}

output "ecr_hr_service_repository_url" {
  description = "HR service ECR 저장소 URL"
  value       = aws_ecr_repository.service["hr-service"].repository_url
}

output "ecr_bootstrap_repository_urls" {
  description = "Private EKS bootstrap controller image를 mirror할 ECR repository URL"
  value = {
    argocd                       = aws_ecr_repository.service["bootstrap-argocd"].repository_url
    redis                        = aws_ecr_repository.service["bootstrap-redis"].repository_url
    aws_load_balancer_controller = aws_ecr_repository.service["bootstrap-aws-load-balancer-controller"].repository_url
  }
}
