output "rds_endpoint" {
  description = "RDS 인스턴스 엔드포인트"
  value       = aws_db_instance.main.endpoint
}

output "rds_address" {
  description = "RDS 호스트 주소"
  value       = aws_db_instance.main.address
}

output "rds_db_name" {
  description = "RDS 데이터베이스 이름"
  value       = aws_db_instance.main.db_name
}
