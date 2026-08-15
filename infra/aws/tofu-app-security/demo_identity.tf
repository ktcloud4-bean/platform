# AWS-SEC-04: 격리 데모 아이덴티티
# 세션 종료 시나리오(시나리오 10) 및 CIEM 권한 드리프트/축소 시나리오(시나리오 11) 대상
# 데모 전용 SAML Role. tofu-identity 관리 리소스와 소유권 중복이 없다.

data "aws_iam_policy_document" "demo_saml_trust" {
  statement {
    sid     = "AllowOnlyKeycloakPlatformSamlDemo"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithSAML"]

    principals {
      type        = "Federated"
      identifiers = [local.saml_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "SAML:aud"
      values   = [local.aws_console_recipient]
    }
  }

  statement {
    sid     = "AllowAccountAdminAssumeForTesting"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

resource "aws_iam_role" "demo_saml" {
  name                 = local.demo_saml_role_name
  description          = "AWS-SEC-04: Keycloak SAML isolated demo operator role for CIEM and session revocation"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.demo_saml_trust.json

  tags = {
    Name    = local.demo_saml_role_name
    Purpose = "ciem-and-session-revocation-demo"
  }
}

# 데모 Role의 초기 권한: CIEM 축소 시나리오에서 미사용 권한 식별 및 축소 정책 생성을 검증하기 위해
# 광범위한 읽기 권한을 포함한다. 실제 검증 시 일부 액션(예: ec2:Describe*)만 호출하고
# Access Analyzer가 미사용 권한을 제외한 축소 정책을 생성하게 된다.
data "aws_iam_policy_document" "demo_saml_permissions" {
  statement {
    sid    = "ReadOnlyWorkloadInventory"
    effect = "Allow"
    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeRegions",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeVpcs",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "IdentifyCurrentSession"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    sid    = "UnusedDemoServices"
    effect = "Allow"
    actions = [
      "s3:ListAllMyBuckets",
      "s3:ListBucket",
      "s3:GetObject",
      "rds:DescribeDBClusters",
      "rds:DescribeDBInstances",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:GetMetricData",
      "cloudwatch:ListMetrics",
      "logs:DescribeLogGroups",
      "logs:FilterLogEvents",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "demo_saml_permissions" {
  name   = "AWSSEC04DemoPermissions"
  role   = aws_iam_role.demo_saml.id
  policy = data.aws_iam_policy_document.demo_saml_permissions.json
}
