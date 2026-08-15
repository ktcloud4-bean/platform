# IAM은 글로벌 서비스이므로 AttachRolePolicy CloudTrail 이벤트는 us-east-1에서만
# 수신한다. 실행 Lambda는 VPC에 넣지 않고 Slack 알림만 수행한다.

data "archive_file" "ciem_boundary_watch" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem_boundary_watch.py"
  output_path = "${path.module}/scripts/ciem_boundary_watch.zip"
}

resource "aws_cloudwatch_log_group" "ciem_boundary_watch" {
  provider          = aws.us_east_1
  name              = "/aws/lambda/${local.name_prefix}-ciem-boundary-watch"
  retention_in_days = 30
}

resource "aws_iam_role" "ciem_boundary_watch" {
  provider           = aws.us_east_1
  name               = "${local.name_prefix}-ciem-boundary-watch-role"
  assume_role_policy = data.aws_iam_policy_document.ciem_lambda_assume.json
}

resource "aws_iam_role_policy_attachment" "ciem_boundary_watch_logs" {
  provider   = aws.us_east_1
  role       = aws_iam_role.ciem_boundary_watch.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "ciem_boundary_watch" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.ciem_slack_app.arn]
  }
}

resource "aws_iam_role_policy" "ciem_boundary_watch" {
  provider = aws.us_east_1
  name     = "ciem-boundary-watch"
  role     = aws_iam_role.ciem_boundary_watch.id
  policy   = data.aws_iam_policy_document.ciem_boundary_watch.json
}

resource "aws_lambda_function" "ciem_boundary_watch" {
  provider         = aws.us_east_1
  function_name    = "${local.name_prefix}-ciem-boundary-watch"
  role             = aws_iam_role.ciem_boundary_watch.arn
  handler          = "ciem_boundary_watch.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.ciem_boundary_watch.output_path
  source_code_hash = data.archive_file.ciem_boundary_watch.output_base64sha256

  environment {
    variables = {
      SLACK_SECRET_ARN = aws_secretsmanager_secret.ciem_slack_app.arn
      SLACK_CHANNEL_ID = var.slack_channel_id
      SECRETS_REGION   = var.aws_region
    }
  }

  depends_on = [aws_cloudwatch_log_group.ciem_boundary_watch]
}

resource "aws_cloudwatch_event_rule" "ciem_attach_role_policy" {
  provider    = aws.us_east_1
  name        = "${local.name_prefix}-ciem-attach-role-policy-watch"
  description = "SAML reader role 관리형 정책 부착 성공만 CIEM 경계 위반으로 탐지"

  event_pattern = jsonencode({
    source      = ["aws.iam"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["iam.amazonaws.com"]
      eventName   = ["AttachRolePolicy"]
      errorCode   = [{ exists = false }]
      requestParameters = {
        roleName = values(local.saml_role_names)
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "ciem_attach_role_policy" {
  provider = aws.us_east_1
  rule     = aws_cloudwatch_event_rule.ciem_attach_role_policy.name
  arn      = aws_lambda_function.ciem_boundary_watch.arn
}

resource "aws_lambda_permission" "ciem_attach_role_policy" {
  provider      = aws.us_east_1
  statement_id  = "AllowEventBridgeCiemAttachRolePolicy"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ciem_boundary_watch.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ciem_attach_role_policy.arn
}

# us-east-1 Lambda 오류는 기존 보안 SNS topic이 있는 ap-northeast-2로 EventBridge
# event bus를 통해 전달한다. CloudWatch Alarm은 SNS cross-region action을 지원하지 않는다.
resource "aws_cloudwatch_metric_alarm" "ciem_boundary_watch_errors" {
  provider            = aws.us_east_1
  alarm_name          = "${local.name_prefix}-ciem-boundary-watch-errors"
  alarm_description   = "AWS-SEC-03 CIEM IAM boundary watch Lambda 오류"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = aws_lambda_function.ciem_boundary_watch.function_name
  }
}

resource "aws_iam_role" "ciem_boundary_alarm_forward" {
  provider = aws.us_east_1
  name     = "${local.name_prefix}-ciem-boundary-alarm-forward-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "events.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ciem_boundary_alarm_forward" {
  provider = aws.us_east_1
  name     = "put-boundary-alarm-to-ap-northeast-2"
  role     = aws_iam_role.ciem_boundary_alarm_forward.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "events:PutEvents"
      Resource = "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:event-bus/default"
    }]
  })
}

resource "aws_cloudwatch_event_rule" "ciem_boundary_alarm_forward" {
  provider = aws.us_east_1
  name     = "${local.name_prefix}-ciem-boundary-alarm-forward"
  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.ciem_boundary_watch_errors.alarm_name]
      state     = { value = ["ALARM"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "ciem_boundary_alarm_forward" {
  provider = aws.us_east_1
  rule     = aws_cloudwatch_event_rule.ciem_boundary_alarm_forward.name
  arn      = "arn:${data.aws_partition.current.partition}:events:${var.aws_region}:${data.aws_caller_identity.current.account_id}:event-bus/default"
  role_arn = aws_iam_role.ciem_boundary_alarm_forward.arn
}

resource "aws_cloudwatch_event_rule" "ciem_boundary_alarm_notify" {
  name = "${local.name_prefix}-ciem-boundary-alarm-notify"
  event_pattern = jsonencode({
    source      = ["aws.cloudwatch"]
    detail-type = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [aws_cloudwatch_metric_alarm.ciem_boundary_watch_errors.alarm_name]
      state     = { value = ["ALARM"] }
    }
  })
}

resource "aws_cloudwatch_event_target" "ciem_boundary_alarm_notify" {
  rule = aws_cloudwatch_event_rule.ciem_boundary_alarm_notify.name
  arn  = local.security_alerts_topic_arn
}
