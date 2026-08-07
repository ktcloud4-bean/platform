terraform {
  required_version = "~> 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.56.0"
    }
  }

  backend "s3" {
    bucket         = "ktcloud4-bean-opentofu-state-465137780685"
    key            = "platform/infra/aws/tofu-app-network/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "ktcloud4-bean-opentofu-locks"
    encrypt        = true
  }
}
