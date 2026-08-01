variable "aws_account_id" {
  description = "적용 대상 AWS 계정 ID. 저장소 밖 tfvars로만 주입하며 provider 계정 guard에 사용한다."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id는 12자리 숫자여야 한다."
  }
}

variable "aws_region" {
  description = "AWS IAM은 전역 자원이지만 provider 일관성을 위해 Seoul region을 명시한다."
  type        = string
  default     = "ap-northeast-2"
}

variable "saml_metadata_file" {
  description = "Keycloak platform realm의 현재 SAML IdP metadata XML을 저장소 밖 mode 0600 경로에 둔 파일."
  type        = string

  validation {
    condition     = can(file(var.saml_metadata_file)) && length(trimspace(file(var.saml_metadata_file))) > 0
    error_message = "saml_metadata_file은 비어 있지 않은 읽기 가능한 저장소 밖 XML 파일이어야 한다."
  }
}

variable "saml_provider_name" {
  description = "이 root만 소유하는 IAM SAML provider 이름. Keycloak reconcile와 이름을 고정해 기존 provider를 import하거나 재사용하지 않는다."
  type        = string
  default     = "keycloak-platform"

  validation {
    condition     = var.saml_provider_name == "keycloak-platform"
    error_message = "AWS-ID-01은 기존 provider 재사용을 막기 위해 saml_provider_name을 keycloak-platform으로 고정한다."
  }
}

variable "console_session_duration_seconds" {
  description = "Keycloak SAML SessionDuration mapper가 AWS 콘솔에 요청할 임시 세션 시간(초). 15분으로 고정한다."
  type        = number
  default     = 900

  validation {
    condition     = var.console_session_duration_seconds == 900
    error_message = "AWS-ID-01은 만료 실증을 위해 SessionDuration을 900초(15분)로만 허용한다."
  }
}
