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

variable "execution_role_arn" {
  description = "AssumeRole할 AWS IAM Role ARN (선택)"
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

variable "private_db_subnet_ids" {
  description = "프라이빗 DB 서브넷 ID 목록"
  type        = list(string)
}

variable "rds_security_group_ids" {
  description = "RDS에 적용할 보안그룹 ID 목록"
  type        = list(string)
}

variable "db_instance_class" {
  description = "RDS 인스턴스 타입"
  type        = string
  default     = "db.t3.micro"
}

variable "multi_az_rds" {
  description = "Multi-AZ 여부"
  type        = bool
  default     = false
}

variable "db_name" {
  description = "생성할 데이터베이스 이름"
  type        = string
  default     = "demodb"
}

variable "db_username" {
  description = "DB 관리자 계정"
  type        = string
  default     = "adminuser"
}

variable "db_password" {
  description = "DB 관리자 비밀번호 (tfvars에서 주입)"
  type        = string
  sensitive   = true
}
