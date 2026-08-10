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

  # 이 root의 state에는 AWS access key secret이 들어갈 수 있다. 버전·암호화·전송 TLS를
  # 강제한 전용 state bucket에만 보관하고, Jenkins에는 이 key 권한을 주지 않는다.
  backend "s3" {
    bucket         = "ktcloud4-bean-opentofu-state-465137780685"
    key            = "platform/infra/aws/tofu/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "ktcloud4-bean-opentofu-locks"
    encrypt        = true
  }
}
