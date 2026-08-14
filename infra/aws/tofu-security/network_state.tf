# tofu-app-network가 소유한 VPC/서브넷/SG를 가져온다 - 이 root는 새 VPC를
# 만들지 않고 기존 HR 네트워크에 올라탄다 (tofu-app-eks와 동일한 패턴).
data "terraform_remote_state" "app_network" {
  backend = "s3"

  config = {
    bucket = "ktcloud4-bean-opentofu-state-465137780685"
    key    = "platform/infra/aws/tofu-app-network/v1/terraform.tfstate"
    region = var.aws_region
  }
}

# tofu-network(VPN 소유 root)에서 onprem_cidr을 직접 가져온다 - tofu-app-network는
# 이 값을 재노출하지 않는다.
data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "ktcloud4-bean-opentofu-state-465137780685"
    key    = "platform/infra/aws/tofu-network/v1/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "app_db" {
  backend = "s3"

  config = {
    bucket = "ktcloud4-bean-opentofu-state-465137780685"
    key    = "platform/infra/aws/tofu-app-db/v1/terraform.tfstate"
    region = var.aws_region
  }
}

data "terraform_remote_state" "app_eks" {
  backend = "s3"

  config = {
    bucket = "ktcloud4-bean-opentofu-state-465137780685"
    key    = "platform/infra/aws/tofu-app-eks/v1/terraform.tfstate"
    region = var.aws_region
  }
}

# 시나리오 스크립트(scripts/scenarios/*.sh)의 tf_output 헬퍼가 쓰는 출력값들
output "rds_endpoint" {
  value = data.terraform_remote_state.app_db.outputs.aurora_writer_endpoint
}

output "eks_cluster_name" {
  value = data.terraform_remote_state.app_eks.outputs.eks_cluster_name
}

output "name_prefix" {
  value = local.name_prefix
}

output "onprem_keycloak_host" {
  value = var.onprem_keycloak_host
}

output "grafana_provisioning_user" {
  value = var.grafana_provisioning_user
}
