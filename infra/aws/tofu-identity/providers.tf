provider "aws" {
  region = var.aws_region

  # provider 단계에서 잘못된 계정의 plan/apply를 막는다.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      ManagedBy = "opentofu"
      Repo      = "ktcloud4-bean/platform"
      Task      = "AWS-ID-01"
      Purpose   = "keycloak-saml-console-federation"
    }
  }
}
