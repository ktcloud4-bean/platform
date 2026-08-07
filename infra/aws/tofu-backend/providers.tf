provider "aws" {
  region              = var.aws_region
  allowed_account_ids = var.aws_account_id != "" ? [var.aws_account_id] : null

  default_tags {
    tags = {
      ManagedBy   = "opentofu"
      Repo        = "ktcloud4-bean/platform"
      Project     = var.project_name
      Environment = var.environment
      Component   = "tfstate-backend"
    }
  }
}
