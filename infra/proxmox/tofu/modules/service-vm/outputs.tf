output "vm_id" {
  description = "생성된 VM 의 VMID."
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  description = "VM 이름."
  value       = proxmox_virtual_environment_vm.this.name
}

output "node_name" {
  description = "VM 이 올라간 노드."
  value       = proxmox_virtual_environment_vm.this.node_name
}

output "configured_ipv4" {
  description = "cloud-init 으로 배정한 고정 주소. 게스트가 실제로 올린 주소는 아니다."
  value       = var.ipv4_address
}

output "vlan_id" {
  description = "네트워크 장치에 붙인 VLAN tag."
  value       = var.vlan_id
}

output "import_id" {
  description = "이 VM 을 state 에 다시 넣어야 할 때 쓸 import ID. 형식은 <node>/<vmid> 다."
  value       = "${var.node_name}/${var.vm_id}"
}
