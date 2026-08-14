data "terraform_remote_state" "account_baseline" {
  backend = "s3"

  config = {
    bucket = "ktcloud4-bean-opentofu-state-465137780685"
    key    = "platform/infra/aws/tofu-account-baseline/v1/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "app_network" {
  backend = "s3"

  config = {
    bucket = "ktcloud4-bean-opentofu-state-465137780685"
    key    = "platform/infra/aws/tofu-app-network/v1/terraform.tfstate"
    region = var.aws_region
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_vpc" "default" {
  default = true
}

data "aws_rds_cluster" "hr" {
  cluster_identifier = "${local.name_prefix}-aurora"
}

locals {
  name_prefix                 = "${var.project_name}-${var.environment}"
  aurora_postgresql_log_group = "/aws/rds/cluster/${data.aws_rds_cluster.hr.cluster_identifier}/postgresql"
  security_alerts_topic_arn   = data.terraform_remote_state.account_baseline.outputs.security_alerts_topic_arn
  cloudtrail_arn              = data.terraform_remote_state.account_baseline.outputs.cloudtrail_arn
  cloudtrail_log_group_name   = data.terraform_remote_state.account_baseline.outputs.cloudtrail_log_group_name
  access_analyzer_arn         = data.terraform_remote_state.account_baseline.outputs.access_analyzer_arn
  # Security Lake(AWS-SEC-01)가 소유·생성한 Glue database다. 이 root는
  # Lake Formation 권한을 소비할 뿐 database를 resource나 state로 소유하지 않는다.
  security_lake_database_name = "amazon_security_lake_glue_db_${replace(var.aws_region, "-", "_")}"
}
