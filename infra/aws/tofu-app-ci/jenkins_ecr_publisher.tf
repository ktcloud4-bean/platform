data "aws_caller_identity" "current" {}

# Repository의 OpenTofu state를 CI에 열지 않는다. 같은 account/region의 정확한 세
# repository만 data source로 읽어 publisher policy resource를 산출한다.
data "aws_ecr_repository" "hr_images" {
  for_each = toset(["frontend", "employee-service", "hr-service"])

  name = "${local.name_prefix}-${each.value}"
}

resource "aws_iam_user" "jenkins_ecr_publisher" {
  name          = "${local.name_prefix}-jenkins-ecr-publisher"
  path          = "/service/jenkins/"
  force_destroy = false

  tags = {
    Name    = "${local.name_prefix}-jenkins-ecr-publisher"
    Purpose = "Jenkins signed HR image publisher only"
  }
}

resource "aws_iam_user_policy" "jenkins_ecr_publisher" {
  name = "${local.name_prefix}-ecr-publish-only"
  user = aws_iam_user.jenkins_ecr_publisher.name

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
        Sid    = "PublishOnlyHrImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          # Cosign verify는 ECR signature manifest가 참조하는 blob을 내려받는다.
          # 대상은 image 세 repository로만 제한하며, 임의 registry read는 허용하지 않는다.
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
