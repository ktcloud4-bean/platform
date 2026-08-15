# AWS-SEC-03 CIEM 조치 계층. Slack 서명값과 Keycloak service client 값은 이
# root가 생성만 하는 Secrets Manager 객체에 운영자가 별도로 주입한다. 어떤
# secret_version도 선언하지 않아 값이 OpenTofu state에 남지 않는다.

resource "aws_secretsmanager_secret" "ciem_slack_app" {
  name                    = var.slack_app_secret_name
  description             = "AWS-SEC-03 CIEM Slack bot/signing credentials; value is externally managed"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret" "ciem_keycloak_session" {
  name                    = var.keycloak_session_secret_name
  description             = "AWS-SEC-03 Keycloak session revocation service client; value is externally managed"
  recovery_window_in_days = 7
}

resource "aws_accessanalyzer_analyzer" "ciem_unused_access" {
  analyzer_name = "${local.name_prefix}-unused-access-analyzer"
  type          = "ACCOUNT_UNUSED_ACCESS"

  configuration {
    unused_access {
      unused_access_age = var.ciem_unused_access_age_days
    }
  }
}

resource "aws_dynamodb_table" "ciem_action_idempotency" {
  name         = "${local.name_prefix}-ciem-action-idempotency"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "action_key"

  attribute {
    name = "action_key"
    type = "S"
  }

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  server_side_encryption {
    enabled = true
  }
}

locals {
  ciem_lambda_log_groups = {
    unused_access_report = "/aws/lambda/${local.name_prefix}-ciem-unused-access-report"
    key_exception_notify = "/aws/lambda/${local.name_prefix}-ciem-key-exception-notify"
    callback             = "/aws/lambda/${local.name_prefix}-ciem-slack-callback"
    action_executor      = "/aws/lambda/${local.name_prefix}-ciem-action-executor"
    permission_drift     = "/aws/lambda/${local.name_prefix}-ciem-permission-drift"
    session_revoke       = "/aws/lambda/${local.name_prefix}-ciem-keycloak-session-revoke"
  }
}

resource "aws_cloudwatch_log_group" "ciem_lambda" {
  for_each          = local.ciem_lambda_log_groups
  name              = each.value
  retention_in_days = 30
}

data "archive_file" "ciem_unused_access_report" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem_unused_access_report.py"
  output_path = "${path.module}/scripts/ciem_unused_access_report.zip"
}

data "archive_file" "ciem_key_exception_notify" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem_key_exception_notify.py"
  output_path = "${path.module}/scripts/ciem_key_exception_notify.zip"
}

data "archive_file" "ciem_callback" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem_callback.py"
  output_path = "${path.module}/scripts/ciem_callback.zip"
}

data "archive_file" "ciem_action_executor" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem_action_executor.py"
  output_path = "${path.module}/scripts/ciem_action_executor.zip"
}

data "archive_file" "ciem_permission_drift" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem_permission_drift.py"
  output_path = "${path.module}/scripts/ciem_permission_drift.zip"
}

data "archive_file" "ciem_keycloak_session_revoke" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem_keycloak_session_revoke.py"
  output_path = "${path.module}/scripts/ciem_keycloak_session_revoke.zip"
}

data "aws_iam_policy_document" "ciem_lambda_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ciem_unused_access_report" {
  name               = "${local.name_prefix}-ciem-unused-access-report-role"
  assume_role_policy = data.aws_iam_policy_document.ciem_lambda_assume.json
}

resource "aws_iam_role" "ciem_key_exception_notify" {
  name               = "${local.name_prefix}-ciem-key-exception-notify-role"
  assume_role_policy = data.aws_iam_policy_document.ciem_lambda_assume.json
}

resource "aws_iam_role" "ciem_callback" {
  name               = "${local.name_prefix}-ciem-slack-callback-role"
  assume_role_policy = data.aws_iam_policy_document.ciem_lambda_assume.json
}

resource "aws_iam_role" "ciem_action_executor" {
  name               = "${local.name_prefix}-ciem-action-executor-role"
  assume_role_policy = data.aws_iam_policy_document.ciem_lambda_assume.json
}

