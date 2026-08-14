# Misconfiguration 자동조치 - Automated Security Response on AWS의 admin
# 템플릿을 aws_cloudformation_stack으로 감싼다. AWS Organizations를 안 쓰므로
# admin 템플릿 하나만 이 계정에 단독 배포하면 된다.
#
# 오케스트레이터(관리 뼈대)만 여기서 배포. 실제로 finding을 고쳐주는 런북은
# 41-asr-member-remediation.tf의 member-roles/member 템플릿 소유 - 그 파일이
# 같이 배포돼야 Security Hub Custom Action("ASRRemediation")을 눌렀을 때
# 실제로 finding이 고쳐진다.
#
# Web UI(CloudFront+Cognito)는 안 쓰므로 ShouldDeployWebUI="no" - 켜두면 계정
# 기본 Lambda 동시실행 할당량을 초과 요구해 스택 배포가 실패할 수 있음.

resource "aws_cloudformation_stack" "asr" {
  count        = var.enable_asr_remediation ? 1 : 0
  name         = "${local.name_prefix}-asr"
  template_url = var.asr_template_url
  capabilities = ["CAPABILITY_IAM", "CAPABILITY_NAMED_IAM", "CAPABILITY_AUTO_EXPAND"]

  parameters = {
    ShouldDeployWebUI = "no"
  }

  tags = {
    Name = "${local.name_prefix}-asr"
  }
}

# Security Hub CloudFormation.1(종료 보호) 대응 - aws_cloudformation_stack엔
# 관련 인자가 없어서 null_resource + local-exec로 우회. destroy 시엔 반대로
# 보호를 먼저 풀어야 삭제가 된다.
resource "null_resource" "asr_termination_protection" {
  count = var.enable_asr_remediation ? 1 : 0

  triggers = {
    stack_name = aws_cloudformation_stack.asr[0].name
    region     = var.aws_region
  }

  provisioner "local-exec" {
    command = "aws cloudformation update-termination-protection --enable-termination-protection --stack-name ${self.triggers.stack_name} --region ${self.triggers.region}"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "aws cloudformation update-termination-protection --no-enable-termination-protection --stack-name ${self.triggers.stack_name} --region ${self.triggers.region} || true"
  }
}

# ASR이 SNS 알림을 자체 생성하지만, 23-security-alerting.tf 파이프라인으로도
# 흘러가게 하려면 배포 완료 후 콘솔에서 ASR의 SNS 토픽에
# aws_sns_topic.security_alerts를 구독시키는 별도 작업이 필요함(ASR 스택이
# 만드는 리소스 이름은 apply 후 출력값으로 확인).

output "asr_stack_id" {
  value = var.enable_asr_remediation ? aws_cloudformation_stack.asr[0].id : "disabled (enable_asr_remediation=false)"
}
