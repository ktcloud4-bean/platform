# CIEM: 권한 드리프트 감지 + Slack 승인 기반 정책 최소화. 지정한 SAML Role들이
# 실제로 어떤 API를 썼는지 IAM Access Analyzer Policy Generation으로 분석하고,
# 안 쓴 권한이 있으면 Slack으로 알린다(발견은 자동, 실행은 사람 승인 후).
#
# ⚠️ boundary_drift_lookback_hours 기본값(3시간)은 데모/테스트용. 실운영에서는
# 24-ciem-lambda.tf의 90일 기준처럼 훨씬 긴 관찰 기간을 강력히 권장 - 안 그러면
# 분기별/저빈도 정당 업무 권한이 "미사용"으로 계속 오탐되어 알림 피로도만 높아짐.
#
# project-c와 달리 대상은 4개 SAML Role 전부(observer/observability-reader/
# security-reader/identity-reader) - 전부 이미 좁은 읽기전용이라 project-c의
# security-auditor 제외 사유(의도적으로 광범위한 권한)가 여기선 해당 없음.
#
# 사전 조건: 28-ciem-key-exception-flow.tf의 Slack App Secret/API Gateway 재사용.

resource "aws_iam_role" "access_analyzer_cloudtrail_read" {
  name = "${local.name_prefix}-access-analyzer-cloudtrail-read-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "access-analyzer.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "access_analyzer_cloudtrail_read" {
  name = "cloudtrail-bucket-read"
  role = aws_iam_role.access_analyzer_cloudtrail_read.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetBucketLocation", "s3:ListBucket"]
        Resource = [aws_s3_bucket.cloudtrail_bucket.arn, "${aws_s3_bucket.cloudtrail_bucket.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["cloudtrail:GetTrail", "cloudtrail:GetTrailStatus"]
        Resource = [aws_cloudtrail.main.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["iam:GetServiceLastAccessedDetails", "iam:GenerateServiceLastAccessedDetails"]
        Resource = "*"
      },
      {
        # CloudTrail 버킷이 KMS로 암호화돼 있어서 이 권한이 없으면
        # "AUTHORIZATION_ERROR: Incorrect permissions..."로 실패함(project-c 실측).
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [aws_kms_key.cloudtrail.arn]
      }
    ]
  })
}

data "archive_file" "ciem_boundary_drift_notify" {
  type        = "zip"
  source_file = "${path.module}/scripts/ciem-boundary-drift-notify.py"
  output_path = "${path.module}/.build/ciem-boundary-drift-notify.zip"
}

resource "aws_iam_role" "ciem_boundary_drift_notify" {
  name = "${local.name_prefix}-ciem-boundary-drift-notify-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ciem_boundary_drift_notify_basic_logs" {
  role       = aws_iam_role.ciem_boundary_drift_notify.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "ciem_boundary_drift_notify_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["access-analyzer:StartPolicyGeneration", "access-analyzer:GetGeneratedPolicy"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["iam:ListRolePolicies", "iam:GetRolePolicy"]
    resources = [for arn in local.saml_role_arns : arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.slack_app.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.access_analyzer_cloudtrail_read.arn]
  }
}

resource "aws_iam_role_policy" "ciem_boundary_drift_notify_permissions" {
  name   = "ciem-boundary-drift-notify-permissions"
  role   = aws_iam_role.ciem_boundary_drift_notify.id
  policy = data.aws_iam_policy_document.ciem_boundary_drift_notify_permissions.json
}

resource "aws_lambda_function" "ciem_boundary_drift_notify" {
  function_name    = "${local.name_prefix}-ciem-boundary-drift-notify"
  role             = aws_iam_role.ciem_boundary_drift_notify.arn
  handler          = "ciem-boundary-drift-notify.handler"
  runtime          = "python3.12"
  timeout          = 540
  filename         = data.archive_file.ciem_boundary_drift_notify.output_path
  source_code_hash = data.archive_file.ciem_boundary_drift_notify.output_base64sha256

  environment {
    variables = {
      CLOUDTRAIL_ARN           = aws_cloudtrail.main.arn
      LOOKBACK_HOURS           = tostring(var.boundary_drift_lookback_hours)
      ACCESS_ANALYZER_ROLE_ARN = aws_iam_role.access_analyzer_cloudtrail_read.arn
      SLACK_SECRET_ARN         = aws_secretsmanager_secret.slack_app.arn
      SLACK_CHANNEL            = "#cspm-findings"
    }
  }
}

# Role별 별도 스케줄(Lambda 하나가 여러 Role을 순서대로 처리하다 타임아웃
# 나는 걸 방지) - project-c는 role_suffix를 넘겨 Lambda가 name_prefix와
# 조합해 role_name을 계산했지만, SAML Role은 그 규칙을 안 따르므로 role_name을
# 그대로 넘긴다.
resource "aws_scheduler_schedule" "ciem_boundary_drift_check" {
  for_each = local.saml_role_names

  name       = "${local.name_prefix}-boundary-drift-${each.key}"
  group_name = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "rate(${var.boundary_drift_lookback_hours} hours)"
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.ciem_boundary_drift_notify.arn
    role_arn = aws_iam_role.ciem_scheduler.arn
    input    = jsonencode({ role_name = each.value })
  }
}

resource "aws_lambda_permission" "allow_scheduler_boundary_drift" {
  for_each = local.saml_role_names

  statement_id  = "AllowEventBridgeScheduler-${each.key}"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ciem_boundary_drift_notify.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.ciem_boundary_drift_check[each.key].arn
}

# Slack 버튼 클릭 콜백은 28번 파일의 ciem_key_callback을 그대로 재사용
# (Slack App은 Interactivity Request URL을 앱 전체에 하나만 등록 가능).
