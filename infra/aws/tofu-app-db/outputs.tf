output "aurora_writer_endpoint" {
  description = "Aurora writer cluster 엔드포인트"
  value       = aws_rds_cluster.main.endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora reader cluster 엔드포인트"
  value       = aws_rds_cluster.main.reader_endpoint
}

output "aurora_db_name" {
  description = "Aurora 데이터베이스 이름"
  value       = aws_rds_cluster.main.database_name
}

output "aurora_master_user_secret_arn" {
  description = "AWS가 관리하는 Aurora master credential secret ARN. migration Job만 읽는다."
  value       = aws_rds_cluster.main.master_user_secret[0].secret_arn
}

output "employee_service_database_secret_arn" {
  description = "Employee service가 IRSA로 읽는 DB credential secret ARN"
  value       = aws_secretsmanager_secret.employee_service_database.arn
}

output "hr_service_database_secret_arn" {
  description = "HR service가 IRSA로 읽는 DB credential secret ARN"
  value       = aws_secretsmanager_secret.hr_service_database.arn
}

output "bootstrap_hr_admin_secret_arn" {
  description = "초기 HR 관리자 이메일 secret ARN. migration Job만 읽는다."
  value       = aws_secretsmanager_secret.bootstrap_hr_admin.arn
}
