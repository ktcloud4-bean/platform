terraform {
  # Proxmox root와 같은 OpenTofu 계열을 쓴다. 1.12로 검증한다.
  required_version = "~> 1.12"

  required_providers {
    aws = {
      source = "hashicorp/aws"

      # 정확히 고정한다. 루트 .gitignore가 .terraform.lock.hcl 을 제외하므로
      # 버전 재현성의 근거가 이 줄뿐이다. 6.57.x는 릴리스 당일 패치가 나온 계열이라
      # 후속 패치 없이 일주일을 넘긴 6.56.0을 고정한다. 갱신은 사람이 릴리스 노트를
      # 읽고 plan을 본 뒤 올린다.
      version = "6.56.0"
    }
  }

  # state backend는 명시적으로 local 이다. 원격 backend 전환 조건은 ADR-0008을 따른다.
  # 이 state는 AWS access key secret을 포함하므로 저장소 밖 mode 0600 사본으로만 보관한다.
  backend "local" {
    path = "terraform.tfstate"
  }
}