resource "aws_iam_role" "ciem_permission_drift" {
  name               = "${local.name_prefix}-ciem-permission-drift-role"
  assume_role_policy = data.aws_iam_policy_document.ciem_lambda_assume.json
}

resource "aws_iam_role" "ciem_keycloak_session_revoke" {
  name               = "${local.name_prefix}-ciem-keycloak-session-revoke-role"
  assume_role_policy = data.aws_iam_policy_document.ciem_lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "ciem_basic_logs" {
  for_each = {
    unused_access_report = aws_iam_role.ciem_unused_access_report.name
    key_exception_notify = aws_iam_role.ciem_key_exception_notify.name
    callback             = aws_iam_role.ciem_callback.name
    action_executor      = aws_iam_role.ciem_action_executor.name
    permission_drift     = aws_iam_role.ciem_permission_drift.name
    session_revoke       = aws_iam_role.ciem_keycloak_session_revoke.name
  }

  role       = each.value
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "ciem_session_revoke_vpc" {
  role       = aws_iam_role.ciem_keycloak_session_revoke.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "ciem_unused_access_report" {
  statement {
    effect    = "Allow"
    actions   = ["access-analyzer:GetAnalyzer", "access-analyzer:ListFindingsV2"]
    resources = [aws_accessanalyzer_analyzer.ciem_unused_access.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [local.security_alerts_topic_arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = [data.aws_kms_alias.security_alerts.target_key_arn]
  }
}

resource "aws_iam_role_policy" "ciem_unused_access_report" {
  name   = "ciem-unused-access-report"
  role   = aws_iam_role.ciem_unused_access_report.id
  policy = data.aws_iam_policy_document.ciem_unused_access_report.json
}

data "aws_iam_policy_document" "ciem_key_exception_notify" {
  statement {
    effect    = "Allow"
    actions   = ["iam:GetAccessKeyLastUsed", "iam:ListAccessKeys", "iam:ListUserTags", "iam:ListUsers"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ciem_slack_app.arn]
  }
}

resource "aws_iam_role_policy" "ciem_key_exception_notify" {
  name   = "ciem-key-exception-notify"
  role   = aws_iam_role.ciem_key_exception_notify.id
  policy = data.aws_iam_policy_document.ciem_key_exception_notify.json
}

data "aws_iam_policy_document" "ciem_callback" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ciem_slack_app.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.ciem_action_executor.arn]
  }
}

resource "aws_iam_role_policy" "ciem_callback" {
  name   = "ciem-slack-callback"
  role   = aws_iam_role.ciem_callback.id
  policy = data.aws_iam_policy_document.ciem_callback.json
}

data "aws_iam_policy_document" "ciem_action_executor" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.ciem_action_idempotency.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["iam:DeleteAccessKey", "iam:DetachRolePolicy", "iam:PutRolePolicy", "iam:TagUser", "iam:UpdateAccessKey"]
    resources = concat(["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:user/*"], local.all_saml_role_arns)
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ciem_slack_app.arn, aws_secretsmanager_secret.ciem_keycloak_session.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.ciem_keycloak_session_revoke.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [local.security_alerts_topic_arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:GenerateDataKey*"]
    resources = [data.aws_kms_alias.security_alerts.target_key_arn]
  }
}

resource "aws_iam_role_policy" "ciem_action_executor" {
  name   = "ciem-action-executor"
  role   = aws_iam_role.ciem_action_executor.id
  policy = data.aws_iam_policy_document.ciem_action_executor.json
}

resource "aws_iam_role" "ciem_access_analyzer_cloudtrail" {
  name = "${local.name_prefix}-ciem-access-analyzer-cloudtrail-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "access-analyzer.amazonaws.com" }
    }]
  })
}

