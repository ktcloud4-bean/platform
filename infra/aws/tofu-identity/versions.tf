terraform {
  # 이 root는 기존 backup/VPN root와 같은 OpenTofu 계열을 쓴다.
  required_version = "~> 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.56.0"
    }
  }

  # 이 state는 SAML IdP metadata와 IAM role ARN을 포함한다. path는 저장소에 고정하지
  # 않고 `tofu init -backend-config=path=...`로 외부 mode 0600 파일만 받는다.
  # 다른 AWS root와 state를 절대 공유하지 않는다.
  backend "local" {}
}
