output "vpc_id" {
  description = "사설 착지점 VPC ID."
  value       = aws_vpc.onprem_link.id
}

output "vpc_cidr" {
  description = "AWS 쪽 대역. OPNsense child SA의 remote traffic selector와 같아야 한다."
  value       = aws_vpc.onprem_link.cidr_block
}

output "onprem_cidr" {
  description = "온프레미스 쪽 대역. OPNsense child SA의 local traffic selector와 같아야 한다."
  value       = var.onprem_cidr
}

output "private_subnet_id" {
  description = "VPN으로만 닿는 사설 서브넷 ID."
  value       = aws_subnet.private_a.id
}

output "vpn_gateway_id" {
  description = "Virtual Private Gateway ID. 이 자원 자체에는 시간당 요금이 없다."
  value       = aws_vpn_gateway.main.id
}

output "customer_gateway_id" {
  description = "Customer Gateway ID."
  value       = aws_customer_gateway.onprem.id
}

output "vpn_connection_id" {
  description = "Site-to-Site VPN Connection ID. gate가 닫혀 있으면 빈 문자열이다."
  value       = var.create_vpn_connection ? aws_vpn_connection.onprem[0].id : ""
}

output "tunnel1_address" {
  description = "터널 1의 AWS 쪽 공인 IP. OPNsense connection의 remote addresses에 넣는다."
  value       = var.create_vpn_connection ? aws_vpn_connection.onprem[0].tunnel1_address : ""
}

output "tunnel2_address" {
  description = <<-EOT
    터널 2의 AWS 쪽 공인 IP. 이번 구성에서는 OPNsense 쪽을 구성하지 않는다.
    AWS 터널 유지보수 때 단절될 수 있다는 한계는 runbook이 소유한다.
  EOT
  value       = var.create_vpn_connection ? aws_vpn_connection.onprem[0].tunnel2_address : ""
}

# PSK는 화면·로그·셸 기록에 남기지 않는다. README의 회수 절차대로
# 저장소 밖 mode 0600 파일로만 꺼내 OPNsense에 직접 입력한다.
output "tunnel1_preshared_key" {
  description = "터널 1 pre-shared key. 저장소 밖 mode 0600으로만 회수한다."
  value       = var.create_vpn_connection ? aws_vpn_connection.onprem[0].tunnel1_preshared_key : ""
  sensitive   = true
}

output "tunnel2_preshared_key" {
  description = "터널 2 pre-shared key. 이번에는 사용하지 않는다."
  value       = var.create_vpn_connection ? aws_vpn_connection.onprem[0].tunnel2_preshared_key : ""
  sensitive   = true
}

output "verify_instance_private_ip" {
  description = "검증 인스턴스의 사설 IP. gate가 닫혀 있으면 빈 문자열이다."
  value       = var.create_verify_instance ? aws_instance.verify[0].private_ip : ""
}

output "verify_marker" {
  description = "검증 인스턴스가 HTTP로 돌려주는 문자열. 비밀이 아니다."
  value       = local.verify_marker
}

output "verify_port" {
  description = "검증 인스턴스의 marker 응답 포트."
  value       = local.verify_port
}
