variable "aws_account_id" {
  description = "적용 대상 AWS account ID. provider 계정 guard에 쓴다."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id는 12자리 숫자여야 한다."
  }
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-northeast-2"
}

variable "execution_role_arn" {
  description = "administrator OpenTofu가 AssumeRole할 ARN. 빈 값이면 현재 caller를 쓴다."
  type        = string
  default     = ""
}

variable "onprem_management_cidr" {
  description = "Pomerium/Argo와 OPNsense Resolver가 있는 PLATFORM VLAN. HR private subnet의 on-prem return route에만 적용한다."
  type        = string
  default     = "10.10.20.0/24"

  validation {
    condition     = can(cidrhost(var.onprem_management_cidr, 0))
    error_message = "onprem_management_cidr는 올바른 IPv4 CIDR이어야 한다."
  }
}
