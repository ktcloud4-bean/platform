variable "aws_account_id" {
  description = "적용 대상 AWS 계정 ID. 저장소 밖 변수 파일로만 주입한다. provider 계정 guard에 쓴다."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id는 12자리 숫자여야 한다."
  }
}

variable "aws_region" {
  description = "사설 착지점 VPC와 VPN을 두는 region. 오프사이트 bucket과 같은 region을 기본값으로 한다."
  type        = string
  default     = "ap-northeast-2"
}

variable "name_prefix" {
  description = "이 root가 만드는 자원의 이름 접두사."
  type        = string
  default     = "ktcloud4-bean"
}

variable "vpc_cidr" {
  description = <<-EOT
    사설 착지점 VPC의 CIDR. 온프레미스 랩 대역(docs/ip-plan.md)과 겹치면 라우팅이 성립하지 않는다.
    계정의 default VPC 대역과도 겹치지 않아야 뒤에 피어링·공유가 생겨도 충돌하지 않는다.
  EOT
  type        = string
  default     = "10.20.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr는 올바른 IPv4 CIDR이어야 한다."
  }
}

variable "private_subnet_cidr" {
  description = "VPN으로만 닿는 사설 서브넷. 인터넷 gateway를 붙이지 않는다."
  type        = string
  default     = "10.20.1.0/24"

  validation {
    condition     = can(cidrhost(var.private_subnet_cidr, 0))
    error_message = "private_subnet_cidr는 올바른 IPv4 CIDR이어야 한다."
  }
}

variable "availability_zone" {
  description = "사설 서브넷을 두는 AZ. 단일 AZ다. 이 VPC는 가용성이 아니라 사설 경로 검증이 목적이다."
  type        = string
  default     = "ap-northeast-2a"
}

variable "onprem_cidr" {
  description = <<-EOT
    VPN으로 통신을 허용할 온프레미스 대역. IPsec traffic selector와 AWS static route,
    security group에 모두 이 값이 들어가므로 여기를 좁히는 것이 "대상 대역만 통신"의 실제 통제다.
    VPN connection 하나의 selector는 PLATFORM과 DATA를 포함한다. 실제 허용은
    OPNsense PF와 AWS security group의 exact source·port 규칙에서 다시 제한한다.
  EOT
  type        = string
  default     = "10.10.0.0/16"

  validation {
    condition     = can(cidrhost(var.onprem_cidr, 0))
    error_message = "onprem_cidr는 올바른 IPv4 CIDR이어야 한다."
  }
}

variable "customer_gateway_ip" {
  description = <<-EOT
    OPNsense WAN의 공인 IPv4. 저장소 밖 변수 파일로만 주입한다.
    ISP DHCP 임대이므로 주소가 바뀌면 이 값과 Customer Gateway를 함께 교체해야 터널이 복구된다.
  EOT
  type        = string

  validation {
    condition     = can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", var.customer_gateway_ip))
    error_message = "customer_gateway_ip는 IPv4 주소여야 한다."
  }
}

variable "customer_gateway_bgp_asn" {
  description = <<-EOT
    Customer Gateway에 기록하는 BGP ASN. static routing에서도 AWS가 요구하는 필수 필드다.
    실제로 BGP 세션을 맺지 않으므로 사설 ASN을 쓴다.
  EOT
  type        = number
  default     = 65000
}

variable "create_vpn_connection" {
  description = <<-EOT
    비용 gate. VPN Connection은 트래픽과 무관하게 존재하는 시간에 비례해 과금된다.
    이 root의 상시 비용은 사실상 전부 이 자원 하나에서 나온다.
    닫으면 VPC·서브넷·route table·VGW만 남고 과금 자원은 0이 된다.
  EOT
  type        = bool
  default     = true
}

variable "create_verify_instance" {
  description = <<-EOT
    검증용 인스턴스 gate. 양방향 통신 증거를 만들 때만 연다.
    증거를 확보하면 닫아서 제거한다. 공인 IP를 붙이지 않으므로 VPN이 유일한 접근 경로다.
  EOT
  type        = bool
  default     = false
}

variable "verify_instance_type" {
  description = <<-EOT
    검증용 인스턴스 타입. 통신 경로만 확인하므로 작은 것을 쓴다.
    이 계정은 free-tier 대상 타입만 실행할 수 있어 t4g.nano는 거부된다.
    arm64 free-tier 중 가장 작은 t4g.micro를 기본값으로 한다.
  EOT
  type        = string
  default     = "t4g.micro"
}

variable "verify_onprem_probe_target" {
  description = <<-EOT
    검증 인스턴스가 AWS→온프레미스 방향을 증명하려고 주기적으로 접속할 대상.
    "IP:PORT" 형식이며 onprem_cidr 안이어야 한다. 빈 문자열이면 probe를 돌리지 않는다.
  EOT
  type        = string
  default     = ""
}
