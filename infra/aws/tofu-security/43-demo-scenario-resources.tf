# 시나리오 8(ASR 오설정 탐지→Slack 1-Click 승인→원복) 전용 더미 리소스 -
# 실제 서비스와 무관한 격리된 대상. SSH 0.0.0.0/0 같은 오설정을 실제로
# 한 번 만들었다가 자동조치로 원복되는 걸 보여줘야 하는데, EKS 노드처럼
# 실제 트래픽을 받는 보안그룹에 이 실험을 하면 반복 검증마다 실제 서비스가
# 잠깐씩 노출된다 - 그래서 아무 인스턴스에도 안 붙는 이 더미 SG에서만 한다.
#
# 기본 상태(이 파일 그대로 apply한 상태)는 SSH 룰이 없는 정상 상태 -
# scripts/scenarios/08-asr-remediation.sh가 실행 중에만 0.0.0.0/0:22 룰을
# 추가했다가 ASR 자동조치(또는 스크립트 자체 안전장치)로 다시 제거한다.
resource "aws_security_group" "asr_demo_target" {
  name        = "${local.name_prefix}-asr-demo-target-sg"
  description = "Scenario 8 ASR remediation demo target - not attached to any instance"
  vpc_id      = data.terraform_remote_state.app_network.outputs.vpc_id

  tags = {
    Name    = "${local.name_prefix}-asr-demo-target-sg"
    Purpose = "asr-demo-scenario8"
  }
}

output "asr_demo_target_sg_id" {
  value = aws_security_group.asr_demo_target.id
}

# ---------- 시나리오 5: RDS IAM DB Auth 검증용 권한 ----------
# ⚠️ 전제조건(이 root 밖, tofu-app-db가 소유): Aurora 클러스터에
# iam_database_authentication_enabled=true가 켜져 있어야 한다. 확인한 시점
# 기준 tofu-app-db/rds.tf엔 이 설정이 없다(기본값 false) - 즉 이 시나리오는
# 아직 tofu-app-db 쪽 변경(라이브 프로덕션 Aurora 클러스터 수정) 없이는
# 실행할 수 없다. 이 파일은 그 전제가 충족된 뒤 필요한 IAM 권한만 미리 준비.
#
# EKS 노드 Role은 tofu-app-eks가 소유하고 이름을 output으로 안 내놓으므로,
# 결정론적 이름 규칙(${local.name_prefix}-eks-node-role)으로 직접 참조한다.
#
# ⚠️ rds-db:connect의 정확한 리소스 ARN은 Aurora 클러스터의 무작위 리소스 ID
# (DbClusterResourceId)가 있어야 하는데, tofu-app-db가 이 값을 output으로
# 안 내놓아서 project-f에서 계산할 수 없다. 정밀 스코핑하려면 tofu-app-db에
# aurora_cluster_resource_id 출력을 추가해야 한다(그 root 소관이라 여기서
# 직접 안 건드림) - 그 전까지는 "*"로 넓게 허용한다(계정/리전 안에서
# general_user_readonly/security_auditor_readonly 사용자명과 일치하는
# 다른 리소스가 생기지 않는 한 실질 위험은 낮음).
data "aws_iam_policy_document" "eks_node_rds_connect_demo" {
  statement {
    effect    = "Allow"
    actions   = ["rds-db:connect"]
    resources = ["arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:*/general_user_readonly", "arn:aws:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:*/security_auditor_readonly"]
  }
}

resource "aws_iam_role_policy" "eks_node_rds_connect_demo" {
  name   = "eks-node-rds-connect-scenario5-demo"
  role   = "${local.name_prefix}-eks-node-role"
  policy = data.aws_iam_policy_document.eks_node_rds_connect_demo.json
}
