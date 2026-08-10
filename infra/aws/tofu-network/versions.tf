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

  # 이 root의 state에는 tunnel pre-shared key가 들어갈 수 있다. 버전·암호화·전송 TLS를
  # 강제한 전용 state bucket에만 보관하고, Jenkins에는 이 key 권한을 주지 않는다.
  backend "s3" {
    bucket         = "ktcloud4-bean-opentofu-state-465137780685"
    key            = "platform/infra/aws/tofu-network/terraform.tfstate"
    region         = "ap-northeast-2"
    dynamodb_table = "ktcloud4-bean-opentofu-locks"
    encrypt        = true
  }
}
