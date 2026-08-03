resource "aws_iam_user" "vault_auto_unseal" {
  name = local.iam_user_name
  path = "/service/"
}

data "aws_iam_policy_document" "vault_auto_unseal" {
  statement {
    sid    = "UseOnlyVaultAutoUnsealKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
    ]
    resources = [aws_kms_key.vault_auto_unseal.arn]
  }
}

# false는 KMS-01 장애 시험에서 이 policy 하나만 결정론적으로 회수한다.
# user/access key/KMS key는 유지하므로 true 재적용이 즉시 rollback이다.
resource "aws_iam_user_policy" "vault_auto_unseal" {
  count = var.enable_vault_kms_access ? 1 : 0

  name   = "VaultAutoUnsealExactKey"
  user   = aws_iam_user.vault_auto_unseal.name
  policy = data.aws_iam_policy_document.vault_auto_unseal.json
}

# 온프레미스 k3s에는 instance profile이 없으므로 전용 service user key를 쓴다.
# secret은 이 root의 외부 state와 $KTC_SECRET_ROOT/kms-01/env에만 회수한다.
resource "aws_iam_access_key" "vault_auto_unseal" {
  user = aws_iam_user.vault_auto_unseal.name
}
