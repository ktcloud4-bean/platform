terraform {
  required_version = "~> 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.56.0"
    }
  }

  # PSK가 state에 들어갈 수 있으므로 Jenkins가 읽지 않는 별도 v1 key를 쓴다.
  backend "s3" {
    bucket         = "ktcloud4-bean-opentofu-state-465137780685"
    key            = "platform/infra/aws/tofu-app-vpn/v1/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "ktcloud4-bean-opentofu-locks"
    encrypt        = true
  }
}
