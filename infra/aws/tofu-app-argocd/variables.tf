variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "execution_role_arn" {
  description = "administrator OpenTofu가 AssumeRole할 ARN. 빈 값이면 현재 caller를 쓴다."
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
