data "aws_iam_policy_document" "kms_key" {
  # 계정 root principal이 IAM policy로 사용 권한을 위임하고 키를 복구할 수 있게 한다.
  # Vault service user는 이 key policy가 아니라 iam.tf의 exact-key policy로만 권한을 받는다.
  statement {
    sid       = "EnableAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:root"]
    }
  }
}

resource "aws_kms_key" "vault_auto_unseal" {
  description              = "KMS-01 Vault Community auto-unseal root key wrapping"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  multi_region             = false
  enable_key_rotation      = false
  deletion_window_in_days  = 30
  policy                   = data.aws_iam_policy_document.kms_key.json
}

resource "aws_kms_alias" "vault_auto_unseal" {
  name          = local.kms_alias_name
  target_key_id = aws_kms_key.vault_auto_unseal.key_id
}
