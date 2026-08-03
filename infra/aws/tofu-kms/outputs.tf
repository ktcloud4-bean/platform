output "kms_alias" {
  description = "Vault seal stanza가 참조하는 고정 alias."
  value       = aws_kms_alias.vault_auto_unseal.name
}

output "kms_key_arn" {
  description = "정확한 IAM resource 대조용 KMS key ARN. 계정 ID를 포함하므로 화면에 출력하지 않는다."
  value       = aws_kms_key.vault_auto_unseal.arn
  sensitive   = true
}

output "vault_access_key_id" {
  description = "Vault auto-unseal 전용 access key ID. 화면에 출력하지 않는다."
  value       = aws_iam_access_key.vault_auto_unseal.id
  sensitive   = true
}

output "vault_secret_access_key" {
  description = "Vault auto-unseal 전용 secret access key. 화면에 출력하지 않는다."
  value       = aws_iam_access_key.vault_auto_unseal.secret
  sensitive   = true
}
