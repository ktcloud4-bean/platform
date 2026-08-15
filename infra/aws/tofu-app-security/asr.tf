# AWS-SEC-05: Automated Security Response on AWS (ASR) 자동 원복 배포
#
# 1. Admin 스택: Orchestrator 및 Security Hub Custom Action ("ASRRemediation") 배포.
# 2. Member Roles 스택: SSM Automation 실행용 IAM Role 배포.
# 3. Member 스택: Standard Controls 런북 (Security Hub findings 자동조치) 배포.
# 4. 종료 보호: Security Hub CloudFormation.1 통제를 준수하여 3개 스택 모두 종료 보호 적용.
# 5. 더미 보안그룹: 실제 워크로드에 영향을 주지 않고 오설정 자동 원복을 검증할 격리된 타깃 SG.

locals {
  # ASR Namespace 파라미터는 S3 버킷 네이밍 규칙(3~9자)을 따라야 하므로 "asrdemo" 고정
  asr_namespace = var.asr_namespace
}

# --- 1. ASR Admin Template S3 Upload & Admin Stack ---
# AWS 계정의 기본 Lambda 동시성 할당량(10) 제약 하에서, 원본 ASR 템플릿의
# ReservedConcurrentExecutions(1, 5)는 Unreserved 동시성을 10 미만으로 떨어뜨려
# Lambda 생성 실패를 유발한다. 따라서 해당 속성을 제거한 curated 템플릿을 S3에 업로드하여 배포한다.
resource "aws_s3_object" "asr_admin_template" {
  count  = var.enable_asr_remediation ? 1 : 0
  bucket = "ktcloud4-bean-opentofu-state-465137780685"
  key    = "platform/templates/automated-security-response-admin-curated.template"
  source = "${path.module}/templates/automated-security-response-admin.template"
  etag   = filemd5("${path.module}/templates/automated-security-response-admin.template")

  tags = {
    Name    = "${local.name_prefix}-asr-admin-curated-template"
    Project = var.project_name
    Env     = var.environment
  }
}

resource "aws_cloudformation_stack" "asr" {
  count        = var.enable_asr_remediation ? 1 : 0
  name         = "${local.name_prefix}-asr"
  template_url = "https://${aws_s3_object.asr_admin_template[0].bucket}.s3.${var.aws_region}.amazonaws.com/${aws_s3_object.asr_admin_template[0].key}"
  capabilities = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]

  parameters = {
    ShouldDeployWebUI = "no"
  }

  tags = {
    Name    = "${local.name_prefix}-asr"
    Project = var.project_name
    Env     = var.environment
  }

  depends_on = [aws_s3_object.asr_admin_template]
}

# --- 2. ASR Member Roles Stack ---
resource "aws_cloudformation_stack" "asr_member_roles" {
  count        = var.enable_asr_remediation ? 1 : 0
  name         = "${local.name_prefix}-asr-member-roles"
  template_url = "https://solutions-reference.s3.amazonaws.com/automated-security-response-on-aws/latest/automated-security-response-member-roles.template"
  capabilities = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM"]

  parameters = {
    SecHubAdminAccount = data.aws_caller_identity.current.account_id
    Namespace          = local.asr_namespace
  }

  tags = {
    Name    = "${local.name_prefix}-asr-member-roles"
    Project = var.project_name
    Env     = var.environment
  }

  depends_on = [aws_cloudformation_stack.asr]
}

# --- 3. ASR Member Stack (Remediation Runbooks) ---
resource "aws_cloudformation_stack" "asr_member" {
  count        = var.enable_asr_remediation ? 1 : 0
  name         = "${local.name_prefix}-asr-member"
  template_url = "https://solutions-reference.s3.amazonaws.com/automated-security-response-on-aws/latest/automated-security-response-member.template"
  capabilities = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]

  parameters = {
    SecHubAdminAccount                    = data.aws_caller_identity.current.account_id
    Namespace                             = local.asr_namespace
    LogGroupName                          = local.cloudtrail_log_group_name
    EnableCloudTrailForASRActionLog       = "no"
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
    Name    = "${local.name_prefix}-asr-member"
    Project = var.project_name
    Env     = var.environment
  }

  depends_on = [aws_cloudformation_stack.asr_member_roles]
}

# --- 4. 종료 보호 (Termination Protection) ---
resource "null_resource" "asr_termination_protection" {
  count = var.enable_asr_remediation ? 1 : 0

  triggers = {
    admin_stack        = aws_cloudformation_stack.asr[0].name
    member_roles_stack = aws_cloudformation_stack.asr_member_roles[0].name
    member_stack       = aws_cloudformation_stack.asr_member[0].name
    region             = var.aws_region
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws cloudformation update-termination-protection --enable-termination-protection --stack-name ${self.triggers.admin_stack} --region ${self.triggers.region}
      aws cloudformation update-termination-protection --enable-termination-protection --stack-name ${self.triggers.member_roles_stack} --region ${self.triggers.region}
      aws cloudformation update-termination-protection --enable-termination-protection --stack-name ${self.triggers.member_stack} --region ${self.triggers.region}
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name ${self.triggers.admin_stack} --region ${self.triggers.region} || true
      aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name ${self.triggers.member_roles_stack} --region ${self.triggers.region} || true
      aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name ${self.triggers.member_stack} --region ${self.triggers.region} || true
    EOT
  }

  depends_on = [
    aws_cloudformation_stack.asr,
    aws_cloudformation_stack.asr_member_roles,
    aws_cloudformation_stack.asr_member
  ]
}

# --- 5. 더미 보안그룹 (시연 전용, 인스턴스 미부착) ---
resource "aws_security_group" "asr_demo_target" {
  name        = "${local.name_prefix}-asr-demo-target-sg"
  description = "Scenario 8 ASR remediation demo target - not attached to any instance"
  vpc_id      = data.terraform_remote_state.app_network.outputs.vpc_id

  tags = {
    Name    = "${local.name_prefix}-asr-demo-target-sg"
    Purpose = "asr-demo-scenario8"
    Project = var.project_name
    Env     = var.environment
  }
}
