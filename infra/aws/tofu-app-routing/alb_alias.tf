# ALB는 Kubernetes Ingress lifecycle에 속해 AWS Load Balancer Controller가 소유한다.
# 이 root는 그 controller-owned ALB의 stable private DNS 별칭만 소유한다. data lookup은
# controller가 `hr-system-prod` ALB를 만든 뒤에만 성공해야 하며, 없을 때 추측해서 record를
# 만들지 않는다.
data "aws_lb" "hr_internal" {
  name = var.internal_alb_name
}

resource "aws_route53_record" "hr_internal_alb" {
  zone_id = data.terraform_remote_state.app_network.outputs.hr_internal_private_zone_id
  name    = var.internal_alb_record_name
  type    = "A"

  alias {
    name                   = data.aws_lb.hr_internal.dns_name
    zone_id                = data.aws_lb.hr_internal.zone_id
    evaluate_target_health = false
  }
}
