variable "aws_account_id" {
  description = "적용 대상 AWS 계정 ID. 저장소 밖 tfvars로만 주입하며 provider account guard에 사용한다."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id는 12자리 숫자여야 한다."
  }
}

variable "aws_region" {
  description = "Vault auto-unseal KMS key의 region. 공인 AWS API endpoint를 사용한다."
  type        = string
  default     = "ap-northeast-2"

  validation {
    condition     = var.aws_region == "ap-northeast-2"
    error_message = "KMS-01은 기존 AWS 자원과 같은 ap-northeast-2만 사용한다."
  }
}

variable "enable_vault_kms_access" {
  description = "KMS 장애 시험용 gate. false면 Vault service user의 유일한 KMS inline policy만 회수한다."
  type        = bool
  default     = true
}
