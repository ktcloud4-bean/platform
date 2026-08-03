provider "aws" {
  region = var.aws_region

  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      ManagedBy = "opentofu"
      Repo      = "ktcloud4-bean/platform"
      Task      = "KMS-01"
      Purpose   = "vault-auto-unseal"
    }
  }
}
