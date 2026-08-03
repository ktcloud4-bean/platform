terraform {
  required_version = "~> 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.56.0"
    }
  }

  # KMS key와 IAM access key의 수명주기를 backup/VPN/SAML state와 분리한다.
  # 실제 path는 저장소 밖 mode 0600 파일을 가리키도록 init 때 주입한다.
  backend "local" {}
}
