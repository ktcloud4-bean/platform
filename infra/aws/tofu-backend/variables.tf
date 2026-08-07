variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_account_id" {
  description = "AWS 계정 ID (선택)"
  type        = string
  default     = ""
}

variable "project_name" {
  description = "프로젝트 명칭"
  type        = string
  default     = "demo-project"
}

variable "environment" {
  description = "환경 배포 명칭"
  type        = string
  default     = "dev"
}

variable "bucket_name_override" {
  description = "tfstate S3 버킷 명칭 (선택 지정)"
  type        = string
  default     = ""
}

variable "dynamodb_table_name_override" {
  description = "DynamoDB Lock 테이블 명칭 (선택 지정)"
  type        = string
  default     = ""
}
