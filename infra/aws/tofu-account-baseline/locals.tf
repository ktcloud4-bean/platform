locals {
  name_prefix = "${var.project_name}-${var.environment}"

  alerting_enabled = var.alert_email != ""
  chatbot_enabled  = var.slack_workspace_id != "" && var.slack_channel_id != ""
}

data "aws_caller_identity" "current" {}
