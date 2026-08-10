provider "aws" {
  region = var.aws_region

  dynamic "assume_role" {
    for_each = var.execution_role_arn != "" ? [var.execution_role_arn] : []
    content {
      role_arn     = assume_role.value
      session_name = "opentofu-${local.name_prefix}-argocd"
    }
  }

  default_tags {
    tags = {
      ManagedBy   = "opentofu"
      Repo        = "ktcloud4-bean/platform"
      Project     = var.project_name
      Environment = var.environment
      Component   = "argocd-eks-access"
    }
  }
}
