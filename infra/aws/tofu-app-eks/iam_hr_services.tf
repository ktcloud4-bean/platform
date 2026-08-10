data "terraform_remote_state" "app_db" {
  backend = "s3"

  config = {
    bucket         = "ktcloud4-bean-opentofu-state-465137780685"
    key            = "platform/infra/aws/tofu-app-db/v1/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = "ktcloud4-bean-opentofu-locks"
    encrypt        = true
  }
}

locals {
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

data "aws_iam_policy_document" "employee_service_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:hr-system:employee-service"]
    }
  }
}

resource "aws_iam_role" "employee_service" {
  name               = "${local.name_prefix}-employee-service-role"
  assume_role_policy = data.aws_iam_policy_document.employee_service_assume.json
}

resource "aws_iam_role_policy" "employee_service_database_secret" {
  name = "read-own-database-secret"
  role = aws_iam_role.employee_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = data.terraform_remote_state.app_db.outputs.employee_service_database_secret_arn
    }]
  })
}

data "aws_iam_policy_document" "hr_service_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:hr-system:hr-service"]
    }
  }
}

resource "aws_iam_role" "hr_service" {
  name               = "${local.name_prefix}-hr-service-role"
  assume_role_policy = data.aws_iam_policy_document.hr_service_assume.json
}

resource "aws_iam_role_policy" "hr_service_database_secret" {
  name = "read-own-database-secret"
  role = aws_iam_role.hr_service.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = data.terraform_remote_state.app_db.outputs.hr_service_database_secret_arn
    }]
  })
}

# 최초 migration은 master로 schema와 두 DB role을 만들지만, 실행 뒤에는 master secret을
# 서비스 Pod에 주지 않는다. Job ServiceAccount 하나로 subject를 고정한다.
data "aws_iam_policy_document" "db_migrate_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:hr-system:hr-db-migrate"]
    }
  }
}

resource "aws_iam_role" "db_migrate" {
  name               = "${local.name_prefix}-db-migrate-role"
  assume_role_policy = data.aws_iam_policy_document.db_migrate_assume.json
}

resource "aws_iam_role_policy" "db_migrate_database_secrets" {
  name = "read-bootstrap-and-service-database-secrets"
  role = aws_iam_role.db_migrate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        data.terraform_remote_state.app_db.outputs.aurora_master_user_secret_arn,
        data.terraform_remote_state.app_db.outputs.employee_service_database_secret_arn,
        data.terraform_remote_state.app_db.outputs.hr_service_database_secret_arn,
        data.terraform_remote_state.app_db.outputs.bootstrap_hr_admin_secret_arn,
      ]
    }]
  })
}

# Aurora managed master secret ARN에는 rotation suffix가 붙는다. migration Job은 cluster
# identifier 하나로 DescribeDBClusters를 수행해 그 ARN을 런타임에만 발견하며, 선언에는
# mutable secret ARN을 복사하지 않는다. AWS RDS Describe API는 resource-level 제한을 지원하지
# 않으므로 action 하나만 별도 wildcard로 둔다.
resource "aws_iam_role_policy" "db_migrate_aurora_discovery" {
  name = "discover-aurora-master-secret"
  role = aws_iam_role.db_migrate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["rds:DescribeDBClusters"]
      Resource = "*"
    }]
  })
}
