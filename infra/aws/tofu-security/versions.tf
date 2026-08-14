terraform {
  required_version = "~> 1.12"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.56.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.2"
    }
  }

  backend "s3" {
    bucket         = "ktcloud4-bean-opentofu-state-465137780685"
    key            = "platform/infra/aws/tofu-app-security/v1/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "ktcloud4-bean-opentofu-locks"
    encrypt        = true
  }
}
