terraform {
  # bpg/proxmox 0.111.1은 OpenTofu 1.6+ 를 요구한다. 이 저장소는 1.12 계열로 검증한다.
  required_version = "~> 1.12"

  required_providers {
    proxmox = {
      source = "bpg/proxmox"

      # 정확히 고정한다. 0.x provider는 minor 갱신에 호환성 파괴가 들어갈 수 있고,
      # 루트 .gitignore가 .terraform.lock.hcl 을 제외하므로 버전 재현성의 근거가 이 줄뿐이다.
      version = "0.111.1"
    }
  }

  # state backend는 명시적으로 local 이다. 원격 backend 전환 조건은 ADR-0008을 따른다.
  backend "local" {
    path = "terraform.tfstate"
  }
}
