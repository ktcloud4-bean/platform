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

variable "ciem_unused_access_age_days" {
  description = "IAM Access Analyzer 미사용 접근 분석 기준 일수"
  type        = number
  default     = 90

  validation {
    condition     = var.ciem_unused_access_age_days == 90
    error_message = "AWS-SEC-03의 미사용 접근 분석 기준은 90일이다."
  }
}

variable "ciem_drift_lookback_days" {
  description = "SAML reader role 권한 드리프트 관찰 기간(일)"
  type        = number
  default     = 30

  validation {
    condition     = var.ciem_drift_lookback_days >= 30
    error_message = "저빈도 정상 업무의 오탐을 줄이기 위해 관찰 기간은 30일 이상이어야 한다."
  }
}

variable "slack_channel_id" {
  description = "CIEM 알림을 수신할 Slack channel ID. 비어 있으면 알림 Lambda는 fail closed한다."
  type        = string
  default     = ""
}

variable "slack_allowed_user_ids" {
  description = "CIEM 파괴적 버튼을 승인할 Slack 사용자 ID allowlist. 비어 있으면 모두 거부한다."
  type        = set(string)
  default     = []
}

variable "slack_app_secret_name" {
  description = "수동 주입 Slack bot_token/signing_secret을 보관할 Secrets Manager 이름"
  type        = string
  default     = "hr-system-prod-ciem-slack-app"
}

variable "keycloak_session_secret_name" {
  description = "수동 주입 Keycloak CIEM service client 자격증명을 보관할 Secrets Manager 이름"
  type        = string
  default     = "hr-system-prod-ciem-keycloak-session"
}

variable "keycloak_realm_name" {
  description = "세션 종료 대상 Keycloak realm"
  type        = string
  default     = "platform"
}

variable "keycloak_hostname" {
  description = "TLS SNI와 Host header에 사용할 Keycloak canonical hostname"
  type        = string
  default     = "sso.imcherry5778.xyz"
}

variable "keycloak_connect_ip" {
  description = "VGW를 통해 Keycloak ingress로 연결할 사설 IPv4 주소"
  type        = string
  default     = "10.10.20.10"

  validation {
    condition     = can(cidrhost("${var.keycloak_connect_ip}/32", 0))
    error_message = "keycloak_connect_ip는 올바른 IPv4 주소여야 한다."
  }
}
