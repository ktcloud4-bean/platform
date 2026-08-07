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
      Component   = "app-ecr"
    }
  }
}
