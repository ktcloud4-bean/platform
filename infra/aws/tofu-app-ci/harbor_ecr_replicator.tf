resource "aws_iam_user" "harbor_ecr_replicator" {
  name          = "${local.name_prefix}-harbor-ecr-replicator"
  path          = "/service/harbor/"
  force_destroy = false

  tags = {
    Name    = "${local.name_prefix}-harbor-ecr-replicator"
    Purpose = "Harbor scheduled ECR replication only"
  }
}

resource "aws_iam_user_policy" "harbor_ecr_replicator" {
  name = "${local.name_prefix}-ecr-replication-only"
  user = aws_iam_user.harbor_ecr_replicator.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrAuthorizationToken"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken", "sts:GetCallerIdentity"]
        Resource = "*"
      },
      {
        Sid    = "ReplicateOnlyHrImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = [for repository in data.aws_ecr_repository.hr_images : repository.arn]
      },
    ]
  })
}
