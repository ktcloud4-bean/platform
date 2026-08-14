# S3 버킷 보안 강화 - cloudtrail_bucket/config_bucket은 이미 08/10번 파일에서
# SSL 강제+액세스 로깅 적용됨. 여기선 rds_audit_worm만 마저 정리.
# (project-c에 있던 session_logs/mtls_trust_store 하드닝은 없음 - platform-main은
# SSM Session Manager도 Pomerium mTLS ALB도 이 root가 소유하지 않음)

data "aws_iam_policy_document" "rds_audit_worm_ssl" {
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

resource "aws_s3_bucket_policy" "rds_audit_worm_ssl" {
  bucket = aws_s3_bucket.rds_audit_worm.id
  policy = data.aws_iam_policy_document.rds_audit_worm_ssl.json
}

resource "aws_s3_bucket_logging" "rds_audit_worm" {
  bucket        = aws_s3_bucket.rds_audit_worm.id
  target_bucket = aws_s3_bucket.s3_access_logs.id
  target_prefix = "s3-access-logs/rds-audit-worm/"
}

# 계정 레벨 무료 항목: EC2.7(EBS 기본 암호화)
resource "aws_ebs_encryption_by_default" "main" {
  enabled = true
}

# Security Hub IAM.18 대응 - AWS Support 인시던트 관리용 역할(존재 여부만 검사)
resource "aws_iam_role" "aws_support_access" {
  name = "${local.name_prefix}-aws-support-access-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "aws_support_access" {
  role       = aws_iam_role.aws_support_access.name
  policy_arn = "arn:aws:iam::aws:policy/AWSSupportAccess"
}
