# 5개 VM 을 한 번의 apply 로 만든다. VM-01 이 이 구성을 그대로 실행한다.
# gate 가 닫혀 있으면 local.vm_instances 가 비어 있어 아무것도 계획되지 않는다.
module "service_vm" {
  source   = "./modules/service-vm"
  for_each = local.vm_instances

  name        = each.key
  description = each.value.description
  vm_id       = each.value.vm_id
  tags        = sort(["opentofu", each.value.role])

  node_name      = var.proxmox_node_name
  datastore_id   = var.vm_datastore_id
  bridge         = var.vm_bridge
  template_vm_id = var.vm_template_id

  vcpu          = each.value.vcpu
  memory_mib    = each.value.memory_mib
  disk_gib      = each.value.disk_gib
  startup_order = each.value.startup_order

  vlan_id      = each.value.vlan_id
  ipv4_address = each.value.ipv4_cidr
  ipv4_gateway = each.value.ipv4_gateway

  # 각 VLAN 의 gateway 가 OPNsense Unbound 다 (docs/ip-plan.md "목표 방화벽 정책").
  dns_servers = [each.value.ipv4_gateway]
  dns_domain  = var.dns_domain

  cloud_init_username  = var.cloud_init_username
  ssh_public_keys      = var.ssh_public_keys
  user_data_file_id    = var.cloud_init_user_data_file_id
  cloud_init_interface = var.cloud_init_interface

  bios          = var.vm_bios
  machine       = var.vm_machine
  agent_enabled = var.agent_enabled
}

# ---------------------------------------------------------------------------
# 카탈로그 자체 검증
#
# check 블록은 plan 을 실패시키지 않고 경고를 낸다.
# 문서 원본과 코드가 어긋난 것을 apply 전에 눈에 보이게 하는 것이 목적이다.
# ---------------------------------------------------------------------------

check "vm_id_unique" {
  assert {
    condition     = length(distinct([for vm in local.vm_catalog : vm.vm_id])) == length(local.vm_catalog)
    error_message = "VMID 가 중복됐다. 카탈로그의 vm_id 를 확인한다."
  }
}

check "vm_id_follows_vlan_rule" {
  assert {
    condition = alltrue([
      for vm in local.vm_catalog : vm.vm_id >= 100 + vm.vlan_id && vm.vm_id < 100 + vm.vlan_id + 10
    ])
    error_message = "VMID 가 '100 + VLAN ID + 순번' 규칙을 벗어났다. VLAN 당 10대가 넘으면 규칙 자체를 다시 정한다."
  }
}

check "capacity_vcpu_budget" {
  assert {
    condition     = local.total_vcpu <= 24
    error_message = "배정 vCPU 합계가 docs/capacity-plan.md 의 경고선 24 를 넘었다. CAP 재검토 없이 늘리지 않는다."
  }
}

check "capacity_ram_budget" {
  assert {
    condition     = local.ram_allocation_gib <= 52
    error_message = "RAM 배정 합계(VM RAM + VM 당 0.20 GiB)가 docs/capacity-plan.md 의 경고선 52 GiB 를 넘었다."
  }
}

check "capacity_thin_provisioning_budget" {
  assert {
    condition     = local.total_disk_gib <= 714
    error_message = "프로비저닝 합계가 docs/capacity-plan.md 의 상한 714 GiB(풀의 90%)를 넘었다. CAP-02 전에는 과할당하지 않는다."
  }
}

check "vlan_matches_address" {
  assert {
    condition = alltrue([
      for vm in local.vm_catalog : startswith(vm.ipv4_cidr, "10.10.${vm.vlan_id}.")
    ])
    error_message = "주소의 세 번째 옥텟이 VLAN ID 와 다르다. docs/ip-plan.md 의 주소 규칙을 확인한다."
  }
}
