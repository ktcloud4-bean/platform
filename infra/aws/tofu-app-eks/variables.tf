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

variable "private_app_subnet_ids" {
  description = "프라이빗 앱 서브넷 ID 목록"
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID 목록"
  type        = list(string)
}

variable "eks_cluster_version" {
  description = "EKS 쿠버네티스 버전"
  type        = string
  default     = "1.30"
}

variable "eks_node_instance_type" {
  description = "EKS 노드 EC2 인스턴스 타입"
  type        = string
  default     = "t3.small"
}

variable "eks_node_desired_size" {
  description = "기본 노드 수"
  type        = number
  default     = 2
}

variable "eks_node_min_size" {
  description = "최소 노드 수"
  type        = number
  default     = 1
}

variable "eks_node_max_size" {
  description = "최대 노드 수"
  type        = number
  default     = 4
}

variable "eks_public_access_cidrs" {
  description = "EKS 컨트롤 플레인 API 허용 CIDR 목록"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
