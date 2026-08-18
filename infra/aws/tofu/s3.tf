# 오프사이트 사본 착지점.
# 이 bucket은 온프레미스 SeaweedFS와 물리 장애 도메인을 공유하지 않는 최종 사본이다.
# 원본을 지우는 동기화는 하지 않는다. 삭제 권한을 전송 identity에 주지 않는 것으로 강제한다.
resource "aws_s3_bucket" "offsite" {
  bucket        = local.bucket_name
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "offsite" {
  bucket = aws_s3_bucket.offsite.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ACL 경로를 아예 닫는다. 접근 제어는 bucket policy와 IAM policy만으로 표현한다.
resource "aws_s3_bucket_ownership_controls" "offsite" {
  bucket = aws_s3_bucket.offsite.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# 덮어쓰기와 손상에서 되돌릴 수 있어야 오프사이트 사본이 의미를 가진다.
resource "aws_s3_bucket_versioning" "offsite" {
  bucket = aws_s3_bucket.offsite.id

  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3(AES256)을 쓴다. KMS는 Vault auto-unseal 후보(KMS-01)와 얽히고 요청당 비용이 붙는다.
# 복구 자격증명이 복구 대상에 의존하는 순환을 만들지 않는다.
resource "aws_s3_bucket_server_side_encryption_configuration" "offsite" {
  bucket = aws_s3_bucket.offsite.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "offsite" {
  bucket = aws_s3_bucket.offsite.id

  # versioning을 켜면 이전 version이 무한히 쌓인다. 복구 창을 넘긴 것만 만료시킨다.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }
  }

  # 중단된 multipart 조각은 목록에 보이지 않으면서 요금만 만든다.
  rule {
    id     = "abort-incomplete-multipart-upload"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = var.abort_incomplete_multipart_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.offsite]
}

data "aws_iam_policy_document" "offsite_bucket" {
  # 평문 HTTP로 오는 모든 요청을 거부한다.
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:*"]
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # SSE 헤더를 붙이되 AES256이 아닌 업로드를 거부한다.
  # 헤더가 아예 없는 요청은 bucket 기본 암호화가 처리하므로 Null guard로 제외한다.
  # guard가 없으면 헤더 없는 정상 업로드까지 거부되어 백업이 조용히 멈춘다.
  statement {
    sid    = "DenyWrongServerSideEncryption"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions   = ["s3:PutObject"]
    resources = ["${local.bucket_arn}/*"]

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["false"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["AES256"]
    }
  }
}

resource "aws_s3_bucket_policy" "offsite" {
  bucket = aws_s3_bucket.offsite.id
  policy = data.aws_iam_policy_document.offsite_bucket.json

  # public access block보다 먼저 policy가 붙으면 평가 순서가 꼬일 수 있다.
  depends_on = [aws_s3_bucket_public_access_block.offsite]
}
