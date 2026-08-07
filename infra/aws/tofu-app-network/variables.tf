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
  description = "환경 배포 명칭 (dev, prod)"
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "VPC CIDR 대역"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "퍼블릭 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_app_subnet_cidrs" {
  description = "프라이빗 앱 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.20.0/24"]
}

variable "private_db_subnet_cidrs" {
  description = "프라이빗 DB 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.0.100.0/24", "10.0.110.0/24"]
}

variable "single_nat_gateway" {
  description = "true면 NAT Gateway 1개만 사용, false면 AZ마다 1개"
  type        = bool
  default     = true
}
