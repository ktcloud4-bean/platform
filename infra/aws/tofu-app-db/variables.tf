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

variable "aurora_min_acu" {
  description = "Aurora Serverless v2 최소 ACU"
  type        = number
  default     = 0.5

  validation {
    condition     = var.aurora_min_acu >= 0.5 && var.aurora_min_acu <= 4
    error_message = "aurora_min_acu는 Free Tier Aurora Serverless 범위인 0.5~4 ACU여야 한다."
  }
}

variable "aurora_max_acu" {
  description = "Aurora Serverless v2 최대 ACU"
  type        = number
  default     = 4

  validation {
    condition     = var.aurora_max_acu >= 0.5 && var.aurora_max_acu <= 4
    error_message = "aurora_max_acu는 Free Tier Aurora Serverless 범위인 0.5~4 ACU여야 한다."
  }

  validation {
    condition     = var.aurora_max_acu >= var.aurora_min_acu
    error_message = "aurora_max_acu는 aurora_min_acu보다 작을 수 없다."
  }
}

variable "db_name" {
  description = "생성할 데이터베이스 이름"
  type        = string
  default     = "hr_system"
}

variable "db_username" {
  description = "RDS managed master 사용자명. 서비스 계정과 공유하지 않는다."
  type        = string
  default     = "hr_platform_admin"
}

variable "backup_retention_days" {
  description = "자동 백업 보존 일수"
  type        = number
  default     = 7

  validation {
    condition     = var.backup_retention_days >= 7 && var.backup_retention_days <= 35
    error_message = "backup_retention_days는 7~35일 사이여야 한다."
  }
}

variable "final_snapshot_identifier" {
  description = "RDS 폐기 시 보존할 final snapshot 식별자. 기존 snapshot과 겹치지 않는 외부 입력을 사용한다."
  type        = string
  default     = "hr-system-prod-postgres-final"
}

variable "bootstrap_hr_admin_email" {
  description = "초기 HR 관리자 이메일. 저장소 밖 mode 0600 tfvars로만 주입하며 AWS Secrets Manager에 보관한다."
  type        = string
  sensitive   = true

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.bootstrap_hr_admin_email))
    error_message = "bootstrap_hr_admin_email은 올바른 이메일 주소여야 한다."
  }
}
