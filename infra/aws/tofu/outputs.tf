output "offsite_bucket" {
  description = "오프사이트 사본 bucket 이름."
  value       = aws_s3_bucket.offsite.id
}

output "offsite_bucket_region" {
  description = "bucket이 있는 region. rclone remote 설정에 그대로 쓴다."
  value       = aws_s3_bucket.offsite.region
}

output "heartbeat_prefix" {
  description = "오프사이트 job이 매 실행마다 쓰는 liveness object prefix."
  value       = local.heartbeat_prefix
}

output "source_copy_prefix" {
  description = "로컬 bucket 사본이 들어가는 prefix."
  value       = local.source_copy_prefix
}

output "alert_topic_arn" {
  description = "실패 경보 SNS topic ARN."
  value       = aws_sns_topic.alert.arn
}

output "alert_subscription_pending" {
  description = "email 구독이 아직 확인되지 않았는지 여부. true면 경보가 전달되지 않는다."
  value       = length(aws_sns_topic_subscription.alert_email) > 0 ? aws_sns_topic_subscription.alert_email[0].pending_confirmation : null
}

output "heartbeat_metric" {
  description = "heartbeat metric의 namespace와 이름."
  value = {
    namespace = var.heartbeat_metric_namespace
    name      = var.heartbeat_metric_name
  }
}

output "backup_user_arn" {
  description = "오프사이트 전송 전용 IAM user ARN."
  value       = aws_iam_user.backup.arn
}

output "backup_access_key_id" {
  description = "전송용 access key ID. secret이 아니다."
  value       = var.create_backup_access_key ? aws_iam_access_key.backup[0].id : null
}

output "backup_secret_access_key" {
  description = "전송용 secret access key. 저장소 밖 mode 0600 파일로만 회수한다."
  value       = var.create_backup_access_key ? aws_iam_access_key.backup[0].secret : null
  sensitive   = true
}
