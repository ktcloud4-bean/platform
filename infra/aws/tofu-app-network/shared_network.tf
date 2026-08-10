data "terraform_remote_state" "shared_network" {
  backend = "s3"

  config = {
    bucket         = "ktcloud4-bean-opentofu-state-465137780685"
    key            = "platform/infra/aws/tofu-network/terraform.tfstate"
    region         = var.aws_region
    dynamodb_table = "ktcloud4-bean-opentofu-locks"
    encrypt        = true
  }
}

# Pomerium은 생성 시마다 바뀌는 ALB provider hostname 대신 이 private hosted zone의
# 고정 별칭만 사용한다. zone은 shared VPC에만 연결되며 public DNS record를 만들지 않는다.
resource "aws_route53_zone" "hr_internal" {
  name          = "aws.imcherry5778.xyz"
  force_destroy = false

  vpc {
    vpc_id = data.terraform_remote_state.shared_network.outputs.vpc_id
  }

  tags = {
    Name = "${local.name_prefix}-internal-private-zone"
  }
}
