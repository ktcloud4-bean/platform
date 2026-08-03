locals {
  # -------------------------------------------------------------------------
  # VM 카탈로그
  #
  # 값의 단일 원본은 문서다. 여기는 그 값을 실행 가능한 형태로 옮긴 구현이며
  # 문서에 같은 표를 다시 쓰지 않는다.
  #
  #   vcpu · memory_mib · disk_gib  ← docs/capacity-plan.md "VM 기준표"와 작업별 증설 기록
  #   vlan_id · ipv4_*              ← docs/ip-plan.md "목표 VLAN"·"고정 배정"
  #   name                          ← docs/ip-plan.md "DNS와 도메인"의 canonical host
  #   role                          ← docs/ip-plan.md "목표 VLAN"의 이름을 소문자로. Proxmox 태그에만 쓴다
  #
  # 문서 값이 바뀌면 이 블록을 고치고 plan 으로 차이를 확인한다.
  # -------------------------------------------------------------------------

  # VMID 규칙: 100 + VLAN ID + 해당 VLAN 안의 순번(0 부터).
  # 예) VLAN 50 의 첫 VM = 150, 두 번째 = 151. VLAN 20 의 첫 VM = 120.
  # Proxmox 예약 범위를 피하려고 100 에서 시작하고, VMID 만 보고 VM 의 신뢰 경계를 알 수 있게 한다.
  # 이 규칙은 VLAN 당 10대까지만 유효하다. 넘어가면 이웃 VLAN 대역과 겹치므로 규칙을 다시 정한다.
  vm_catalog = {
    "k3s-01" = {
      vm_id         = 120
      role          = "platform"
      vcpu          = 8
      memory_mib    = 28672 # 28 GiB; CAP-03
      disk_gib      = 200
      vlan_id       = 20
      ipv4_cidr     = "10.10.20.10/24"
      ipv4_gateway  = "10.10.20.1"
      startup_order = 2
      description   = "단일 서버 k3s. 플랫폼 워크로드와 GitOps."
    }

    "postgres-01" = {
      vm_id         = 150
      role          = "data"
      vcpu          = 4
      memory_mib    = 8192 # 8 GiB
      disk_gib      = 100
      vlan_id       = 50
      ipv4_cidr     = "10.10.50.10/24"
      ipv4_gateway  = "10.10.50.1"
      startup_order = 1
      description   = "공용 PostgreSQL. 서비스별 DB·role."
    }

    "object-01" = {
      vm_id         = 151
      role          = "data"
      vcpu          = 2
      memory_mib    = 4096 # 4 GiB
      disk_gib      = 200
      vlan_id       = 50
      ipv4_cidr     = "10.10.50.20/24"
      ipv4_gateway  = "10.10.50.1"
      startup_order = 1
      description   = "SeaweedFS S3 오브젝트 저장소. 로컬 백업 착지점."
    }

    "warpgate-01" = {
      vm_id         = 130
      role          = "access"
      vcpu          = 2
      memory_mib    = 2048 # 2 GiB
      disk_gib      = 40
      vlan_id       = 30
      ipv4_cidr     = "10.10.30.10/24"
      ipv4_gateway  = "10.10.30.1"
      startup_order = 3
      description   = "특권 세션 중계."
    }

    "netbird-01" = {
      vm_id         = 140
      role          = "dmz"
      vcpu          = 2
      memory_mib    = 2048 # 2 GiB
      disk_gib      = 32
      vlan_id       = 40
      ipv4_cidr     = "10.10.40.10/24"
      ipv4_gateway  = "10.10.40.1"
      startup_order = 3
      description   = "원격접속 제어면. 인터넷에 닿는 진입면."
    }
  }

  # -------------------------------------------------------------------------
  # 선행 작업 gate
  #
  # 두 gate 가 모두 열려야 VM 을 선언한다. 이것이 apply 차단 지점이다.
  # -------------------------------------------------------------------------

  os_template_ready = var.vm_template_id != null
  vlan_ready        = var.vlan_trunk_ready
  ssh_access_ready  = length(var.ssh_public_keys) > 0 || var.cloud_init_user_data_file_id != null

  vm_creation_ready = local.os_template_ready && local.vlan_ready && local.ssh_access_ready

  vm_instances = local.vm_creation_ready ? local.vm_catalog : {}

  blocked_by = compact([
    local.os_template_ready ? "" : "OS-01: vm_template_id 미확정",
    local.vlan_ready ? "" : "NET-02·NET-03: vlan_trunk_ready = false",
    local.ssh_access_ready ? "" : "ssh_public_keys 또는 cloud_init_user_data_file_id 미지정",
  ])

  # -------------------------------------------------------------------------
  # 자원 합계 — docs/capacity-plan.md 대조용
  # -------------------------------------------------------------------------

  total_vcpu       = sum([for vm in local.vm_catalog : vm.vcpu])
  total_memory_mib = sum([for vm in local.vm_catalog : vm.memory_mib])
  total_disk_gib   = sum([for vm in local.vm_catalog : vm.disk_gib])

  # 배정 합계 = VM RAM 합 + VM 당 QEMU 오버헤드 0.20 GiB (capacity-plan "RAM 예산")
  ram_allocation_gib = (local.total_memory_mib / 1024) + (length(local.vm_catalog) * 0.2)
}
