data "terraform_remote_state" "app_network" {
  backend = "s3"

  config = {
    bucket = "ktcloud4-bean-opentofu-state-465137780685"
    key    = "platform/infra/aws/tofu-app-network/v1/terraform.tfstate"
    region = var.aws_region
  }
}
