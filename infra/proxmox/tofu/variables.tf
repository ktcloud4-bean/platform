# ---------------------------------------------------------------------------
# Proxmox 접속 대상
# ---------------------------------------------------------------------------

variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint. 이름은 docs/ip-plan.md 의 proxmox-01 canonical host 를 쓴다."
  type        = string
  default     = "https://proxmox-01.imcherry5778.xyz:8006/"

  validation {
    condition     = can(regex("^https://", var.proxmox_endpoint))
    error_message = "endpoint 는 https 여야 한다."
  }
}

variable "proxmox_insecure" {
  description = <<-EOT
    PVE API 인증서 검증을 건너뛸지 여부.
    PVE-ACME-01 완료로 Let's Encrypt 공인 인증서가 설치되어 strict TLS 검증을 수행한다.
  EOT
  type        = bool
  default     = false
}

variable "proxmox_min_tls" {
  description = "PVE API 호출의 최소 TLS 버전. provider 기본값과 같은 1.3 을 유지한다."
  type        = string
  default     = "1.3"

  validation {
    condition     = contains(["1.0", "1.1", "1.2", "1.3"], var.proxmox_min_tls)
    error_message = "min_tls 는 1.0 · 1.1 · 1.2 · 1.3 중 하나여야 한다."
  }
}

# ---------------------------------------------------------------------------
# OpenTofu 가 소유하지 않는 기존 자산
#
# 아래 세 값은 이미 존재하는 Proxmox 자산을 "가리키기만" 한다.
# resource 로 선언하지도, import 하지도 않는다. 경계 근거는 ADR-0008.
# ---------------------------------------------------------------------------

variable "proxmox_node_name" {
  description = "VM 을 배치할 Proxmox 노드 이름. PVE-01 이 설치한 노드이며 state 가 소유하지 않는다."
  type        = string
  default     = "proxmox-01"
}

variable "vm_datastore_id" {
  description = "VM 디스크·cloud-init 디스크를 둘 datastore. PVE 설치가 만든 lvmthin 이며 state 가 소유하지 않는다."
  type        = string
  default     = "local-lvm"
}

variable "vm_bridge" {
  description = "VM 이 붙을 Proxmox bridge. NET-02 가 VLAN-aware trunk 로 바꾸며 state 가 소유하지 않는다."
  type        = string
  default     = "vmbr0"
}

# ---------------------------------------------------------------------------
# 선행 작업 gate
#
# 두 gate 가 모두 열려야 VM 이 선언된다. 하나라도 닫혀 있으면 이 구성은
# 리소스를 0개 계획한다. 존재하지 않는 template·VLAN 을 있는 것처럼 꾸미지 않기 위한 장치다.
# ---------------------------------------------------------------------------

variable "vm_template_id" {
  description = <<-EOT
    OS-01 이 만들 Rocky Linux 9 Minimal cloud-init template 의 VMID.
    OS-01 이 DONE 이 되고 실제 template VMID 를 확인하기 전까지 null 이다.
    null 이면 VM 을 한 대도 선언하지 않는다.
  EOT
  type        = number
  default     = null
}

variable "vlan_trunk_ready" {
  description = <<-EOT
    NET-02·NET-03 완료 여부.
    vmbr0 가 VLAN-aware trunk 이고 목표 VLAN gateway 와 기본 deny 정책이 살아 있어야 true 다.
    false 이면 VM 을 한 대도 선언하지 않는다.
    현재 vmbr0 는 Phase 1 untagged 이므로 VLAN tag 를 붙여도 통신하지 않는다.
  EOT
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# cloud-init 계약
# ---------------------------------------------------------------------------

variable "dns_domain" {
  description = "게스트 cloud-init 이 쓸 DNS search domain. docs/ip-plan.md 의 랩 도메인."
  type        = string
  default     = "imcherry5778.xyz"
}

variable "cloud_init_username" {
  description = "cloud-init 이 만들 bootstrap 사용자. 이후 계정 정책은 OS-01 의 Ansible baseline 이 소유한다."
  type        = string
  default     = "rocky"
}

variable "ssh_public_keys" {
  description = <<-EOT
    cloud-init 이 bootstrap 사용자에게 넣을 SSH 공개키 목록.
    공개키만 넣는다. private key 는 이 저장소와 state 어디에도 두지 않는다.
    파일에서 읽으려면 TF_VAR_ssh_public_keys 환경변수나 저장소 밖 tfvars 를 쓴다.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for k in var.ssh_public_keys : can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+) ", k))
    ])
    error_message = "SSH 공개키 형식이 아니다. private key 나 파일 경로를 넣지 않았는지 확인한다."
  }
}

variable "cloud_init_user_data_file_id" {
  description = <<-EOT
    cloud-init user-data snippet 의 파일 ID (예: local:snippets/rocky.yaml).
    지정하면 user_account 블록 대신 이 snippet 을 쓴다.
    snippet 업로드 자체는 이 구성의 범위 밖이며 OS-01 이 소유한다.
  EOT
  type        = string
  default     = null
}

# ---------------------------------------------------------------------------
# VM 하드웨어 기준선
#
# 용량 회계에 영향을 주는 값은 docs/capacity-plan.md 가 소유한다.
# 여기서는 그 문서가 다루지 않는 나머지 옵션만 노출한다.
# ---------------------------------------------------------------------------

variable "vm_bios" {
  description = "VM 펌웨어. OS-01 template 과 반드시 같아야 한다. clone 시 이 값이 template 설정을 덮어쓴다."
  type        = string
  default     = "seabios"

  validation {
    condition     = contains(["seabios", "ovmf"], var.vm_bios)
    error_message = "bios 는 seabios 또는 ovmf 여야 한다."
  }
}

variable "vm_machine" {
  description = "VM machine type. OS-01 template 과 반드시 같아야 한다."
  type        = string
  default     = "pc"
}

variable "cloud_init_interface" {
  description = "cloud-init 디스크를 붙일 인터페이스. OS-01 template 의 cloud-init drive 위치와 같아야 한다."
  type        = string
  default     = "ide2"
}

variable "agent_enabled" {
  description = <<-EOT
    QEMU guest agent 사용 여부.
    OS-01 template 이 qemu-guest-agent 를 자동 기동하지 않으면 true 로 두지 않는다.
    agent 가 없는데 true 이면 생성·refresh·shutdown 이 전부 timeout 된다.
  EOT
  type        = bool
  default     = true
}
