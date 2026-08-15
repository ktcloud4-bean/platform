data "aws_caller_identity" "current" {}

# Repository의 OpenTofu state를 CI에 열지 않는다. 같은 account/region의 정확한 세
# repository만 data source로 읽어 replicator policy resource를 산출한다.
data "aws_ecr_repository" "hr_images" {
  for_each = toset(["frontend", "employee-service", "hr-service"])

  name = "${local.name_prefix}-${each.value}"
}
