resource "aws_s3_bucket" "athena_results" {
  bucket = "${local.name_prefix}-grafana-athena-results-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.athena_results.arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-query-results"
    status = "Enabled"
    filter {}

    expiration {
      days = var.athena_results_expiration_days
    }
  }
}

data "aws_iam_policy_document" "athena_results" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [aws_s3_bucket.athena_results.arn, "${aws_s3_bucket.athena_results.arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id
  policy = data.aws_iam_policy_document.athena_results.json
}

resource "aws_athena_workgroup" "grafana" {
  name = "${local.name_prefix}-security"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = false

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = aws_kms_key.athena_results.arn
      }
    }
  }
}

resource "aws_iam_role" "grafana" {
  name = "${local.name_prefix}-grafana-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "grafana.amazonaws.com" }
    }]
  })
}

data "aws_iam_policy_document" "grafana" {
  statement {
    effect = "Allow"
    actions = [
      "cloudwatch:DescribeAlarms",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetInsightRuleReport",
      "cloudwatch:ListMetrics",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:GetLogGroupFields",
      "logs:GetQueryResults",
      "logs:StartQuery",
      "logs:StopQuery",
      "oam:ListAttachedLinks",
      "oam:ListSinks",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "athena:GetDataCatalog",
      "athena:GetDatabase",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:GetTableMetadata",
      "athena:GetWorkGroup",
      "athena:ListDatabases",
      "athena:ListTableMetadata",
      "athena:ListWorkGroups",
      "athena:StartQueryExecution",
      "athena:StopQueryExecution",
    ]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetPartition",
      "glue:GetPartitions",
      "glue:GetTable",
      "glue:GetTables",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.athena_results.arn, "arn:${data.aws_partition.current.partition}:s3:::aws-security-data-lake-*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.athena_results.arn}/*", "arn:${data.aws_partition.current.partition}:s3:::aws-security-data-lake-*/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.athena_results.arn}/results/*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
    ]
    resources = [aws_kms_key.athena_results.arn]
  }
}

resource "aws_iam_role_policy" "grafana" {
  name   = "grafana-security-datasources-readonly"
  role   = aws_iam_role.grafana.id
  policy = data.aws_iam_policy_document.grafana.json
}

resource "aws_lakeformation_permissions" "grafana_database" {
  principal   = aws_iam_role.grafana.arn
  permissions = ["DESCRIBE"]

  database {
    name = local.security_lake_database_name
  }
}

resource "aws_lakeformation_permissions" "grafana_tables" {
  principal   = aws_iam_role.grafana.arn
  permissions = ["SELECT", "DESCRIBE"]

  table {
    database_name = local.security_lake_database_name
    wildcard      = true
  }
}

resource "aws_grafana_workspace" "soc" {
  name                     = "${local.name_prefix}-soc"
  account_access_type      = "CURRENT_ACCOUNT"
  authentication_providers = ["SAML"]
  permission_type          = "SERVICE_MANAGED"
  role_arn                 = aws_iam_role.grafana.arn
  data_sources             = ["CLOUDWATCH", "ATHENA"]

  configuration = jsonencode({
    unifiedAlerting = { enabled = false }
    plugins         = { pluginAdminEnabled = false }
  })
}

resource "aws_grafana_workspace_saml_configuration" "keycloak" {
  workspace_id     = aws_grafana_workspace.soc.id
  idp_metadata_xml = sensitive(file(var.keycloak_saml_metadata_file))

  role_assertion  = "role"
  email_assertion = "email"
  login_assertion = "login"
  name_assertion  = "name"

  admin_role_values = var.grafana_admin_role_values
  # provider와 API 모두 최소 한 값을 요구한다. 기본값은 구성원 없는 전용
  # grafana-amg-editors group이라 /platform-users에 Editor 권한을 부여하지 않는다.
  editor_role_values = var.grafana_editor_role_values
}
