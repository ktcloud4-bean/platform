# AWS Config 관리형 규칙 - FSBP(10번 파일)가 대부분 커버하지만 명시적으로 켜서 확인

resource "aws_config_config_rule" "restricted_ssh" {
  name = "${local.name_prefix}-restricted-ssh"
  source {
    owner             = "AWS"
    source_identifier = "INCOMING_SSH_DISABLED"
  }
  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_config_rule" "restricted_common_ports" {
  name = "${local.name_prefix}-restricted-common-ports"
  source {
    owner             = "AWS"
    source_identifier = "RESTRICTED_INCOMING_TRAFFIC"
  }
  input_parameters = jsonencode({
    blockedPort1 = "3389"
    blockedPort2 = "22"
  })
  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_config_rule" "iam_user_unused_credentials" {
  name = "${local.name_prefix}-iam-user-unused-credentials"
  source {
    owner             = "AWS"
    source_identifier = "IAM_USER_UNUSED_CREDENTIALS_CHECK"
  }
  input_parameters = jsonencode({ maxCredentialUsageAge = "90" })
  depends_on        = [aws_config_configuration_recorder.main]
}

resource "aws_config_config_rule" "access_keys_rotated" {
  name = "${local.name_prefix}-access-keys-rotated"
  source {
    owner             = "AWS"
    source_identifier = "ACCESS_KEYS_ROTATED"
  }
  input_parameters = jsonencode({ maxAccessKeyAge = "90" })
  depends_on        = [aws_config_configuration_recorder.main]
}

# IMDSv2 강제는 못 함(Organizations/SCP 없음) - 탐지까지만
resource "aws_config_config_rule" "ec2_imdsv2_check" {
  name = "${local.name_prefix}-ec2-imdsv2-check"
  source {
    owner             = "AWS"
    source_identifier = "EC2_IMDSV2_CHECK"
  }
  depends_on = [aws_config_configuration_recorder.main]
}
