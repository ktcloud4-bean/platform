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

variable "alert_email" {
  description = "예산/보안 경보를 받을 이메일"
  type        = string
}

variable "security_contact_name" {
  description = "Security Hub Account.1(계정 보안 연락처) - AWS Alternate Contact(SECURITY) 이름"
  type        = string
}

variable "security_contact_phone" {
  description = "Security Hub Account.1 - AWS Alternate Contact(SECURITY) 전화번호"
  type        = string
}

variable "enable_cis_benchmark" {
  description = "true면 Security Hub에서 CIS AWS Foundations Benchmark 표준도 FSBP와 함께 활성화"
  type        = bool
  default     = false
}

variable "monthly_budget_amount" {
  description = "월 예산 알림 기준 금액(USD)"
  type        = string
  default     = "100"
}

variable "rds_audit_worm_retention_days" {
  description = "RDS 감사로그 WORM 보존기간(일). S3 Object Lock이라 이 기간 동안 계정 소유자도 못 지움"
  type        = number
  default     = 365
}

variable "psycopg2_layer_arn" {
  description = "RDS 권한 드리프트 체크 Lambda용 psycopg2 Lambda Layer ARN"
  type        = string
  default     = ""
}

# --- Automated Security Response on AWS (ASR) ---
variable "enable_asr_remediation" {
  description = "ASR(Automated Security Response on AWS) 활성화 여부. Lambda 동시실행 할당량 이슈로 기본 false"
  type        = bool
  default     = false
}

variable "asr_template_url" {
  description = "ASR 관리자 CloudFormation 템플릿 URL"
  type        = string
  default     = "https://s3.amazonaws.com/solutions-reference/automated-security-response-on-aws/latest/automated-security-response-admin.template"
}

# --- CIEM 권한 드리프트 검사 (36) ---
variable "boundary_drift_lookback_hours" {
  description = "권한 드리프트 검사 시 CloudTrail을 몇 시간 거슬러 볼지"
  type        = number
  default     = 3
}

# --- Slack App (28, 36, 44 공용) ---
# 실제 Bot Token/Signing Secret은 apply 후 Secrets Manager 콘솔/CLI로 채운다
# (terraform.tfvars에 두지 않음 - tofu-identity의 SAML metadata와 같은 이유).

# --- CIEM 세션 강제 종료 (35) - 실제 온프레미스 Keycloak ---
variable "onprem_keycloak_host" {
  description = "온프레미스 Keycloak 접속 주소 (tofu-network VPN 경유)"
  type        = string
}

variable "keycloak_realm_name" {
  description = "Keycloak AWS SAML 연동 realm 이름 (tofu-identity의 saml_provider_name과 짝을 이루는 realm)"
  type        = string
  default     = "platform"
}

# --- Grafana (25, 템플릿은 project-c 그대로 유지) ---
variable "keycloak_test_users_password" {
  description = "Grafana 대시보드 프로비저닝 스크립트가 SAML 로그인에 쓸 계정 비밀번호"
  type        = string
  sensitive   = true
  default     = ""
}

variable "grafana_provisioning_user" {
  description = "grafana-dashboard-setup.sh가 SAML 로그인에 쓸 Keycloak 사용자명 - Grafana Admin 권한이 있는 실제 계정으로 채울 것"
  type        = string
  default     = ""
}

# Grafana 전용 SAML 클라이언트의 role 속성값 - Keycloak 그룹 이름과 정확히
# 일치해야 함(reconcile-keycloak-saml.sh가 관리하는 그룹과는 별개, Grafana
# 전용으로 새로 등록되는 클라이언트의 role 매퍼 그룹). 실제 그룹명을 모르면
# scripts/keycloak-grafana-saml-client.sh 실행 전에 먼저 채울 것.
variable "grafana_admin_role_values" {
  type    = list(string)
  default = []
}

variable "grafana_editor_role_values" {
  type    = list(string)
  default = []
}
