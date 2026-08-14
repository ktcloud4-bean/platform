# VPC Flow Logs (Security Hub EC2.6 대응) - tofu-network의 Security Lake VPC_FLOW
# 소스와는 별개 통제라 고전적 aws_flow_log도 켜야 EC2.6이 통과됨.

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc-flow-logs/${local.name_prefix}"
  retention_in_days = 30
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

resource "aws_iam_role_policy" "vpc_flow_logs" {
  name = "vpc-flow-logs-to-cwl"
  role = aws_iam_role.vpc_flow_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams",
      ]
      Resource = "${aws_cloudwatch_log_group.vpc_flow_logs.arn}:*"
    }]
  })
}

resource "aws_flow_log" "main_vpc" {
  vpc_id               = data.terraform_remote_state.app_network.outputs.vpc_id
  log_destination_type = "cloud-watch-logs"
  log_destination       = aws_cloudwatch_log_group.vpc_flow_logs.arn
  iam_role_arn           = aws_iam_role.vpc_flow_logs.arn
  traffic_type           = "ALL"
}

# 계정 기본 VPC - EC2.6이 이 VPC까지 포함해서 검사하므로 같이 켬
data "aws_vpc" "default" {
  default = true
}

resource "aws_flow_log" "account_default_vpc" {
  vpc_id               = data.aws_vpc.default.id
  log_destination_type = "cloud-watch-logs"
  log_destination       = aws_cloudwatch_log_group.vpc_flow_logs.arn
  iam_role_arn           = aws_iam_role.vpc_flow_logs.arn
  traffic_type           = "ALL"
}
