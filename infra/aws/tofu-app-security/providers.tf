provider "aws" {
  region              = var.aws_region
  allowed_account_ids = var.aws_account_id != "" ? [var.aws_account_id] : null

  dynamic "assume_role" {
    for_each = var.execution_role_arn != "" ? [var.execution_role_arn] : []
    content {
      role_arn     = assume_role.value
      session_name = "OpenTofu-Session"
    }
  }

  default_tags {
    tags = {
      ManagedBy   = "opentofu"
      Repo        = "ktcloud4-bean/platform"
      Project     = var.project_name
      Environment = var.environment
      Component   = "app-security"
    }
  }
}

# IAM의 전역 관리 이벤트는 CloudTrail을 통해 us-east-1 EventBridge 기본 버스로
# 전달된다. 이 별칭은 AttachRolePolicy 경계 위반 감시에만 사용한다.
provider "aws" {
  alias               = "us_east_1"
  region              = "us-east-1"
  allowed_account_ids = var.aws_account_id != "" ? [var.aws_account_id] : null

  dynamic "assume_role" {
    for_each = var.execution_role_arn != "" ? [var.execution_role_arn] : []
    content {
      role_arn     = assume_role.value
      session_name = "OpenTofu-Session"
    }
  }

  default_tags {
    tags = {
      ManagedBy   = "opentofu"
      Repo        = "ktcloud4-bean/platform"
      Project     = var.project_name
      Environment = var.environment
      Component   = "app-security"
    }
  }
}
