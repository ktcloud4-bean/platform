variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_account_id" {
  description = "적용을 허용할 AWS account ID. 빈 값이면 current caller만 사용한다."
  type        = string
  default     = ""
}

variable "execution_role_arn" {
  description = "administrator OpenTofu가 AssumeRole할 ARN. 빈 값이면 현재 caller를 쓴다."
  type        = string
  default     = ""
}

variable "internal_alb_name" {
  description = "AWS Load Balancer Controller가 Ingress에서 만드는 internal ALB name"
  type        = string
  default     = "hr-system-prod"
}

variable "internal_alb_record_name" {
  description = "Pomerium이 사용하는 private hosted zone의 stable ALB alias label"
  type        = string
  default     = "hr-system.alb"
}
