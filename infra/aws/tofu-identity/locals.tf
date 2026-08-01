locals {
  provider_arn = "arn:aws:iam::${var.aws_account_id}:saml-provider/${var.saml_provider_name}"

  role_names = {
    observer        = "platform-saml-observer"
    identity_reader = "platform-saml-identity-reader"
  }

  role_arns = {
    for key, name in local.role_names : key => "arn:aws:iam::${var.aws_account_id}:role/${name}"
  }

  # AWS trust의 SAML:aud context key는 Assertion Audience가 아니라
  # SubjectConfirmationData Recipient에서 파생된다. Keycloak client의 서울 ACS와
  # 정확히 같은 값으로 고정해 다른 AWS sign-in endpoint를 통한 assume을 막는다.
  aws_console_recipient = "https://ap-northeast-2.signin.aws.amazon.com/saml"
}
