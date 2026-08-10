resource "aws_ecr_repository" "frontend" {
  name = "${local.name_prefix}-frontend-repo"
  # Jenkins·Cosign artifact는 digest와 tag의 대응을 보존해야 한다.
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_repository" "backend" {
  name                 = "${local.name_prefix}-backend-repo"
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }
}
