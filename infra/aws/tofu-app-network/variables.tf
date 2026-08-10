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
  default     = "hr-system"
}

variable "environment" {
  description = "환경 배포 명칭"
  type        = string
  default     = "prod"
}

variable "private_app_subnet_cidrs" {
  description = "10.20 shared VPC 안의 HR 전용 프라이빗 앱 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.20.10.0/24", "10.20.20.0/24"]
}

variable "private_db_subnet_cidrs" {
  description = "10.20 shared VPC 안의 HR 전용 프라이빗 DB 서브넷 CIDR 목록"
  type        = list(string)
  default     = ["10.20.100.0/24", "10.20.110.0/24"]
}

variable "onprem_management_cidr" {
  description = "EKS private API와 internal ALB에 접근하는 Pomerium/Argo 관리 대역. docs/ip-plan.md의 PLATFORM VLAN 하나로만 제한한다."
  type        = string
  default     = "10.10.20.0/24"

  validation {
    condition     = can(cidrhost(var.onprem_management_cidr, 0))
    error_message = "onprem_management_cidr는 올바른 IPv4 CIDR이어야 한다."
  }
}
