locals {
  repositories = toset([
    "frontend",
    "employee-service",
    "hr-service",
    "bootstrap-argocd",
    "bootstrap-redis",
    "bootstrap-aws-load-balancer-controller",
    "bootstrap-kyverno",
    "bootstrap-kyvernopre",
    "bootstrap-kyverno-reports-controller",
  ])
}

resource "aws_ecr_repository" "service" {
  for_each = local.repositories

  name                 = "${local.name_prefix}-${each.key}"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  encryption_configuration {
    encryption_type = "AES256"
  }

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Argo CD, Redis, AWS Load Balancer Controller는 private EKS의 첫 GitOps 제어면을
# 구성한다. Jenkins mirror pipeline이 upstream digest를 검증한 뒤 이 별도 repository에
# push하며 HR application release 권한과 공유하지 않는다.

# Digest pinning으로 실행 중인 배포는 tag를 덮어쓰지 않는다. 롤백 가능한 최근 이미지와
# Cosign OCI artifact를 보존하기 위해 tagged 이미지는 90개까지 유지한다.
resource "aws_ecr_lifecycle_policy" "service" {
  for_each = aws_ecr_repository.service

  repository = each.value.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged image layers after 14 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 14
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Retain the 90 most recent immutable release tags"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 90
        }
        action = { type = "expire" }
      },
    ]
  })
}
