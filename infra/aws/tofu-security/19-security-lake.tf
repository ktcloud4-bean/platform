# Amazon Security Lake + VPC Flow Logs 네이티브 등록 - Grafana SOC 대시보드가
# Athena로 조회하는 OCSF 데이터의 원천.

variable "enable_security_lake" {
  description = "Security Lake 활성화 여부"
  type        = bool
  default     = false
}

variable "security_lake_retention_days" {
  description = "Security Lake 데이터 보존기간(일)"
  type        = number
  default     = 365
  validation {
    condition     = var.security_lake_retention_days > 30
    error_message = "security_lake_retention_days는 transition 설정(30일)보다 커야 합니다."
  }
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

resource "aws_iam_role_policy_attachment" "security_lake_metastore_lakeformation" {
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
      expiration {
        days = var.security_lake_retention_days
      }
      transition {
        days          = 30
        storage_class = "GLACIER"
      }
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.security_lake_metastore,
    aws_iam_role_policy_attachment.security_lake_metastore_lakeformation
  ]
}

# VPC_FLOW/SH_FINDINGS만 켠다: CLOUD_TRAIL_MGMT는 이 리전 조합 미지원,
# EKS_AUDIT은 별도 클러스터 설정이 없어 항상 비어있어 제외.
resource "aws_securitylake_aws_log_source" "vpc_flow" {
  count = var.enable_security_lake ? 1 : 0
  source {
    source_name = "VPC_FLOW"
    regions     = [var.aws_region]
  }
  depends_on = [aws_securitylake_data_lake.main]
}

resource "aws_securitylake_aws_log_source" "sh_findings" {
  count = var.enable_security_lake ? 1 : 0
  source {
    source_name = "SH_FINDINGS"
    regions     = [var.aws_region]
  }
  depends_on = [aws_securitylake_data_lake.main]
}

output "security_lake_arn" {
  value = var.enable_security_lake ? aws_securitylake_data_lake.main[0].arn : "disabled (enable_security_lake=false)"
}
