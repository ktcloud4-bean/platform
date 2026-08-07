data "aws_caller_identity" "current" {}

locals {
  name_prefix         = "${var.project_name}-${var.environment}"
  bucket_name         = var.bucket_name_override != "" ? var.bucket_name_override : "ktcloud4-bean-opentofu-state-${data.aws_caller_identity.current.account_id}"
  dynamodb_table_name = var.dynamodb_table_name_override != "" ? var.dynamodb_table_name_override : "ktcloud4-bean-opentofu-locks"
}
