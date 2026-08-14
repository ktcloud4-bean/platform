resource "aws_cloudwatch_log_group" "vpc_flow_reject" {
  name              = "/aws/vpc-flow-logs/${local.name_prefix}-reject"
  retention_in_days = var.flow_log_retention_days
}

resource "aws_iam_role" "vpc_flow_logs" {
  name = "${local.name_prefix}-vpc-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
    }]
  })
}

data "aws_iam_policy_document" "vpc_flow_logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.vpc_flow_reject.arn}:*"]
  }
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name   = "vpc-flow-reject-to-cloudwatch"
  role   = aws_iam_role.vpc_flow_logs.id
  policy = data.aws_iam_policy_document.vpc_flow_logs.json
}

resource "aws_flow_log" "hr_vpc_reject" {
  vpc_id               = data.terraform_remote_state.app_network.outputs.vpc_id
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_flow_reject.arn
  iam_role_arn         = aws_iam_role.vpc_flow_logs.arn
  traffic_type         = "REJECT"
}

resource "aws_flow_log" "default_vpc_reject" {
  vpc_id               = data.aws_vpc.default.id
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_flow_reject.arn
  iam_role_arn         = aws_iam_role.vpc_flow_logs.arn
  traffic_type         = "REJECT"
}
