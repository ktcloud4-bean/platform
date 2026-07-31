# 오프사이트 전송 전용 identity.
# 사람이 쓰는 admin 자격증명과 분리하고, 온프레미스 host에 두는 것은 이 key뿐이다.
resource "aws_iam_user" "backup" {
  name = var.backup_user_name
  path = "/service/"
}

data "aws_iam_policy_document" "backup" {
  # 전송에 필요한 bucket 단위 조회만 연다.
  statement {
    sid    = "ListOffsiteBucket"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions",
      "s3:ListBucketMultipartUploads",
      "s3:GetBucketLocation",
    ]

    resources = [local.bucket_arn]
  }

  # 쓰기와 검증용 읽기만 연다. 삭제 action은 넣지 않는다.
  # 이것이 "원본을 지우는 동기화"와 랜섬웨어성 일괄 삭제를 막는 실제 경계다.
  statement {
    sid    = "WriteAndVerifyOffsiteObjects"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]

    resources = ["${local.bucket_arn}/*"]
  }

  # 나중에 더 넓은 policy가 붙어도 삭제와 보호 설정 해제가 열리지 않게 한다.
  statement {
    sid    = "DenyDeleteAndProtectionChanges"
    effect = "Deny"

    actions = [
      "s3:DeleteObject",
      "s3:DeleteObjectVersion",
      "s3:DeleteBucket",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutLifecycleConfiguration",
      "s3:PutBucketPolicy",
      "s3:PutEncryptionConfiguration",
      "s3:PutBucketPublicAccessBlock",
    ]

    resources = [local.bucket_arn, "${local.bucket_arn}/*"]
  }

  # 실패 경보 발행 권한. 이 topic 하나에만 준다.
  statement {
    sid       = "PublishFailureAlert"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alert.arn]
  }

  # job이 아예 돌지 않는 상황을 잡는 heartbeat metric.
  # PutMetricData는 resource ARN을 지원하지 않으므로 namespace 조건으로 좁힌다.
  statement {
    sid       = "PublishHeartbeatMetric"
    effect    = "Allow"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [var.heartbeat_metric_namespace]
    }
  }
}

resource "aws_iam_user_policy" "backup" {
  name   = "${var.backup_user_name}-offsite"
  user   = aws_iam_user.backup.name
  policy = data.aws_iam_policy_document.backup.json
}

# secret은 생성 시점에만 평문으로 나온다. 이 root의 state에 남으므로
# state 파일은 저장소 밖 mode 0600으로만 보관한다. README의 회수 절차를 따른다.
resource "aws_iam_access_key" "backup" {
  count = var.create_backup_access_key ? 1 : 0

  user = aws_iam_user.backup.name
}
