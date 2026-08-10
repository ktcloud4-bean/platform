terraform {
  required_version = "~> 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.56.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }

  backend "s3" {
    bucket         = "ktcloud4-bean-opentofu-state-465137780685"
    key            = "platform/infra/aws/tofu-app-db/v1/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "ktcloud4-bean-opentofu-locks"
    encrypt        = true
  }
}
