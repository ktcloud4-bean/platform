resource "aws_s3_bucket" "rds_audit_worm" {
  bucket              = "${local.name_prefix}-rds-audit-worm-${data.aws_caller_identity.current.account_id}"
  object_lock_enabled = true
}

resource "aws_s3_bucket_public_access_block" "rds_audit_worm" {
  bucket                  = aws_s3_bucket.rds_audit_worm.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "rds_audit_worm" {
  bucket = aws_s3_bucket.rds_audit_worm.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "rds_audit_worm" {
  bucket = aws_s3_bucket.rds_audit_worm.id

  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.rds_audit_worm_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.rds_audit_worm]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "rds_audit_worm" {
  bucket = aws_s3_bucket.rds_audit_worm.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.rds_audit_worm.arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "rds_audit_worm" {
  bucket = aws_s3_bucket.rds_audit_worm.id

  rule {
    id     = "rds-audit-retention"
    status = "Enabled"
    filter {}

    transition {
      days          = var.rds_audit_transition_days
      storage_class = "DEEP_ARCHIVE"
    }

    expiration {
      days = var.rds_audit_expiration_days
    }
  }
}

data "aws_iam_policy_document" "rds_audit_worm" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.rds_audit_worm.arn, "${aws_s3_bucket.rds_audit_worm.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "rds_audit_worm" {
  bucket = aws_s3_bucket.rds_audit_worm.id
  policy = data.aws_iam_policy_document.rds_audit_worm.json
}

resource "aws_iam_role" "firehose_rds_audit" {
  name = "${local.name_prefix}-firehose-rds-audit-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "firehose.amazonaws.com" }
    }]
  })
}

data "aws_iam_policy_document" "firehose_rds_audit" {
  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [aws_s3_bucket.rds_audit_worm.arn, "${aws_s3_bucket.rds_audit_worm.arn}/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.rds_audit_worm.arn]
  }
}

resource "aws_iam_role_policy" "firehose_rds_audit" {
  name   = "firehose-rds-audit-s3-write"
  role   = aws_iam_role.firehose_rds_audit.id
  policy = data.aws_iam_policy_document.firehose_rds_audit.json
}

resource "aws_kinesis_firehose_delivery_stream" "rds_audit" {
  name        = "${local.name_prefix}-rds-audit-worm-stream"
  destination = "extended_s3"

  server_side_encryption {
    enabled = true
  }

  extended_s3_configuration {
    role_arn           = aws_iam_role.firehose_rds_audit.arn
    bucket_arn         = aws_s3_bucket.rds_audit_worm.arn
    prefix             = "rds-postgresql-audit/"
    compression_format = "GZIP"
    buffering_size     = 5
    buffering_interval = 300
  }
}

resource "aws_iam_role" "cwl_to_firehose" {
  name = "${local.name_prefix}-cwl-to-firehose-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*" }
      }
    }]
  })
}

data "aws_iam_policy_document" "cwl_to_firehose" {
  statement {
    effect    = "Allow"
    actions   = ["firehose:PutRecord", "firehose:PutRecordBatch"]
    resources = [aws_kinesis_firehose_delivery_stream.rds_audit.arn]
  }
}

resource "aws_iam_role_policy" "cwl_to_firehose" {
  name   = "cwl-to-firehose-put-record"
  role   = aws_iam_role.cwl_to_firehose.id
  policy = data.aws_iam_policy_document.cwl_to_firehose.json
}

resource "aws_cloudwatch_log_subscription_filter" "rds_audit_to_worm" {
  name            = "${local.name_prefix}-rds-audit-to-worm"
  log_group_name  = local.aurora_postgresql_log_group
  filter_pattern  = "AUDIT"
  destination_arn = aws_kinesis_firehose_delivery_stream.rds_audit.arn
  role_arn        = aws_iam_role.cwl_to_firehose.arn
}