data "aws_iam_policy_document" "ciem_access_analyzer_cloudtrail" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket", "s3:GetObject"]
    resources = [local.cloudtrail_bucket_arn, "${local.cloudtrail_bucket_arn}/*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "cloudtrail:GetTrail",
      "cloudtrail:GetTrailStatus",
      "cloudtrail:ListTrails",
      "cloudtrail:DescribeTrails"
    ]
    resources = ["*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "iam:GenerateServiceLastAccessedDetails",
      "iam:GetServiceLastAccessedDetails"
    ]
    resources = ["*"]
  }
  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey"
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ciem_access_analyzer_cloudtrail" {
  name   = "ciem-cloudtrail-read"
  role   = aws_iam_role.ciem_access_analyzer_cloudtrail.id
  policy = data.aws_iam_policy_document.ciem_access_analyzer_cloudtrail.json
}

data "aws_iam_policy_document" "ciem_permission_drift" {
  statement {
    effect    = "Allow"
    actions   = ["access-analyzer:GetGeneratedPolicy", "access-analyzer:StartPolicyGeneration"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["iam:GetRolePolicy", "iam:ListRolePolicies"]
    resources = local.all_saml_role_arns
  }
  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ciem_access_analyzer_cloudtrail.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ciem_slack_app.arn]
  }
}

resource "aws_iam_role_policy" "ciem_permission_drift" {
  name   = "ciem-permission-drift"
  role   = aws_iam_role.ciem_permission_drift.id
  policy = data.aws_iam_policy_document.ciem_permission_drift.json
}

