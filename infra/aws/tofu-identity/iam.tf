resource "aws_iam_saml_provider" "keycloak_platform" {
  name                   = var.saml_provider_name
  saml_metadata_document = file(var.saml_metadata_file)

}

data "aws_iam_policy_document" "saml_trust" {
  statement {
    sid     = "AllowOnlyKeycloakPlatformSamlConsole"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithSAML"]

    principals {
      type = "Federated"
      # ARN을 var에서 결정해 plan 단계에도 trust 원문을 검토할 수 있게 한다.
      # 실제 create 순서는 각 role의 depends_on으로 provider 뒤에 고정한다.
      identifiers = [local.provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "SAML:aud"
      values   = [local.aws_console_recipient]
    }
  }
}

resource "aws_iam_role" "observer" {
  name                 = local.role_names.observer
  description          = "AWS-ID-02: Keycloak SAML inventory reader temporary role"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.saml_trust.json

  depends_on = [aws_iam_saml_provider.keycloak_platform]

}

resource "aws_iam_role" "observability_reader" {
  name                 = local.role_names.observability_reader
  description          = "AWS-ID-02: Keycloak SAML observability reader temporary role"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.saml_trust.json

  depends_on = [aws_iam_saml_provider.keycloak_platform]

}

resource "aws_iam_role" "security_reader" {
  name                 = local.role_names.security_reader
  description          = "AWS-ID-02: Keycloak SAML security reader temporary role"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.saml_trust.json

  depends_on = [aws_iam_saml_provider.keycloak_platform]

}

resource "aws_iam_role" "identity_reader" {
  name                 = local.role_names.identity_reader
  description          = "AWS-ID-01: Keycloak SAML privileged identity-read temporary role"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.saml_trust.json

  depends_on = [aws_iam_saml_provider.keycloak_platform]

}

data "aws_iam_policy_document" "observer_permissions" {
  statement {
    sid    = "ReadOnlyPrivateNetworkInventory"
    effect = "Allow"
    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeCustomerGateways",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcAttribute",
      "ec2:DescribeVpcClassicLink",
      "ec2:DescribeVpcClassicLinkDnsSupport",
      "ec2:DescribeVpcPeeringConnections",
      "ec2:DescribeVpcs",
      "ec2:DescribeVpnConnections",
      "ec2:DescribeVpnGateways",
    ]
    resources = ["*"]
  }

  # 이 호출은 현재 세션이 role session임을 사용자가 스스로 확인할 때만 쓴다.
  statement {
    sid       = "IdentifyCurrentTemporarySession"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }

  statement {
    sid    = "ReadOnlyWorkloadInventory"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeTags",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "eks:DescribeAddon",
      "eks:DescribeCluster",
      "eks:DescribeNodegroup",
      "eks:ListAddons",
      "eks:ListClusters",
      "eks:ListNodegroups",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetHealth",
      "rds:DescribeDBClusters",
      "rds:DescribeDBInstances",
      "rds:DescribeDBSubnetGroups",
      "tag:GetResources",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "observer_permissions" {
  name   = "AWSID01ObserverReadOnly"
  role   = aws_iam_role.observer.id
  policy = data.aws_iam_policy_document.observer_permissions.json
}

data "aws_iam_policy_document" "observability_reader_permissions" {
  statement {
    sid    = "ReadOnlyCloudWatchMetricsAndAlarms"
    effect = "Allow"
    actions = [
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:GetDashboard",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListDashboards",
      "cloudwatch:ListMetrics",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadOnlyCloudWatchLogsQueries"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
      "logs:GetQueryResults",
      "logs:StartQuery",
      "logs:StopQuery",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "observability_reader_permissions" {
  name   = "AWSID02ObservabilityReadOnly"
  role   = aws_iam_role.observability_reader.id
  policy = data.aws_iam_policy_document.observability_reader_permissions.json
}

data "aws_iam_policy_document" "security_reader_permissions" {
  statement {
    sid    = "ReadOnlySecurityPosture"
    effect = "Allow"
    actions = [
      "access-analyzer:GetAnalyzer",
      "access-analyzer:GetFinding",
      "access-analyzer:ListAnalyzers",
      "access-analyzer:ListFindings",
      "cloudtrail:DescribeTrails",
      "cloudtrail:GetTrailStatus",
      "cloudtrail:LookupEvents",
      "iam:GetAccountSummary",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:GetSAMLProvider",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
      "iam:ListRoles",
      "iam:ListSAMLProviders",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "security_reader_permissions" {
  name   = "AWSID02SecurityReadOnly"
  role   = aws_iam_role.security_reader.id
  policy = data.aws_iam_policy_document.security_reader_permissions.json
}

data "aws_iam_policy_document" "identity_reader_permissions" {
  source_policy_documents = [data.aws_iam_policy_document.observer_permissions.json]

  statement {
    sid    = "ReadOnlyFederationConfiguration"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListRolePolicies",
    ]
    resources = values(local.role_arns)
  }

  statement {
    sid       = "ListAndReadOnlyThisSamlProvider"
    effect    = "Allow"
    actions   = ["iam:ListSAMLProviders"]
    resources = ["*"]
  }

  statement {
    sid       = "ReadOnlyThisSamlProvider"
    effect    = "Allow"
    actions   = ["iam:GetSAMLProvider"]
    resources = [local.provider_arn]
  }
}

resource "aws_iam_role_policy" "identity_reader_permissions" {
  name   = "AWSID01IdentityReadOnly"
  role   = aws_iam_role.identity_reader.id
  policy = data.aws_iam_policy_document.identity_reader_permissions.json
}
