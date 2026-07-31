terraform {
  # 다른 root와 같은 OpenTofu 계열을 쓴다. 1.12로 검증한다.
  required_version = "~> 1.12"

  required_providers {
    aws = {
      source = "hashicorp/aws"

      # 정확히 고정한다. 루트 .gitignore가 .terraform.lock.hcl 을 제외하므로
      # 버전 재현성의 근거가 이 줄뿐이다. 오프사이트 root(infra/aws/tofu)와 같은
      # 6.56.0을 쓴다. 두 root가 서로 다른 provider 동작을 보이지 않게 하려는 것이다.
      # 갱신은 사람이 릴리스 노트를 읽고 plan을 본 뒤 올린다.
      version = "6.56.0"
    }
  }

  # state backend는 명시적으로 local 이다. 원격 backend 전환 조건은 ADR-0008을 따른다.
  # 이 state는 tunnel pre-shared key를 포함하므로 저장소 밖 mode 0600 사본으로만 보관한다.
  backend "local" {
    path = "terraform.tfstate"
  }
}