resource "aws_security_group" "ciem_keycloak_session_revoke" {
  name        = "${local.name_prefix}-ciem-keycloak-session-revoke-sg"
  description = "AWS-SEC-03 Keycloak session Lambda: VGW Keycloak HTTPS only"
  vpc_id      = data.terraform_remote_state.app_network.outputs.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "ciem_keycloak_session_revoke" {
  security_group_id = aws_security_group.ciem_keycloak_session_revoke.id
  description       = "Keycloak admin API over existing Site-to-Site VPN only"
  cidr_ipv4         = "${var.keycloak_connect_ip}/32"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_lambda_function" "ciem_unused_access_report" {
  function_name    = "${local.name_prefix}-ciem-unused-access-report"
  role             = aws_iam_role.ciem_unused_access_report.arn
  handler          = "ciem_unused_access_report.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.ciem_unused_access_report.output_path
  source_code_hash = data.archive_file.ciem_unused_access_report.output_base64sha256

  environment {
    variables = {
      ANALYZER_ARN  = aws_accessanalyzer_analyzer.ciem_unused_access.arn
      SNS_TOPIC_ARN = local.security_alerts_topic_arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.ciem_lambda["unused_access_report"]]
}

resource "aws_lambda_function" "ciem_key_exception_notify" {
  function_name    = "${local.name_prefix}-ciem-key-exception-notify"
  role             = aws_iam_role.ciem_key_exception_notify.arn
  handler          = "ciem_key_exception_notify.handler"
  runtime          = "python3.12"
  timeout          = 120
  filename         = data.archive_file.ciem_key_exception_notify.output_path
  source_code_hash = data.archive_file.ciem_key_exception_notify.output_base64sha256

  environment {
    variables = {
      SLACK_SECRET_ARN = aws_secretsmanager_secret.ciem_slack_app.arn
      SLACK_CHANNEL_ID = var.slack_channel_id
      UNUSED_DAYS      = tostring(var.ciem_unused_access_age_days)
    }
  }

  depends_on = [aws_cloudwatch_log_group.ciem_lambda["key_exception_notify"]]
}

resource "aws_lambda_function" "ciem_callback" {
  function_name    = "${local.name_prefix}-ciem-slack-callback"
  role             = aws_iam_role.ciem_callback.arn
  handler          = "ciem_callback.handler"
  runtime          = "python3.12"
  timeout          = 10
  filename         = data.archive_file.ciem_callback.output_path
  source_code_hash = data.archive_file.ciem_callback.output_base64sha256

  environment {
    variables = {
      SLACK_SECRET_ARN      = aws_secretsmanager_secret.ciem_slack_app.arn
      ALLOWED_USER_IDS_JSON = jsonencode(sort(tolist(var.slack_allowed_user_ids)))
      EXECUTOR_FUNCTION     = aws_lambda_function.ciem_action_executor.function_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.ciem_lambda["callback"]]
}

resource "aws_lambda_function" "ciem_action_executor" {
  function_name    = "${local.name_prefix}-ciem-action-executor"
  role             = aws_iam_role.ciem_action_executor.arn
  handler          = "ciem_action_executor.handler"
  runtime          = "python3.12"
  timeout          = 90
  filename         = data.archive_file.ciem_action_executor.output_path
  source_code_hash = data.archive_file.ciem_action_executor.output_base64sha256

  environment {
    variables = {
      ACTION_TABLE_NAME           = aws_dynamodb_table.ciem_action_idempotency.name
      SLACK_SECRET_ARN            = aws_secretsmanager_secret.ciem_slack_app.arn
      KEYCLOAK_SESSION_SECRET_ARN = aws_secretsmanager_secret.ciem_keycloak_session.arn
      KEYCLOAK_SESSION_FUNCTION   = aws_lambda_function.ciem_keycloak_session_revoke.function_name
      SNS_TOPIC_ARN               = local.security_alerts_topic_arn
      SAML_ROLE_NAMES_JSON        = jsonencode(local.all_saml_role_names)
    }
  }

  depends_on = [aws_cloudwatch_log_group.ciem_lambda["action_executor"]]
}

resource "aws_lambda_function" "ciem_permission_drift" {
  function_name    = "${local.name_prefix}-ciem-permission-drift"
  role             = aws_iam_role.ciem_permission_drift.arn
  handler          = "ciem_permission_drift.handler"
  runtime          = "python3.12"
  timeout          = 540
  filename         = data.archive_file.ciem_permission_drift.output_path
  source_code_hash = data.archive_file.ciem_permission_drift.output_base64sha256

  environment {
    variables = {
      CLOUDTRAIL_ARN           = local.cloudtrail_arn
      ACCESS_ANALYZER_ROLE_ARN = aws_iam_role.ciem_access_analyzer_cloudtrail.arn
      LOOKBACK_DAYS            = tostring(var.ciem_drift_lookback_days)
      SLACK_SECRET_ARN         = aws_secretsmanager_secret.ciem_slack_app.arn
      SLACK_CHANNEL_ID         = var.slack_channel_id
    }
  }

  depends_on = [aws_cloudwatch_log_group.ciem_lambda["permission_drift"]]
}

resource "aws_lambda_function" "ciem_keycloak_session_revoke" {
  function_name    = "${local.name_prefix}-ciem-keycloak-session-revoke"
  role             = aws_iam_role.ciem_keycloak_session_revoke.arn
  handler          = "ciem_keycloak_session_revoke.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.ciem_keycloak_session_revoke.output_path
  source_code_hash = data.archive_file.ciem_keycloak_session_revoke.output_base64sha256

  vpc_config {
    subnet_ids         = data.terraform_remote_state.app_network.outputs.private_app_subnet_ids
    security_group_ids = [aws_security_group.ciem_keycloak_session_revoke.id]
  }

  environment {
    variables = {
      KEYCLOAK_HOSTNAME   = var.keycloak_hostname
      KEYCLOAK_CONNECT_IP = var.keycloak_connect_ip
      KEYCLOAK_REALM      = var.keycloak_realm_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.ciem_lambda["session_revoke"]]
}

resource "aws_iam_role" "ciem_scheduler" {
  name = "${local.name_prefix}-ciem-scheduler-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ciem_scheduler" {
  name = "invoke-ciem-functions"
  role = aws_iam_role.ciem_scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = "lambda:InvokeFunction"
      Resource = [
        aws_lambda_function.ciem_unused_access_report.arn,
        aws_lambda_function.ciem_key_exception_notify.arn,
        aws_lambda_function.ciem_permission_drift.arn,
      ]
    }]
  })
}

resource "aws_scheduler_schedule" "ciem_unused_access_monthly" {
  name                         = "${local.name_prefix}-ciem-unused-access-monthly"
  group_name                   = "default"
  schedule_expression          = "cron(0 0 1 * ? *)"
  schedule_expression_timezone = "UTC"
  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_lambda_function.ciem_unused_access_report.arn
    role_arn = aws_iam_role.ciem_scheduler.arn
  }
}

