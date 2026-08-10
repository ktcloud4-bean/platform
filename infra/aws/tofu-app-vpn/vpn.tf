data "terraform_remote_state" "app_network" {
  backend = "s3"

  config = {
    bucket         = "ktcloud4-bean-opentofu-state-465137780685"
    key            = "platform/infra/aws/tofu-app-network/v1/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = "ktcloud4-bean-opentofu-locks"
    encrypt        = true
  }
}

data "terraform_remote_state" "shared_network" {
  backend = "s3"

  config = {
    bucket         = "ktcloud4-bean-opentofu-state-465137780685"
    key            = "platform/infra/aws/tofu-network/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = "ktcloud4-bean-opentofu-locks"
    encrypt        = true
  }
}

# App network root가 route table을 소유하고, 이 root는 VPN의 목적 route 한 개만 별도
# resource로 소유한다. `tofu-network`가 소유하는 단일 shared VPN의 selector는
# 10.10.0.0/16 ↔ 10.20.0.0/16이며, 이 root는 default route를 만들거나 VPN을 추가하지 않는다.
resource "aws_route" "to_onprem_management" {
  for_each = toset(data.terraform_remote_state.app_network.outputs.private_route_table_ids)

  route_table_id         = each.value
  destination_cidr_block = var.onprem_management_cidr
  gateway_id             = data.terraform_remote_state.shared_network.outputs.vpn_gateway_id
}
