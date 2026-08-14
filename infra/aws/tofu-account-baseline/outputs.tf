output "security_alerts_topic_arn" {
  value = aws_sns_topic.security_alerts.arn
}

output "cloudtrail_arn" {
  value = aws_cloudtrail.main.arn
}

output "cloudtrail_log_group_name" {
  value = aws_cloudwatch_log_group.cloudtrail.name
}

output "access_analyzer_arn" {
  value = aws_accessanalyzer_analyzer.main.arn
}

output "security_lake_arn" {
  value = var.enable_security_lake ? aws_securitylake_data_lake.main[0].arn : null
}
