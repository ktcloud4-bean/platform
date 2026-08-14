variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}
variable "aws_account_id" {
  description = "적용을 허용할 AWS 계정 ID"
  type        = string
  default     = ""
}

variable "execution_role_arn" {
  description = "선택적 OpenTofu AssumeRole ARN"
  type        = string
  default     = ""
}

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
  default     = "hr-system"
}

variable "environment" {
  description = "환경 이름"
  type        = string
  default     = "prod"
}

variable "rds_audit_worm_retention_days" {
  description = "RDS 감사 객체의 Object Lock COMPLIANCE 보존 기간(일)"
  type        = number
  default     = 4

  validation {
    condition     = var.rds_audit_worm_retention_days == 4
    error_message = "AWS-SEC-02의 ADR 확정 COMPLIANCE 보존 기간은 4일이다."
  }
}

variable "rds_audit_transition_days" {
  description = "RDS 감사 객체의 Glacier Deep Archive 전환일"
  type        = number
  default     = 30

  validation {
    condition     = var.rds_audit_transition_days == 30
    error_message = "AWS-SEC-02의 ADR 확정 transition은 30일이다."
  }
}

variable "rds_audit_expiration_days" {
  description = "RDS 감사 객체의 만료일"
  type        = number
  default     = 210

  validation {
    condition     = var.rds_audit_expiration_days == 210
    error_message = "AWS-SEC-02의 ADR 확정 expiration은 210일이다."
  }
}

variable "flow_log_retention_days" {
  description = "HR/default VPC REJECT Flow Log CloudWatch 보존일"
  type        = number
  default     = 30
}

variable "athena_results_expiration_days" {
  description = "Grafana Athena query result 보존일"
  type        = number
  default     = 30
}

variable "keycloak_saml_metadata_file" {
  description = "저장소 밖 Keycloak platform realm SAML metadata XML의 절대 경로"
  type        = string
}

variable "grafana_admin_role_values" {
  description = "Keycloak SAML role assertion에서 Managed Grafana Admin이 될 값"
  type        = list(string)
  default     = ["platform-privileged"]
}

variable "grafana_editor_role_values" {
  description = "Keycloak SAML role assertion에서 Managed Grafana Editor가 될 값"
  type        = list(string)
  default     = ["grafana-amg-editors"]
}
