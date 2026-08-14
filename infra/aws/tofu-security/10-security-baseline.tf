# 계정 보안 베이스라인 (AWS Foundational Security Best Practices 정렬)
# Config, Security Hub CSPM(FSBP 기본, CIS는 선택), 계정 단위 S3 Block Public
# Access, Budgets/Cost Anomaly, 계정 패스워드 정책, 보안 연락처를 다룬다.
#
# 다루지 않는 것: 루트/IAM 사용자 MFA(콘솔에서 사람이 직접 해야 함, 이 계정은
# 사람 접근을 전부 tofu-identity의 SAML로 처리해 attach 대상 IAM 사용자가 없음),
# 장기 Access Key 금지(같은 이유).

resource "aws_s3_bucket" "config_bucket" {
  bucket        = "${local.name_prefix}-config-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

# S3 access logging 전용 타겟 버킷 - cloudtrail_bucket/config_bucket/rds_audit_worm이
# 전부 여기로 로그를 보낸다. 이 버킷들끼리 서로를 타겟으로 삼으면(A→B, B→A) 순환
# 로깅이 생길 수 있어, 로그를 받기만 하고 자기 자신은 로그를 안 남기는 종점을 따로 둠.
resource "aws_s3_bucket" "s3_access_logs" {
  bucket        = "${local.name_prefix}-s3-access-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "s3_access_logs" {
  bucket                  = aws_s3_bucket.s3_access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "s3_access_logs" {
  bucket = aws_s3_bucket.s3_access_logs.id
  rule {
    id     = "expire_after_90_days"
    status = "Enabled"
    filter {}
    expiration { days = 90 }
  }
}

data "aws_iam_policy_document" "s3_access_logs_policy" {
  statement {
    sid    = "S3ServerAccessLogsPolicy"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logging.s3.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.s3_access_logs.arn}/*"]
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [
        aws_s3_bucket.cloudtrail_bucket.arn,
        aws_s3_bucket.config_bucket.arn,
        aws_s3_bucket.rds_audit_worm.arn,
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.s3_access_logs.arn, "${aws_s3_bucket.s3_access_logs.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "s3_access_logs" {
  bucket = aws_s3_bucket.s3_access_logs.id
  policy = data.aws_iam_policy_document.s3_access_logs_policy.json
}

resource "aws_s3_bucket_logging" "config_bucket" {
  bucket        = aws_s3_bucket.config_bucket.id
  target_bucket = aws_s3_bucket.s3_access_logs.id
  target_prefix = "s3-access-logs/config-bucket/"
}

resource "aws_s3_bucket_lifecycle_configuration" "config_bucket_lifecycle" {
  bucket = aws_s3_bucket.config_bucket.id
  rule {
    id     = "expire_after_90_days"
    status = "Enabled"
    filter {}
    expiration { days = 90 }
  }
}

data "aws_iam_policy_document" "config_bucket_policy" {
  statement {
    sid    = "AWSConfigBucketPermissionsCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.config_bucket.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AWSConfigBucketExistenceCheck"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.config_bucket.arn]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "AWSConfigBucketDelivery"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.config_bucket.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"]
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.config_bucket.arn, "${aws_s3_bucket.config_bucket.arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "config_bucket_policy" {
  bucket = aws_s3_bucket.config_bucket.id
  policy = data.aws_iam_policy_document.config_bucket_policy.json
}

# Security Hub Config.1 대응 - 서비스 연결 역할만 요구, 커스텀 Role 안 씀
resource "aws_iam_service_linked_role" "config" {
  aws_service_name = "config.amazonaws.com"
}

resource "aws_config_configuration_recorder" "main" {
  name     = "${local.name_prefix}-config-recorder"
  role_arn = aws_iam_service_linked_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }

  depends_on = [aws_iam_service_linked_role.config]
}

resource "aws_config_delivery_channel" "main" {
  name           = "${local.name_prefix}-config-delivery-channel"
  s3_bucket_name = aws_s3_bucket.config_bucket.id

  depends_on = [
    aws_config_configuration_recorder.main,
    aws_s3_bucket_policy.config_bucket_policy,
  ]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}

# Security Hub CSPM - enable_default_standards=false로 FSBP/CIS를 각각 명시 구독
resource "aws_securityhub_account" "main" {
  enable_default_standards = false
}

resource "aws_securityhub_standards_subscription" "fsbp" {
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.main]
}

resource "aws_securityhub_standards_subscription" "cis" {
  count         = var.enable_cis_benchmark ? 1 : 0
  standards_arn = "arn:aws:securityhub:${var.aws_region}::standards/cis-aws-foundations-benchmark/v/1.4.0"
  depends_on    = [aws_securityhub_account.main]
}

# 계정 단위 S3 Block Public Access - 개별 버킷 설정 실수와 무관하게 원천 차단
resource "aws_s3_account_public_access_block" "main" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Security Hub EC2.182 대응 - EBS 스냅샷 퍼블릭 공유 계정 레벨 차단
resource "aws_ebs_snapshot_block_public_access" "main" {
  state = "block-all-sharing"
}

resource "aws_budgets_budget" "monthly_cost" {
  name         = "${local.name_prefix}-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_amount
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }
}

# Cost Anomaly Detection - 계정 탈취로 인한 비정상 리소스 생성 조기 포착
resource "aws_ce_anomaly_monitor" "service_monitor" {
  name              = "${local.name_prefix}-service-cost-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"
}

resource "aws_ce_anomaly_subscription" "main" {
  name             = "${local.name_prefix}-cost-anomaly-subscription"
  frequency        = "DAILY"
  monitor_arn_list = [aws_ce_anomaly_monitor.service_monitor.arn]

  subscriber {
    type    = "EMAIL"
    address = var.alert_email
  }

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      values        = ["100"]
      match_options = ["GREATER_THAN_OR_EQUAL"]
    }
  }
}

# Security Hub IAM.7 대응 - IAM 사용자가 없어도 계정 레벨 패스워드 정책은 검사됨
resource "aws_iam_account_password_policy" "main" {
  minimum_password_length        = 14
  require_lowercase_characters   = true
  require_uppercase_characters   = true
  require_numbers                = true
  require_symbols                = true
  allow_users_to_change_password = true
  max_password_age               = 90
  password_reuse_prevention      = 24
}

# Security Hub Account.1 대응
resource "aws_account_alternate_contact" "security" {
  alternate_contact_type = "SECURITY"
  email_address           = var.alert_email
  name                    = var.security_contact_name
  phone_number            = var.security_contact_phone
  title                   = "Security Administrator"
}
