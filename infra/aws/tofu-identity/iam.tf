resource "aws_iam_saml_provider" "keycloak_platform" {
  name                   = var.saml_provider_name
  saml_metadata_document = file(var.saml_metadata_file)

  lifecycle {
    # 인증서 교체는 metadata file 갱신 후 update로 처리한다. 삭제는 Keycloak client
    # 비활성화와 별도 폐기 plan을 확인한 사람이 이 보호를 명시적으로 풀어야 한다.
    prevent_destroy = true
  }
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
  description          = "AWS-ID-01: Keycloak SAML daily observer temporary role"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.saml_trust.json

  depends_on = [aws_iam_saml_provider.keycloak_platform]

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role" "identity_reader" {
  name                 = local.role_names.identity_reader
  description          = "AWS-ID-01: Keycloak SAML privileged identity-read temporary role"
  max_session_duration = 3600
  assume_role_policy   = data.aws_iam_policy_document.saml_trust.json

  depends_on = [aws_iam_saml_provider.keycloak_platform]

  lifecycle {
    prevent_destroy = true
  }
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
}

resource "aws_iam_role_policy" "observer_permissions" {
  name   = "AWSID01ObserverReadOnly"
  role   = aws_iam_role.observer.id
  policy = data.aws_iam_policy_document.observer_permissions.json
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
