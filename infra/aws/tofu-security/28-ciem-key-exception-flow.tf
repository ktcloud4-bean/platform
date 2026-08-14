# CIEM: Access Key 예외 확인 Slack 인터랙티브 플로우 - 소유자를 찾아서 삭제
# 여부를 사람이 Slack 버튼으로 직접 승인(자동 삭제 없음).
#
# ⚠️ 사전 준비(수동): Slack App을 만들고 Bot Token(chat:write)/Signing Secret을
# 발급받아 아래 Secrets Manager에 채우고, Slack App의 Interactivity Request URL을
# slack_interactivity_endpoint 출력값 + /slack/interactivity로 설정할 것.

resource "aws_secretsmanager_secret" "slack_app" {
  name                     = "${local.name_prefix}-slack-app-credentials"
  description              = "Slack Bot Token + Signing Secret (수동으로 값 채워야 함)"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "slack_app" {
  secret_id = aws_secretsmanager_secret.slack_app.id
  secret_string = jsonencode({
    bot_token      = "xoxb-여기에-실제-값을-채우세요"
    signing_secret = "여기에-실제-값을-채우세요"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ---------- Lambda A: 미사용 Access Key 탐지 + Slack 알림 ----------
data "archive_file" "ciem_key_notify" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem-key-exception-notify.py"
  output_path = "${path.module}/.build/ciem-key-exception-notify.zip"
}

resource "aws_iam_role" "ciem_key_notify" {
  name = "${local.name_prefix}-ciem-key-notify-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ciem_key_notify_basic_logs" {
  role       = aws_iam_role.ciem_key_notify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "ciem_key_notify_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["iam:ListUsers", "iam:ListAccessKeys", "iam:GetAccessKeyLastUsed", "iam:ListUserTags"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.slack_app.arn]
  }
}

resource "aws_iam_role_policy" "ciem_key_notify_permissions" {
  name   = "ciem-key-notify-permissions"
  role   = aws_iam_role.ciem_key_notify.id
  policy = data.aws_iam_policy_document.ciem_key_notify_permissions.json
}

resource "aws_lambda_function" "ciem_key_notify" {
  function_name    = "${local.name_prefix}-ciem-key-exception-notify"
  role             = aws_iam_role.ciem_key_notify.arn
  handler          = "ciem-key-exception-notify.handler"
  runtime          = "python3.12"
  timeout          = 120
  filename         = data.archive_file.ciem_key_notify.output_path
  source_code_hash = data.archive_file.ciem_key_notify.output_base64sha256

  environment {
    variables = {
      SLACK_SECRET_ARN = aws_secretsmanager_secret.slack_app.arn
      SLACK_CHANNEL    = "#cspm-findings"
    }
  }
}

resource "aws_scheduler_schedule" "ciem_key_notify_monthly" {
  name       = "${local.name_prefix}-ciem-key-notify-monthly"
  group_name = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 0 1 * ? *)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.ciem_key_notify.arn
    role_arn = aws_iam_role.ciem_scheduler.arn
  }
}

resource "aws_lambda_permission" "allow_scheduler_key_notify" {
  statement_id  = "AllowEventBridgeScheduler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ciem_key_notify.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.ciem_key_notify_monthly.arn
}

# ---------- Lambda B: Slack 버튼 클릭 콜백 (Access Key + 권한 드리프트 + 경계 위반 공용) ----------
data "archive_file" "ciem_key_callback" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem-key-exception-callback.py"
  output_path = "${path.module}/.build/ciem-key-exception-callback.zip"
}

resource "aws_iam_role" "ciem_key_callback" {
  name = "${local.name_prefix}-ciem-key-callback-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ciem_key_callback_basic_logs" {
  role       = aws_iam_role.ciem_key_callback.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "ciem_key_callback_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["iam:TagUser", "iam:UpdateAccessKey", "iam:DeleteAccessKey"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.slack_app.arn]
  }
  # 36-ciem-boundary-drift-check.tf(권한 드리프트) 처리용
  statement {
    effect    = "Allow"
    actions   = ["access-analyzer:GetGeneratedPolicy"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["iam:ListRolePolicies", "iam:PutRolePolicy", "iam:TagRole"]
    # 4개 SAML Role(tofu-identity 소유)로만 정확히 좁힘
    resources = [for arn in local.saml_role_arns : arn]
  }
  # 44-iam-boundary-violation-watch.tf(경계 위반 1-Click 잠금) 처리용
  statement {
    effect    = "Allow"
    actions   = ["lambda:InvokeFunction"]
    resources = [aws_lambda_function.session_revoke.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["iam:DetachRolePolicy"]
    resources = [for arn in local.saml_role_arns : arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.iam_boundary_violation.arn}:*"]
  }
}

resource "aws_iam_role_policy" "ciem_key_callback_permissions" {
  name   = "ciem-key-callback-permissions"
  role   = aws_iam_role.ciem_key_callback.id
  policy = data.aws_iam_policy_document.ciem_key_callback_permissions.json
}

resource "aws_lambda_function" "ciem_key_callback" {
  function_name    = "${local.name_prefix}-ciem-key-exception-callback"
  role             = aws_iam_role.ciem_key_callback.arn
  handler          = "ciem-key-exception-callback.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.ciem_key_callback.output_path
  source_code_hash = data.archive_file.ciem_key_callback.output_base64sha256

  environment {
    variables = {
      SLACK_SECRET_ARN             = aws_secretsmanager_secret.slack_app.arn
      SESSION_REVOKE_FUNCTION_NAME = aws_lambda_function.session_revoke.function_name
      BOUNDARY_VIOLATION_LOG_GROUP = aws_cloudwatch_log_group.iam_boundary_violation.name
    }
  }
}

# ---------- API Gateway: Slack Interactivity 콜백 수신 엔드포인트 ----------
resource "aws_apigatewayv2_api" "slack_interactivity" {
  name          = "${local.name_prefix}-slack-interactivity"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "slack_interactivity" {
  api_id                 = aws_apigatewayv2_api.slack_interactivity.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.ciem_key_callback.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "slack_interactivity" {
  api_id    = aws_apigatewayv2_api.slack_interactivity.id
  route_key = "POST /slack/interactivity"
  target    = "integrations/${aws_apigatewayv2_integration.slack_interactivity.id}"
}

resource "aws_cloudwatch_log_group" "slack_interactivity_access_logs" {
  name              = "/aws/apigateway/${local.name_prefix}-slack-interactivity"
  retention_in_days = 30
}

resource "aws_apigatewayv2_stage" "slack_interactivity" {
  api_id      = aws_apigatewayv2_api.slack_interactivity.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.slack_interactivity_access_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }
}

resource "aws_lambda_permission" "allow_apigw_callback" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ciem_key_callback.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.slack_interactivity.execution_arn}/*/*"
}

output "slack_interactivity_endpoint" {
  description = "Slack App Interactivity Request URL에 이 값 + /slack/interactivity 를 넣을 것"
  value       = aws_apigatewayv2_stage.slack_interactivity.invoke_url
}
