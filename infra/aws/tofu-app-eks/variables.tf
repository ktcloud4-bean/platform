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

variable "eks_cluster_version" {
  description = "EKS 쿠버네티스 버전"
  type        = string
  default     = "1.36"
}

variable "eks_node_instance_type" {
  description = "EKS 노드 EC2 인스턴스 타입"
  type        = string
  default     = "t3.medium"
}

variable "eks_node_desired_size" {
  description = "기본 노드 수"
  type        = number
  default     = 2
}

variable "eks_node_min_size" {
  description = "최소 노드 수"
  type        = number
  default     = 2
}

variable "eks_node_max_size" {
  description = "최대 노드 수"
  type        = number
  default     = 4
}

variable "admin_principal_arns" {
  description = "EKS access API로 administrator policy를 받을 AWS IAM principal ARN 목록. 빈 목록이면 cluster creator만 bootstrap admin이다."
  type        = set(string)
  default     = []
}
