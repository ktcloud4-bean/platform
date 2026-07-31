# AWS 자격증명은 이 저장소에 두지 않는다.
# 관리자 자격증명은 AWS CLI profile 또는 표준 환경변수로만 주입한다.
provider "aws" {
  region = var.aws_region

  # 잘못된 계정에 적용하는 사고를 provider 단계에서 막는다.
  # 실제 계정과 다르면 plan이 실패한다.
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      ManagedBy = "opentofu"
      Repo      = "ktcloud4-bean/platform"
      Task      = "AWS-NET-01"
      Purpose   = "site-to-site-vpn"
    }
  }
}
