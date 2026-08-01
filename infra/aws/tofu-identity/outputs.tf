output "keycloak_saml_provider_arn" {
  description = "Keycloak SAML client reconcile에만 전달할 provider ARN. 계정 ID 노출을 막기 위해 sensitive로 둔다."
  value       = aws_iam_saml_provider.keycloak_platform.arn
  sensitive   = true
}

output "keycloak_saml_role_arns" {
  description = "Keycloak SAML role-name mapper에만 전달할 role ARN. 화면이나 Git에 출력하지 않는다."
  value       = local.role_arns
  sensitive   = true
}

output "console_session_duration_seconds" {
  description = "SAML mapper가 요청하는 AWS 콘솔 임시 세션 시간(초)."
  value       = var.console_session_duration_seconds
}
