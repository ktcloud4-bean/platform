output "argocd_credential_issuer_user_name" {
  description = "Vault runtime access key를 발급할 전용 IAM user. key secret은 OpenTofu state에 저장하지 않는다."
  value       = aws_iam_user.argocd_credential_issuer.name
}

output "argocd_credential_issuer_user_arn" {
  description = "Argo CD source IAM user ARN"
  value       = aws_iam_user.argocd_credential_issuer.arn
}

output "argocd_eks_role_arn" {
  description = "argocd-k8s-auth가 AssumeRole할 private EKS target role ARN"
  value       = aws_iam_role.argocd_eks.arn
}
