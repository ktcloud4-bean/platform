locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # tofu-identity(로컬 backend, 이 root와 state 공유 안 함)와 동일한 결정론적
  # 네이밍을 그대로 재현한다 - remote_state로 안 당겨오는 이유는 tofu-identity의
  # backend "local" 설계 자체가 "다른 AWS root와 state를 절대 공유하지 않는다"는
  # 원칙이기 때문(tofu-identity/versions.tf 주석 참고). 이름이 결정론적이라
  # 굳이 state를 공유하지 않아도 ARN을 그대로 계산할 수 있다.
  saml_role_names = {
    observer              = "platform-saml-observer"
    observability_reader  = "platform-saml-observability-reader"
    security_reader       = "platform-saml-security-reader"
    identity_reader       = "platform-saml-identity-reader"
  }
  saml_role_arns = {
    for k, name in local.saml_role_names : k => "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/${name}"
  }
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}
