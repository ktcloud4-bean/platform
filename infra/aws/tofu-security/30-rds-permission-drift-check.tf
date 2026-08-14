# RDS(Aurora) 마스킹 뷰 권한 드리프트 자동 복구 - 원본 테이블에 직접 GRANT로
# 마스킹 뷰를 우회하는 드리프트를 매일 탐지해서 REVOKE한다.
#
# ⚠️ 05번 파일과 동일한 전제조건: iam_database_authentication_enabled=true가
# tofu-app-db에 켜져 있어야 하고, hr-data-masking-views.sql에 db_admin/
# remediation_admin 두 Role을 추가로 적용해야 한다(project-c 원본에는 있었지만
# project-f의 05번 포팅 때 "필요한 것만"으로 줄이면서 뺐음 - 09번 시나리오를
# 쓰려면 hr-data-masking-views.sql에 다시 추가할 것).

data "archive_file" "rds_view_permission_check" {
  type        = "zip"
  source_file = "${path.module}/scripts/rds-view-permission-check.py"
  output_path = "${path.module}/.build/rds-view-permission-check.zip"
}

resource "aws_iam_role" "rds_view_permission_check" {
  name = "${local.name_prefix}-rds-view-permission-check-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_view_permission_check_basic_logs" {
  role       = aws_iam_role.rds_view_permission_check.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "rds_view_permission_check_vpc" {
  role       = aws_iam_role.rds_view_permission_check.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# ⚠️ 05번과 동일하게 Aurora 클러스터 리소스 ID를 tofu-app-db가 output으로
# 안 내놓아서 dbuser 리소스를 정밀 스코핑할 수 없다 - "*"로 넓게 허용.
data "aws_iam_policy_document" "rds_view_permission_check_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:*/remediation_admin"]
  }
}

resource "aws_iam_role_policy" "rds_view_permission_check_permissions" {
  name   = "rds-view-permission-check-permissions"
  role   = aws_iam_role.rds_view_permission_check.id
  policy = data.aws_iam_policy_document.rds_view_permission_check_permissions.json
}

resource "aws_security_group" "rds_view_permission_check_lambda" {
  name        = "${local.name_prefix}-rds-view-check-lambda-sg"
  description = "RDS permission drift check Lambda - outbound to Aurora(5432) only"
  vpc_id      = data.terraform_remote_state.app_network.outputs.vpc_id
}

resource "aws_vpc_security_group_egress_rule" "rds_view_check_lambda_to_rds" {
  security_group_id            = aws_security_group.rds_view_permission_check_lambda.id
  referenced_security_group_id = data.terraform_remote_state.app_network.outputs.rds_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}

resource "aws_lambda_function" "rds_view_permission_check" {
  function_name    = "${local.name_prefix}-rds-view-permission-check"
  role             = aws_iam_role.rds_view_permission_check.arn
  handler          = "rds-view-permission-check.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.rds_view_permission_check.output_path
  source_code_hash = data.archive_file.rds_view_permission_check.output_base64sha256
  layers           = var.psycopg2_layer_arn != "" ? [var.psycopg2_layer_arn] : []

  vpc_config {
    subnet_ids         = data.terraform_remote_state.app_network.outputs.private_app_subnet_ids
    security_group_ids = [aws_security_group.rds_view_permission_check_lambda.id]
  }

  environment {
    variables = {
      DB_HOST = split(":", data.terraform_remote_state.app_db.outputs.aurora_writer_endpoint)[0]
      DB_NAME = "hr_system" # tofu-app-db var.db_name 기본값
    }
  }
}

resource "aws_scheduler_schedule" "rds_view_permission_check_daily" {
  name       = "${local.name_prefix}-rds-view-check-daily"
  group_name = "default"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = "cron(0 18 * * ? *)" # 매일 03:00 KST
  schedule_expression_timezone = "UTC"

  target {
    arn      = aws_lambda_function.rds_view_permission_check.arn
    role_arn = aws_iam_role.ciem_scheduler.arn
  }
}

resource "aws_lambda_permission" "allow_scheduler_rds_check" {
  statement_id  = "AllowEventBridgeScheduler"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.rds_view_permission_check.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = aws_scheduler_schedule.rds_view_permission_check_daily.arn
}
