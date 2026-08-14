variable "aws_region" {
  type    = string
  default = "ap-northeast-2"
}

variable "aws_account_id" {
  type    = string
  default = ""
}

variable "execution_role_arn" {
  description = "선택적으로 assume할 AWS IAM role ARN"
  type        = string
  default     = ""
}

variable "project_name" {
  type    = string
  default = "hr-system"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "cloudtrail_name" {
  description = "AWS-SEC-01이 import해 소유할 기존 multi-region CloudTrail 이름"
  type        = string
  default     = "management-events"
}

variable "alert_email" {
  description = "예산·비용 이상 알림과 SECURITY alternate contact 수신 주소"
  type        = string
  default     = ""
}

variable "security_contact_name" {
  description = "AWS 계정 SECURITY alternate contact 이름"
  type        = string
  default     = ""
}

variable "security_contact_phone" {
  description = "AWS 계정 SECURITY alternate contact 전화번호"
  type        = string
  default     = ""
}

variable "slack_workspace_id" {
  description = "Amazon Q Developer in chat applications에 승인된 Slack workspace ID"
  type        = string
  default     = ""
}

variable "slack_channel_id" {
  description = "보안 알림을 수신할 Slack channel ID"
  type        = string
  default     = ""
}

variable "pagerduty_integration_url" {
  description = "선택적인 PagerDuty Events API endpoint"
  type        = string
  default     = ""
  sensitive   = true
}

variable "enable_cis_benchmark" {
  description = "Security Hub CIS 표준은 현재 FSBP와 별도로 비활성 유지한다."
  type        = bool
  default     = false
}

variable "enable_security_lake" {
  description = "Security Lake data lake와 VPC Flow/Security Hub finding source를 생성한다."
  type        = bool
  default     = true
}

variable "security_lake_retention_days" {
  type    = number
  default = 365

  validation {
    condition     = var.security_lake_retention_days > 30
    error_message = "security_lake_retention_days는 30일 transition보다 길어야 한다."
  }
}

variable "monthly_budget_amount" {
  type    = string
  default = "100"
}

variable "cost_anomaly_monitor_name" {
  description = "계정의 유일한 DIMENSIONAL Cost Explorer monitor. 기존 기본 monitor를 import해 사용한다."
  type        = string
  default     = "Default-Services-Monitor"
}
