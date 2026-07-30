resource "proxmox_virtual_environment_vm" "this" {
  node_name   = var.node_name
  vm_id       = var.vm_id
  name        = var.name
  description = var.description
  tags        = var.tags

  # --- 전원·수명주기 --------------------------------------------------------
  on_boot         = true
  started         = true
  stop_on_destroy = var.stop_on_destroy
  protection      = false

  # 오프라인이 필요한 변경은 자동으로 적용하지 않는다.
  # 실패하게 두고 사람이 정지 시점을 정한다 (README.md "계층별 Git의 역할").
  reboot_after_update = false

  # --- 하드웨어 기준선 -------------------------------------------------------
  bios          = var.bios
  machine       = var.machine
  scsi_hardware = "virtio-scsi-single" # disk.iothread 를 쓰려면 single 이어야 한다
  tablet_device = false                # 콘솔은 serial 로 쓴다. USB tablet 은 불필요한 폴링만 만든다

  operating_system {
    type = "l26"
  }

  agent {
    enabled = var.agent_enabled
  }

  # --- clone ---------------------------------------------------------------
  # OS-01 template 에서 full clone 한다. linked clone 은 template 을 지울 수 없게 만들고
  # 단일 thin 풀에서 공간 이득도 크지 않다.
  clone {
    vm_id        = var.template_vm_id
    datastore_id = var.datastore_id
    full         = true
  }

  # --- CPU ------------------------------------------------------------------
  # docs/capacity-plan.md "공통 VM 옵션":
  #   type = host   단일 노드이며 live migration 대상이 없다
  #   numa = false  NUMA 노드가 1개다
  #   affinity 미설정  하이브리드 코어에서 vCPU 고정은 성능을 보장하지 못한다
  cpu {
    type    = "host"
    sockets = 1
    cores   = var.vcpu
    numa    = false
  }

  # --- 메모리 ---------------------------------------------------------------
  # floating = 0 이면 ballooning device 자체가 붙지 않는다.
  # docs/capacity-plan.md 가 요구하는 "게스트가 보는 메모리가 변하지 않는다"를
  # min = max 보다 강하게 보장한다. RAM 과할당 금지 원칙의 구현 지점이다.
  memory {
    dedicated = var.memory_mib
    floating  = 0
  }

  # --- 디스크 ---------------------------------------------------------------
  # clone 은 원본 디스크 속성을 상속하지만, 한 속성이라도 명시하면 나머지는
  # schema 기본값으로 덮인다. 그래서 의도한 값을 전부 적는다.
  #   discard = on · ssd = true  docs/capacity-plan.md "공통 VM 옵션"
  #                              없으면 게스트가 지운 블록이 thin 풀로 돌아오지 않는다
  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    size         = var.disk_gib
    discard      = "on"
    ssd          = true
    iothread     = true
    cache        = "none"
    aio          = "io_uring"
    backup       = true
    replicate    = false # 단일 노드이며 replication job 이 없다
  }

  # --- cloud-init -----------------------------------------------------------
  initialization {
    datastore_id = var.datastore_id
    interface    = var.cloud_init_interface

    # 첫 부팅 자동 패키지 업그레이드를 끈다.
    # root@pam 전용 파라미터라 API token 인증에서 실패할 수 있고,
    # 패키지 상태는 OS-01 의 Ansible baseline 이 소유한다.
    upgrade = false

    dns {
      domain  = var.dns_domain
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = var.ipv4_address
        gateway = var.ipv4_gateway
      }
    }

    # user_data_file_id 와 user_account 는 동시에 쓸 수 없다.
    dynamic "user_account" {
      for_each = var.user_data_file_id == null ? [1] : []
      content {
        username = var.cloud_init_username
        keys     = var.ssh_public_keys
      }
    }

    user_data_file_id = var.user_data_file_id
  }

  # --- 네트워크 -------------------------------------------------------------
  # VLAN 간 라우팅과 필터링은 OPNsense 만 담당한다.
  # Proxmox 방화벽을 켜면 통제 지점이 두 곳으로 갈라진다.
  network_device {
    bridge   = var.bridge
    model    = "virtio"
    vlan_id  = var.vlan_id
    firewall = false
  }

  dynamic "serial_device" {
    for_each = var.serial_console ? [1] : []
    content {
      device = "socket"
    }
  }

  startup {
    order = tostring(var.startup_order)
  }

  lifecycle {
    precondition {
      condition     = var.user_data_file_id != null || length(var.ssh_public_keys) > 0
      error_message = "SSH 공개키도 user-data snippet 도 없으면 생성 후 게스트에 접속할 수 없다."
    }
  }
}
