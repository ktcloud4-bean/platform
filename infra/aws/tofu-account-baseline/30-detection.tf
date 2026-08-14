resource "aws_guardduty_detector" "main" {
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

resource "aws_guardduty_detector_feature" "s3_data_events" {
  detector_id = aws_guardduty_detector.main.id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "ebs_malware_protection" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "ENABLED"
}

resource "aws_accessanalyzer_analyzer" "main" {
  analyzer_name = "${local.name_prefix}-account-access-analyzer"
  type          = "ACCOUNT"
}

resource "aws_iam_role" "security_lake_metastore" {
  count = var.enable_security_lake ? 1 : 0
  name  = "${local.name_prefix}-security-lake-metastore-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "security_lake_metastore" {
  count      = var.enable_security_lake ? 1 : 0
  role       = aws_iam_role.security_lake_metastore[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonSecurityLakeMetastoreManager"
}

resource "aws_iam_role_policy_attachment" "security_lake_lakeformation" {
  count      = var.enable_security_lake ? 1 : 0
  role       = aws_iam_role.security_lake_metastore[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSLakeFormationDataAdmin"
}

resource "aws_securitylake_data_lake" "main" {
  count                       = var.enable_security_lake ? 1 : 0
  meta_store_manager_role_arn = aws_iam_role.security_lake_metastore[0].arn

  configuration {
    region = var.aws_region

    encryption_configuration {
      kms_key_id = "S3_MANAGED_KEY"
    }

    lifecycle_configuration {
      transition {
        days          = 30
        storage_class = "GLACIER"
      }
      expiration {
        days = var.security_lake_retention_days
      }
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.security_lake_metastore,
    aws_iam_role_policy_attachment.security_lake_lakeformation,
  ]
}

# Security Lake가 metastore manager Lambda와 함께 자동 생성한다. 서비스 lifecycle은
# Security Lake가 계속 소유하고, 이 root는 CloudWatch Logs 보존 정책만 import해 관리한다.
resource "aws_cloudwatch_log_group" "security_lake_metastore" {
  name              = "/aws/lambda/AmazonSecurityLakeMetastoreManager-${var.aws_region}"
  retention_in_days = var.security_lake_metastore_log_retention_days
}

import {
  to = aws_cloudwatch_log_group.security_lake_metastore
  id = "/aws/lambda/AmazonSecurityLakeMetastoreManager-${var.aws_region}"
}

resource "aws_securitylake_aws_log_source" "vpc_flow" {
  count = var.enable_security_lake ? 1 : 0
  source {
    source_name = "VPC_FLOW"
    regions     = [var.aws_region]
  }
  depends_on = [aws_securitylake_data_lake.main]
}

resource "aws_securitylake_aws_log_source" "securityhub_findings" {
  count = var.enable_security_lake ? 1 : 0
  source {
    source_name = "SH_FINDINGS"
    regions     = [var.aws_region]
  }
  depends_on = [aws_securitylake_data_lake.main]
}

resource "aws_config_config_rule" "restricted_ssh" {
  name = "${local.name_prefix}-restricted-ssh"
  source {
    owner             = "AWS"
    source_identifier = "INCOMING_SSH_DISABLED"
  }
  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "restricted_common_ports" {
  name = "${local.name_prefix}-restricted-common-ports"
  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_INCOMING_TRAFFIC"
  }
  input_parameters = jsonencode({ blockedPort1 = "22", blockedPort2 = "3389" })
  depends_on       = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "iam_user_unused_credentials" {
  name = "${local.name_prefix}-iam-user-unused-credentials"
  source {
    owner             = "AWS"
    source_identifier = "IAM_USER_UNUSED_CREDENTIALS_CHECK"
  }
  input_parameters = jsonencode({ maxCredentialUsageAge = "90" })
  depends_on       = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "access_keys_rotated" {
  name = "${local.name_prefix}-access-keys-rotated"
  source {
    owner             = "AWS"
    source_identifier = "ACCESS_KEYS_ROTATED"
  }
  input_parameters = jsonencode({ maxAccessKeyAge = "90" })
  depends_on       = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "ec2_imdsv2" {
  name = "${local.name_prefix}-ec2-imdsv2-check"
  source {
    owner             = "AWS"
    source_identifier = "EC2_IMDSV2_CHECK"
  }
  depends_on = [aws_config_configuration_recorder_status.main]
}
