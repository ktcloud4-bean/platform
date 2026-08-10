output "vpn_gateway_id" {
  description = "AWS-NET-01이 소유한 shared VPC Virtual Private Gateway ID"
  value       = data.terraform_remote_state.shared_network.outputs.vpn_gateway_id
}
