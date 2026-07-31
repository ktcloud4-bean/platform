locals {
  vpc_name    = "${var.name_prefix}-onprem-link"
  subnet_name = "${var.name_prefix}-private-a"

  # 검증 인스턴스가 HTTP로 돌려주는 고유 문자열. 경로가 실제로 열렸는지
  # ICMP 대신 payload로 판정하려는 것이다. 비밀이 아니다.
  verify_marker = "aws-net-01-private-path-ok"
  verify_port   = 8080

  # "IP:PORT" 를 나눠 검증 인스턴스의 probe 대상으로 넘긴다.
  probe_enabled = var.verify_onprem_probe_target != ""
  probe_host    = local.probe_enabled ? split(":", var.verify_onprem_probe_target)[0] : ""
  probe_port    = local.probe_enabled ? split(":", var.verify_onprem_probe_target)[1] : "0"
}
