# 이 모듈의 계약은 "docs/capacity-plan.md 의 Day 1 값과 공통 옵션을 지키는 서비스 VM 한 대"다.
# 값의 출처는 root 모듈이 소유하고 여기서는 형식만 강제한다.

variable "name" {
  description = "VM 이름. docs/ip-plan.md 의 canonical host 이름과 같아야 하며 유효한 DNS 이름이어야 한다."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.name))
    error_message = "이름은 소문자·숫자·하이픈만 쓰고 하이픈으로 시작하거나 끝날 수 없다."
  }
}

variable "description" {
  description = "Proxmox VM 설명."
  type        = string
  default     = "Managed by OpenTofu"
}

variable "tags" {
  description = "Proxmox VM 태그. Proxmox 가 항상 정렬하므로 정렬된 값을 넘긴다."
  type        = list(string)
  default     = ["opentofu"]
}

variable "vm_id" {
  description = "VMID."
  type        = number

  validation {
    condition     = var.vm_id >= 100 && var.vm_id <= 999999999
    error_message = "VMID 는 100 이상이어야 한다. 100 미만은 Proxmox 예약 범위다."
  }
}

# --- OpenTofu 가 소유하지 않는 대상 -----------------------------------------

variable "node_name" {
  description = "배치할 Proxmox 노드 이름. 이 모듈은 노드를 만들지 않고 참조만 한다."
  type        = string
}

variable "datastore_id" {
  description = "VM 디스크·cloud-init 디스크 datastore. 이 모듈은 datastore 를 만들지 않고 참조만 한다."
  type        = string
}

variable "bridge" {
  description = "네트워크 bridge. 이 모듈은 bridge 를 만들지 않고 참조만 한다."
  type        = string
}

variable "template_vm_id" {
  description = "clone 원본이 될 cloud-init template 의 VMID. OS-01 이 만든다."
  type        = number
}

# --- docs/capacity-plan.md Day 1 값 -----------------------------------------

variable "vcpu" {
  description = "vCPU 수. cores 로 들어가며 socket 은 항상 1 이다."
  type        = number

  validation {
    condition     = var.vcpu >= 1 && var.vcpu <= 20
    error_message = "vCPU 는 1 이상 물리 스레드 수 20 이하여야 한다."
  }
}

variable "memory_mib" {
  description = "게스트에 고정 배정할 메모리(MiB). ballooning 을 쓰지 않으므로 이 값이 게스트가 보는 전부다."
  type        = number

  validation {
    condition     = var.memory_mib >= 512
    error_message = "메모리는 512 MiB 이상이어야 한다."
  }
}

variable "disk_gib" {
  description = "부팅 디스크 가상 크기(GiB). thin 풀이라 축소는 불가능하므로 필요한 만큼만 준다."
  type        = number

  validation {
    condition     = var.disk_gib >= 8
    error_message = "디스크는 8 GiB 이상이어야 한다."
  }
}

variable "startup_order" {
  description = "호스트 부팅 시 기동 순서. 작은 값이 먼저 뜬다."
  type        = number
}

# --- docs/ip-plan.md 값 ------------------------------------------------------

variable "vlan_id" {
  description = "네트워크 장치에 붙일 802.1Q VLAN tag."
  type        = number

  validation {
    condition     = var.vlan_id >= 2 && var.vlan_id <= 4094
    error_message = "VLAN 1 과 예약 범위는 쓰지 않는다 (docs/ip-plan.md '물리 토폴로지')."
  }
}

variable "ipv4_address" {
  description = "CIDR 표기 고정 IPv4 주소."
  type        = string

  validation {
    condition     = can(cidrhost(var.ipv4_address, 0))
    error_message = "CIDR 표기여야 한다. 예: 10.10.20.10/24"
  }
}

variable "ipv4_gateway" {
  description = "해당 VLAN 의 OPNsense gateway."
  type        = string
}

variable "dns_servers" {
  description = "게스트가 쓸 DNS 서버 목록."
  type        = list(string)
}

variable "dns_domain" {
  description = "게스트 DNS search domain."
  type        = string
}

# --- cloud-init --------------------------------------------------------------

variable "cloud_init_username" {
  description = "cloud-init bootstrap 사용자."
  type        = string
}

variable "ssh_public_keys" {
  description = "bootstrap 사용자에게 넣을 SSH 공개키. private key 는 절대 넣지 않는다."
  type        = list(string)
  default     = []
}

variable "user_data_file_id" {
  description = "cloud-init user-data snippet 파일 ID. 지정하면 user_account 대신 쓴다."
  type        = string
  default     = null
}

variable "cloud_init_interface" {
  description = "cloud-init 디스크 인터페이스."
  type        = string
  default     = "ide2"
}

# --- 나머지 VM 옵션 -----------------------------------------------------------

variable "bios" {
  description = "VM 펌웨어. template 과 같아야 한다."
  type        = string
  default     = "seabios"
}

variable "machine" {
  description = "VM machine type. template 과 같아야 한다."
  type        = string
  default     = "pc"
}

variable "agent_enabled" {
  description = "QEMU guest agent 사용 여부."
  type        = bool
  default     = true
}

variable "stop_on_destroy" {
  description = <<-EOT
    destroy 때 graceful shutdown 대신 강제 stop 을 쓸지 여부.
    기본은 false 다. agent 가 정상이면 게스트가 파일시스템을 정리하고 내려간다.
  EOT
  type        = bool
  default     = false
}

variable "serial_console" {
  description = "serial console 장치를 붙일지 여부. 네트워크가 끊겼을 때의 콘솔 복구 경로다."
  type        = bool
  default     = true
}
