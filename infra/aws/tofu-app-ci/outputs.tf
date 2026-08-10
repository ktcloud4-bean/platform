output "jenkins_ecr_publisher_user_name" {
  description = "Jenkins ECR publisher IAM user name. Access key 원문은 OpenTofu state로 관리하지 않는다."
  value       = aws_iam_user.jenkins_ecr_publisher.name
}

output "jenkins_ecr_repository_names" {
  description = "publisher policy가 허용한 정확한 ECR repository"
  value       = sort([for repository in data.aws_ecr_repository.hr_images : repository.name])
}
