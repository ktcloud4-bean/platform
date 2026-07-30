output "vm_creation_ready" {
  description = "5개 VM 을 apply 할 수 있는 상태인지 여부. false 이면 이 구성은 아무것도 계획하지 않는다."
  value       = local.vm_creation_ready
}

output "blocked_by" {
  description = "VM 생성을 막고 있는 선행 조건. 비어 있으면 gate 가 모두 열린 것이다."
  value       = local.blocked_by
}

output "planned_vms" {
  description = "이번 apply 가 만들 VM. gate 가 닫혀 있으면 빈 map 이다."
  value = {
    for name, vm in local.vm_instances : name => {
      vm_id     = vm.vm_id
      vcpu      = vm.vcpu
      memory    = "${vm.memory_mib / 1024} GiB"
      disk      = "${vm.disk_gib} GiB"
      vlan      = vm.vlan_id
      ipv4      = vm.ipv4_cidr
      datastore = var.vm_datastore_id
    }
  }
}

output "capacity_footprint" {
  description = "카탈로그 전체의 자원 합계. docs/capacity-plan.md 의 Day 1 합계·정지 기준과 대조한다."
  value = {
    vm_count           = length(local.vm_catalog)
    vcpu               = local.total_vcpu
    memory_gib         = local.total_memory_mib / 1024
    ram_allocation_gib = local.ram_allocation_gib
    disk_gib           = local.total_disk_gib
  }
}

output "state_ownership" {
  description = "이 state 가 소유하는 것과 소유하지 않는 것. import 경계의 요약이다."
  value = {
    owned = "proxmox_virtual_environment_vm (5대) 와 그 VM 이 만든 디스크·cloud-init 디스크뿐"
    not_owned = [
      "Proxmox 노드 ${var.proxmox_node_name}",
      "datastore ${var.vm_datastore_id} 와 local",
      "bridge ${var.vm_bridge} 와 VLAN 인터페이스",
      "OS-01 template (VMID ${var.vm_template_id == null ? "미확정" : tostring(var.vm_template_id)})",
      "OPNsense 의 모든 자원",
    ]
  }
}
