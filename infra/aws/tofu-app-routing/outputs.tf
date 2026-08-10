output "internal_alb_private_fqdn" {
  description = "Pomerium이 사용할 controller-independent internal ALB private alias"
  value       = aws_route53_record.hr_internal_alb.fqdn
}

output "internal_alb_dns_name" {
  description = "적용 시점의 controller-owned ALB DNS name. public DNS record가 아니다."
  value       = data.aws_lb.hr_internal.dns_name
}
