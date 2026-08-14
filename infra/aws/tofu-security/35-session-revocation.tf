# 세션 강제 종료 - 특정 인물의 AWS SAML 세션(4개 Role 전부)과 Keycloak 세션을
# 동시에 강제 종료. 파괴적 조치라 Security Hub Custom Action으로 사람이 트리거.
#
# ⚠️ 이 Lambda가 iam:PutRolePolicy로 건드리는 4개 Role(local.saml_role_arns)은
# 이 root가 만든 게 아니라 tofu-identity가 소유·prevent_destroy로 보호하는
# 실제 운영 중인 Role이다(실제 사람이 Keycloak SSO로 assume함). AGENTS.md의
# "credential 교체" 승인 항목에 준하는 조치이므로 적용 전 반드시 검토할 것.

resource "aws_securityhub_action_target" "revoke_session" {
  name        = "Revoke User Session"
  identifier  = "RevokeUserSession"
  description = "Force-terminate a specific person's AWS SAML sessions (all 4 roles) and Keycloak session at once"
}

data "archive_file" "session_revoke" {
  type        = "zip"
  source_file = "${path.module}/scripts/session-revoke.py"
  output_path = "${path.module}/.build/session-revoke.zip"
}

resource "aws_iam_role" "session_revoke" {
  name = "${local.name_prefix}-session-revoke-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "session_revoke_basic_logs" {
  role       = aws_iam_role.session_revoke.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "session_revoke_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["iam:PutRolePolicy"]
    resources = [for arn in local.saml_role_arns : arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.keycloak_admin.arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]
  }
}

resource "aws_iam_role_policy" "session_revoke_permissions" {
  name   = "session-revoke-permissions"
  role   = aws_iam_role.session_revoke.id
  policy = data.aws_iam_policy_document.session_revoke_permissions.json
}

resource "aws_iam_role_policy_attachment" "session_revoke_vpc" {
  role       = aws_iam_role.session_revoke.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_security_group" "session_revoke_lambda" {
  name        = "${local.name_prefix}-session-revoke-lambda-sg"
  description = "session-revoke Lambda - outbound to Keycloak(443) only"
  vpc_id      = data.terraform_remote_state.app_network.outputs.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "session_revoke_lambda_to_internet" {
  security_group_id = aws_security_group.session_revoke_lambda.id
  cidr_ipv4          = "0.0.0.0/0"
  from_port          = 443
  to_port             = 443
  ip_protocol        = "tcp"
  description        = "AWS API calls (Secrets Manager/SNS) via NAT/VPC endpoint"
}

resource "aws_vpc_security_group_egress_rule" "session_revoke_lambda_to_keycloak" {
  security_group_id = aws_security_group.session_revoke_lambda.id
  cidr_ipv4          = data.terraform_remote_state.network.outputs.onprem_cidr
  from_port          = 443
  to_port             = 443
  ip_protocol        = "tcp"
  description        = "Keycloak admin API via Site-to-Site VPN"
}

# Keycloak admin 자격증명 - platform-main은 Vault가 애플리케이션 비밀을 소유하므로
# (README "시크릿" 섹션) 이 Lambda가 직접 Vault를 못 건드린다. apply 후 값을
# 수동으로 채우거나(Slack Bot Token과 동일 패턴), Vault→Secrets Manager 동기화가
# 있다면 그쪽으로 연결할 것.
resource "aws_secretsmanager_secret" "keycloak_admin" {
  name                     = "${local.name_prefix}-keycloak-admin-credentials"
  description              = "온프레미스 Keycloak admin 계정 (수동으로 값 채워야 함)"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "keycloak_admin" {
  secret_id = aws_secretsmanager_secret.keycloak_admin.id
  secret_string = jsonencode({
    username = "여기에-실제-값을-채우세요"
    password = "여기에-실제-값을-채우세요"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_lambda_function" "session_revoke" {
  function_name    = "${local.name_prefix}-session-revoke"
  role             = aws_iam_role.session_revoke.arn
  handler          = "session-revoke.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.session_revoke.output_path
  source_code_hash = data.archive_file.session_revoke.output_base64sha256

  vpc_config {
    subnet_ids         = data.terraform_remote_state.app_network.outputs.private_app_subnet_ids
    security_group_ids = [aws_security_group.session_revoke_lambda.id]
  }

  environment {
    variables = {
      NAME_PREFIX             = local.name_prefix
      KEYCLOAK_HOST            = var.onprem_keycloak_host
      REALM_NAME               = var.keycloak_realm_name
      KEYCLOAK_ADMIN_SECRET_ARN = aws_secretsmanager_secret.keycloak_admin.arn
      SNS_TOPIC_ARN            = aws_sns_topic.security_alerts.arn
      ROLE_NAMES_JSON          = jsonencode([for name in local.saml_role_names : name])
    }
  }
}

resource "aws_cloudwatch_event_rule" "revoke_session_action" {
  name = "${local.name_prefix}-revoke-session-action"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Custom Action"]
    resources   = [aws_securityhub_action_target.revoke_session.arn]
  })
}

resource "aws_cloudwatch_event_target" "revoke_session_lambda" {
  rule = aws_cloudwatch_event_rule.revoke_session_action.name
  arn  = aws_lambda_function.session_revoke.arn
}

resource "aws_lambda_permission" "allow_eventbridge_revoke" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.session_revoke.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.revoke_session_action.arn
}
