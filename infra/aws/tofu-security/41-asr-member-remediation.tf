# ASR 실제 remediation 런북 배포 - 27번 파일의 admin 템플릿은 오케스트레이터일
# 뿐, 실제로 finding을 고치는 런북(SSM Automation 문서)은 member-roles/member
# 템플릿 소유. Organizations 없이 단일 계정만 쓰더라도 이 계정 자신이 "member
# 계정 1개"로 취급되어 두 템플릿을 이 계정에 똑같이 배포해야 한다.
#
# admin 스택이 LoadSCAdminStack=yes로 떠 있으므로 member 쪽도 LoadSCMemberStack=yes로
# 맞춘다 - 어긋나면 orchestrator가 해당 control의 런북을 못 찾는다.

locals {
  # Namespace 파라미터는 S3 버킷 네이밍 규칙(3~9자)을 따라야 해서 name_prefix를
  # 못 쓴다. member-roles/member 두 스택 사이에서만 일치하면 되고 admin 스택과는 무관.
  # scripts/scenarios/08-asr-remediation.sh가 이 값 기준 IAM Role 이름
  # (SO0111-DisablePublicAccessForSecurityGroup-asrdemo)을 하드코딩하므로
  # project-c와 동일하게 "asrdemo" 유지 - 임의로 바꾸면 스크립트가 깨짐.
  asr_namespace = "asrdemo"
}

resource "aws_cloudformation_stack" "asr_member_roles" {
  count        = var.enable_asr_remediation ? 1 : 0
  name         = "${local.name_prefix}-asr-member-roles"
  template_url = "https://s3.amazonaws.com/solutions-reference/automated-security-response-on-aws/latest/automated-security-response-member-roles.template"
  capabilities = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"]

  parameters = {
    SecHubAdminAccount = data.aws_caller_identity.current.account_id
    Namespace          = local.asr_namespace
  }

  tags = {
    Name = "${local.name_prefix}-asr-member-roles"
  }
}

resource "aws_cloudformation_stack" "asr_member" {
  count        = var.enable_asr_remediation ? 1 : 0
  name         = "${local.name_prefix}-asr-member"
  template_url = "https://s3.amazonaws.com/solutions-reference/automated-security-response-on-aws/latest/automated-security-response-member.template"
  capabilities = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]

  parameters = {
    SecHubAdminAccount                    = data.aws_caller_identity.current.account_id
    Namespace                             = local.asr_namespace
    LogGroupName                          = aws_cloudwatch_log_group.cloudtrail.name
    EnableCloudTrailForASRActionLog       = "no" # 08-cloudtrail.tf의 CloudTrail 파이프라인이 이미 있음
    CreateS3BucketForRedshiftAuditLogging = "no"
    LoadSCMemberStack                     = "yes"
    LoadAFSBPMemberStack                  = "no"
    LoadCIS120MemberStack                 = "no"
    LoadCIS140MemberStack                 = "no"
    LoadCIS300MemberStack                 = "no"
    LoadNIST80053MemberStack              = "no"
    LoadPCI321MemberStack                 = "no"
  }

  tags = {
    Name = "${local.name_prefix}-asr-member"
  }

  depends_on = [aws_cloudformation_stack.asr_member_roles]
}

output "asr_member_stack_id" {
  value = var.enable_asr_remediation ? aws_cloudformation_stack.asr_member[0].id : "disabled (enable_asr_remediation=false)"
}
