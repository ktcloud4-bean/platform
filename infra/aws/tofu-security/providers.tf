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

# IAM은 글로벌 서비스라 AttachRolePolicy 관리 이벤트가 CloudTrail을 거쳐 EventBridge
# 기본 버스로 갈 때 항상 us-east-1에만 도착한다(project-c에서 실측 확인된 사실 -
# ap-northeast-2에 규칙을 두면 AWS/Events Invocations 지표가 0으로 전혀 매칭 안 됨).
# 44-iam-boundary-violation-watch.tf가 이 alias로 EventBridge 규칙+감시 Lambda를
# us-east-1에 배포한다.
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