resource "aws_scheduler_schedule" "ciem_key_exception_monthly" {
  name                         = "${local.name_prefix}-ciem-key-exception-monthly"
  group_name                   = "default"
  schedule_expression          = "cron(5 0 1 * ? *)"
  schedule_expression_timezone = "UTC"
  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_lambda_function.ciem_key_exception_notify.arn
    role_arn = aws_iam_role.ciem_scheduler.arn
  }
}

resource "aws_scheduler_schedule" "ciem_permission_drift_monthly" {
  for_each                     = local.saml_role_names
  name                         = "${local.name_prefix}-ciem-permission-drift-${each.key}"
  group_name                   = "default"
  schedule_expression          = "cron(10 0 1 * ? *)"
  schedule_expression_timezone = "UTC"
  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_lambda_function.ciem_permission_drift.arn
    role_arn = aws_iam_role.ciem_scheduler.arn
    input    = jsonencode({ role_name = each.value })
  }
}

resource "aws_lambda_permission" "ciem_scheduler_unused_access" {
  statement_id  = "AllowSchedulerUnusedAccess"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ciem_unused_access_report.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.ciem_unused_access_monthly.arn
}

resource "aws_lambda_permission" "ciem_scheduler_key_exception" {
  statement_id  = "AllowSchedulerKeyException"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ciem_key_exception_notify.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.ciem_key_exception_monthly.arn
}

resource "aws_lambda_permission" "ciem_scheduler_permission_drift" {
  for_each      = local.saml_role_names
  statement_id  = "AllowSchedulerPermissionDrift-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ciem_permission_drift.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.ciem_permission_drift_monthly[each.key].arn
}

resource "aws_apigatewayv2_api" "ciem_slack_callback" {
  name          = "${local.name_prefix}-ciem-slack-callback"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "ciem_slack_callback" {
  api_id                 = aws_apigatewayv2_api.ciem_slack_callback.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ciem_callback.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "ciem_slack_callback" {
  api_id    = aws_apigatewayv2_api.ciem_slack_callback.id
  route_key = "POST /slack/interactivity"
  target    = "integrations/${aws_apigatewayv2_integration.ciem_slack_callback.id}"
}

resource "aws_cloudwatch_log_group" "ciem_slack_callback_access" {
  name              = "/aws/apigateway/${local.name_prefix}-ciem-slack-callback"
  retention_in_days = 30
}

resource "aws_apigatewayv2_stage" "ciem_slack_callback" {
  api_id      = aws_apigatewayv2_api.ciem_slack_callback.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.ciem_slack_callback_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
    })
  }
}

resource "aws_lambda_permission" "ciem_apigateway_callback" {
  statement_id  = "AllowAPIGatewayCiemCallback"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ciem_callback.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.ciem_slack_callback.execution_arn}/*/*"
}

locals {
  ciem_function_names = {
    unused_access_report = aws_lambda_function.ciem_unused_access_report.function_name
    key_exception_notify = aws_lambda_function.ciem_key_exception_notify.function_name
    callback             = aws_lambda_function.ciem_callback.function_name
    action_executor      = aws_lambda_function.ciem_action_executor.function_name
    permission_drift     = aws_lambda_function.ciem_permission_drift.function_name
    session_revoke       = aws_lambda_function.ciem_keycloak_session_revoke.function_name
  }
}

resource "aws_cloudwatch_metric_alarm" "ciem_lambda_errors" {
  for_each            = local.ciem_function_names
  alarm_name          = "${each.value}-errors"
  alarm_description   = "AWS-SEC-03 CIEM Lambda 오류: ${each.key}"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [local.security_alerts_topic_arn]

  dimensions = {
    FunctionName = each.value
  }
}

output "ciem_slack_interactivity_endpoint" {
  description = "Slack App Interactivity Request URL에 /slack/interactivity를 붙일 HTTPS endpoint"
  value       = aws_apigatewayv2_stage.ciem_slack_callback.invoke_url
}
