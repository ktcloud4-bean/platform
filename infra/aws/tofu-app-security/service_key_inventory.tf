# AWS-SEC-07: /service/ IAM access key의 메타데이터만 읽고 경보한다.
# 이 리소스와 실행 코드는 access key ID/secret을 반환·기록·알림에 넣지 않으며,
# IAM UpdateAccessKey/DeleteAccessKey 권한도 갖지 않는다.

data "archive_file" "ciem_service_key_inventory" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem_service_key_inventory.py"
  output_path = "${path.module}/scripts/ciem_service_key_inventory.zip"
}

resource "aws_cloudwatch_log_group" "ciem_service_key_inventory" {
  name              = "/aws/lambda/${local.name_prefix}-ciem-service-key-inventory"
  retention_in_days = 30
}

resource "aws_iam_role" "ciem_service_key_inventory" {
  name = "${local.name_prefix}-ciem-service-key-inventory-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

data "aws_iam_policy_document" "ciem_service_key_inventory" {
  statement {
    effect = "Allow"
    actions = [
      "iam:GetAccessKeyLastUsed",
      "iam:ListAccessKeys",
      "iam:ListUserTags",
      "iam:ListUsers",
    ]
    resources = ["*"]
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

resource "aws_iam_role_policy" "ciem_service_key_inventory" {
  name   = "ciem-service-key-inventory-readonly"
  role   = aws_iam_role.ciem_service_key_inventory.id
  policy = data.aws_iam_policy_document.ciem_service_key_inventory.json
}

resource "aws_iam_role_policy_attachment" "ciem_service_key_inventory_logs" {
  role       = aws_iam_role.ciem_service_key_inventory.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "ciem_service_key_inventory" {
  function_name    = "${local.name_prefix}-ciem-service-key-inventory"
  role             = aws_iam_role.ciem_service_key_inventory.arn
  handler          = "ciem_service_key_inventory.handler"
  runtime          = "python3.12"
  timeout          = 120
  filename         = data.archive_file.ciem_service_key_inventory.output_path
  source_code_hash = data.archive_file.ciem_service_key_inventory.output_base64sha256

  environment {
    variables = {
      EXPECTED_SERVICE_USERS_JSON = jsonencode(var.ciem_service_key_identities)
      ROTATION_DAYS               = tostring(var.ciem_service_key_rotation_days)
      SNS_TOPIC_ARN               = local.security_alerts_topic_arn
    }
  }

  depends_on = [aws_cloudwatch_log_group.ciem_service_key_inventory]
}

resource "aws_iam_role_policy" "ciem_scheduler_service_key_inventory" {
  name = "invoke-ciem-service-key-inventory"
  role = aws_iam_role.ciem_scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = aws_lambda_function.ciem_service_key_inventory.arn
    }]
  })
}

resource "aws_scheduler_schedule" "ciem_service_key_inventory_monthly" {
  name                         = "${local.name_prefix}-ciem-service-key-inventory-monthly"
  group_name                   = "default"
  schedule_expression          = "cron(15 0 1 * ? *)"
  schedule_expression_timezone = "UTC"
  flexible_time_window { mode = "OFF" }

  target {
    arn      = aws_lambda_function.ciem_service_key_inventory.arn
    role_arn = aws_iam_role.ciem_scheduler.arn
  }
}

resource "aws_lambda_permission" "ciem_scheduler_service_key_inventory" {
  statement_id  = "AllowSchedulerServiceKeyInventory"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ciem_service_key_inventory.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.ciem_service_key_inventory_monthly.arn
}

resource "aws_cloudwatch_metric_alarm" "ciem_service_key_inventory_errors" {
  alarm_name          = "${aws_lambda_function.ciem_service_key_inventory.function_name}-errors"
  alarm_description   = "AWS-SEC-07 service IAM key inventory Lambda 오류"
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
    FunctionName = aws_lambda_function.ciem_service_key_inventory.function_name
  }
}
