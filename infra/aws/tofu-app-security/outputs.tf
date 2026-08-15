output "rds_audit_worm_bucket" {
  description = "RDS PostgreSQL 감사 로그의 Object Lock COMPLIANCE bucket"
  value       = aws_s3_bucket.rds_audit_worm.id
}

output "grafana_workspace_endpoint" {
  description = "Keycloak SAML client ACS 등록에만 사용할 Managed Grafana endpoint"
  value       = aws_grafana_workspace.soc.endpoint
  sensitive   = true
}

output "grafana_workspace_id" {
  description = "Managed Grafana workspace ID"
  value       = aws_grafana_workspace.soc.id
  sensitive   = true
}

output "athena_workgroup_name" {
  description = "Security Lake Athena query에 사용할 전용 workgroup"
  value       = aws_athena_workgroup.grafana.name
}

output "account_baseline_contract" {
  description = "AWS-SEC-01 remote state 네 output의 읽기 계약 확인용"
  value = {
    security_alerts_topic_arn = local.security_alerts_topic_arn
    cloudtrail_arn            = local.cloudtrail_arn
    cloudtrail_log_group_name = local.cloudtrail_log_group_name
    access_analyzer_arn       = local.access_analyzer_arn
  }
  sensitive = true
}

output "demo_saml_role_arn" {
  description = "AWS-SEC-04 격리 데모 SAML role ARN"
  value       = aws_iam_role.demo_saml.arn
}

output "demo_saml_role_name" {
  description = "AWS-SEC-04 격리 데모 SAML role 이름"
  value       = aws_iam_role.demo_saml.name
}

output "asr_stack_id" {
  description = "ASR admin CloudFormation stack ID"
  value       = var.enable_asr_remediation ? aws_cloudformation_stack.asr[0].id : "disabled"
}

output "asr_member_roles_stack_id" {
  description = "ASR member-roles CloudFormation stack ID"
  value       = var.enable_asr_remediation ? aws_cloudformation_stack.asr_member_roles[0].id : "disabled"
}

output "asr_member_stack_id" {
  description = "ASR member CloudFormation stack ID"
  value       = var.enable_asr_remediation ? aws_cloudformation_stack.asr_member[0].id : "disabled"
}

output "asr_demo_target_sg_id" {
  description = "ASR 시연 전용 더미 보안그룹 ID (인스턴스 미부착)"
  value       = aws_security_group.asr_demo_target.id
}
