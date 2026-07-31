# 검증 전용 자원.
# "양방향 대상 대역만 통신"을 증명하려면 AWS 쪽에도 실제로 응답하는 상대가 있어야 한다.
# 증거를 확보하면 create_verify_instance 를 닫아 제거한다. 이 인스턴스는 백업 자산도
# 운영 자산도 아니다.

data "aws_ssm_parameter" "al2023_arm64" {
  count = var.create_verify_instance ? 1 : 0

  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# 온프레미스 대역에서 오는 지정 프로토콜만 받는다.
# egress도 온프레미스 대역으로만 연다. 이 VPC에는 인터넷 경로가 없지만,
# 통제를 route 부재에만 기대지 않고 security group에도 명시한다.
resource "aws_security_group" "verify" {
  count = var.create_verify_instance ? 1 : 0

  name = "${var.name_prefix}-verify"

  # AWS는 security group description에 ASCII만 허용한다.
  # 이 필드에 한해 영문으로 적는다.
  description = "AWS-NET-01 private path verification only. Allows on-premises range."

  vpc_id = aws_vpc.onprem_link.id

  tags = {
    Name = "${var.name_prefix}-verify"
  }
}

resource "aws_vpc_security_group_ingress_rule" "verify_marker" {
  count = var.create_verify_instance ? 1 : 0

  security_group_id = aws_security_group.verify[0].id
  description       = "Marker response from on-premises range; judges the private path by payload."

  cidr_ipv4   = var.onprem_cidr
  ip_protocol = "tcp"
  from_port   = local.verify_port
  to_port     = local.verify_port
}

resource "aws_vpc_security_group_ingress_rule" "verify_icmp" {
  count = var.create_verify_instance ? 1 : 0

  security_group_id = aws_security_group.verify[0].id
  description       = "ICMP for path check only; not used as evidence for block verdicts."

  cidr_ipv4   = var.onprem_cidr
  ip_protocol = "icmp"
  from_port   = -1
  to_port     = -1
}

resource "aws_vpc_security_group_egress_rule" "verify_to_onprem" {
  count = var.create_verify_instance ? 1 : 0

  security_group_id = aws_security_group.verify[0].id
  description       = "Reverse-direction probe to on-premises; never leaves the target range."

  cidr_ipv4   = var.onprem_cidr
  ip_protocol = "-1"
}

resource "aws_instance" "verify" {
  count = var.create_verify_instance ? 1 : 0

  ami           = data.aws_ssm_parameter.al2023_arm64[0].value
  instance_type = var.verify_instance_type
  subnet_id     = aws_subnet.private_a.id

  vpc_security_group_ids = [aws_security_group.verify[0].id]

  # 공인 IP를 붙이지 않는다. VPN이 유일한 접근 경로라는 것이 이 검증의 전제다.
  associate_public_ip_address = false

  # SSH key pair를 만들지 않는다. private key가 state에 남는 것을 피하고,
  # 로그인 대신 marker 응답과 probe 로그로 판정한다.
  #
  # cloud-init은 첫 부팅에만 user_data를 실행한다. 이것이 없으면 user_data를 고쳐도
  # 인스턴스는 stop/start만 하고 예전 설정으로 계속 뜬다. 검증 내용이 조용히
  # 반영되지 않는 것을 막으려고 교체를 강제한다.
  user_data_replace_on_change = true

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    encrypted   = true
    volume_size = 8
    volume_type = "gp3"
  }

  user_data = <<-EOT
    #!/bin/bash
    set -eu

    # 1) 온프레미스 → AWS 방향: 고유 marker를 돌려주는 최소 HTTP 응답기.
    #    ICMP가 아니라 payload로 판정하려는 것이다.
    cat > /opt/verify-marker.py <<'PY'
    import http.server, socketserver

    MARKER = "${local.verify_marker}"
    PORT = ${local.verify_port}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write((MARKER + "\n").encode())

        def log_message(self, fmt, *args):
            print("request from %s" % self.client_address[0], flush=True)

    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer(("0.0.0.0", PORT), Handler) as httpd:
        httpd.serve_forever()
    PY

    cat > /etc/systemd/system/verify-marker.service <<'UNIT'
    [Unit]
    Description=AWS-NET-01 marker responder
    After=network-online.target

    [Service]
    ExecStart=/usr/bin/python3 /opt/verify-marker.py
    Restart=always
    DynamicUser=yes

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable --now verify-marker.service

    # 2) AWS → 온프레미스 방향: 지정 대상으로 주기적으로 TCP 연결을 시도하고 결과를 남긴다.
    #    온프레미스 쪽 listener에서 이 연결이 관측되면 역방향이 증명된다.
    %{if local.probe_enabled}
    cat > /opt/verify-probe.sh <<'PROBE'
    #!/bin/bash
    while true; do
      if timeout 5 bash -c "echo aws-net-01-probe > /dev/tcp/${local.probe_host}/${local.probe_port}" 2>/dev/null; then
        logger -t verify-probe "reach ${local.probe_host}:${local.probe_port} ok"
      else
        logger -t verify-probe "reach ${local.probe_host}:${local.probe_port} fail"
      fi
      sleep 30
    done
    PROBE
    chmod 755 /opt/verify-probe.sh

    cat > /etc/systemd/system/verify-probe.service <<'UNIT2'
    [Unit]
    Description=AWS-NET-01 reverse direction probe
    After=network-online.target

    [Service]
    ExecStart=/opt/verify-probe.sh
    Restart=always

    [Install]
    WantedBy=multi-user.target
    UNIT2

    systemctl daemon-reload
    systemctl enable --now verify-probe.service
    %{endif}
  EOT

  tags = {
    Name = "${var.name_prefix}-verify"
  }
}
