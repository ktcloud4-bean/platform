output "tfstate_bucket_name" {
  description = "OpenTofu Remote State S3 버킷 이름"
  value       = aws_s3_bucket.tfstate.id
}

output "tfstate_bucket_arn" {
  description = "OpenTofu Remote State S3 버킷 ARN"
  value       = aws_s3_bucket.tfstate.arn
}

output "dynamodb_table_name" {
  description = "OpenTofu State Lock DynamoDB 테이블 이름"
  value       = aws_dynamodb_table.locks.name
}
