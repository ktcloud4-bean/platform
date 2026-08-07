output "ecr_frontend_repository_url" {
  description = "Frontend ECR 저장소 URL"
  value       = aws_ecr_repository.frontend.repository_url
}

output "ecr_backend_repository_url" {
  description = "Backend ECR 저장소 URL"
  value       = aws_ecr_repository.backend.repository_url
}
