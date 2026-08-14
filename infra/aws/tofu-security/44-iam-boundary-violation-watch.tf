# Permission Boundary 위반 실시간 감시 - AttachRolePolicy → Slack 1-Click 잠금
# 4개 SAML Role(tofu-identity 소유)은 인라인 정책만 갖도록 설계돼 있어서 관리형
# 정책이 붙는 경우가 원래 없다 - AttachRolePolicy가 호출된다는 사실 자체가
# "설계된 경계 밖의 권한이 붙었다"는 이상 징후. 위반 여부를 CloudWatch Logs에
# 남기고(Grafana 테이블 패널이 조회) Slack에 원클릭 잠금 버튼과 함께 알린다.
# 잠금 실행 자체는 scripts/session-revoke.py를 그대로 재사용(28번 tf의
# lock_account_risk 액션 참고).
#
# ⚠️ EventBridge 규칙 + 감시 Lambda는 provider = aws.us_east_1로 배포한다. IAM은
# 글로벌 서비스라 AttachRolePolicy 관리 이벤트가 CloudTrail을 거쳐 EventBridge
# 기본 버스로 갈 때 항상 us-east-1에만 도착한다(project-c에서 실측 확인).
# 로그그룹/Secret은 ap-northeast-2에 두고, Lambda 코드 안에서 boto3 클라이언트가
# region_name을 명시한다.

resource "aws_cloudwatch_log_group" "iam_boundary_violation" {
  name              = "/${var.project_name}/iam-boundary-violations"
  retention_in_days = 30
}

data "archive_file" "iam_boundary_violation_watch" {
  type        = "zip"
  source_file = "${path.module}/scripts/iam-boundary-violation-watch.py"
  output_path = "${path.module}/.build/iam-boundary-violation-watch.zip"
}

resource "aws_iam_role" "iam_boundary_violation_watch" {
  provider = aws.us_east_1
  name     = "${local.name_prefix}-iam-boundary-watch-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "iam_boundary_violation_watch_basic_logs" {
  provider   = aws.us_east_1
  role       = aws_iam_role.iam_boundary_violation_watch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "iam_boundary_violation_watch_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.iam_boundary_violation.arn}:*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.slack_app.arn]
  }
}

resource "aws_iam_role_policy" "iam_boundary_violation_watch_permissions" {
  provider = aws.us_east_1
  name     = "iam-boundary-watch-permissions"
  role     = aws_iam_role.iam_boundary_violation_watch.id
  policy   = data.aws_iam_policy_document.iam_boundary_violation_watch_permissions.json
}

resource "aws_lambda_function" "iam_boundary_violation_watch" {
  provider         = aws.us_east_1
  function_name    = "${local.name_prefix}-iam-boundary-violation-watch"
  role             = aws_iam_role.iam_boundary_violation_watch.arn
  handler          = "iam-boundary-violation-watch.handler"
  runtime          = "python3.12"
  timeout          = 30
  filename         = data.archive_file.iam_boundary_violation_watch.output_path
  source_code_hash = data.archive_file.iam_boundary_violation_watch.output_base64sha256

  environment {
    variables = {
      LOG_GROUP_NAME               = aws_cloudwatch_log_group.iam_boundary_violation.name
      SLACK_SECRET_ARN             = aws_secretsmanager_secret.slack_app.arn
      EXPECTED_MANAGED_POLICY_ARNS = ""
    }
  }
}

resource "aws_cloudwatch_event_rule" "attach_role_policy" {
  provider    = aws.us_east_1
  name        = "${local.name_prefix}-attach-role-policy-watch"
  description = "4개 SAML Role에 관리형 정책이 붙는 순간(Permission Boundary 모델 밖) 감지"

  event_pattern = jsonencode({
    source      = ["aws.iam"]
    detail-type = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["iam.amazonaws.com"]
      eventName   = ["AttachRolePolicy"]
      requestParameters = {
        roleName = [for name in local.saml_role_names : name]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "attach_role_policy_to_lambda" {
  provider = aws.us_east_1
  rule     = aws_cloudwatch_event_rule.attach_role_policy.name
  arn      = aws_lambda_function.iam_boundary_violation_watch.arn
}

resource "aws_lambda_permission" "allow_eventbridge_attach_role_policy" {
  provider      = aws.us_east_1
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.iam_boundary_violation_watch.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.attach_role_policy.arn
}
