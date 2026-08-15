# HR application network root

이 root는 `tofu-network`가 소유한 `10.20.0.0/16` shared VPC를 read-only remote state로
참조한다. 그 안의 HR EKS application/DB private subnet, EKS·RDS security group, AWS service
endpoint만 소유한다. VPC·기본 security group·기존 DATA VPN을 import하거나 수정하지 않는다.
IGW, NAT Gateway, public subnet, `0.0.0.0/0` route와 internet-facing ELB는 선언하지 않는다.
실제 주소는 `docs/ip-plan.md`가 소유한다.

Node/Pod egress는 CoreDNS가 있는 private application subnet의 DNS TCP/UDP 53, ECR API/DKR,
S3, STS, RDS, EC2, Elastic Load Balancing, Secrets Manager의 VPC endpoint와 Aurora PostgreSQL로
한정한다. migration Job의 Aurora managed master secret discovery는 RDS API endpoint를 쓴다.
공급망 admission의 TUF metadata는 EKS root가 선언한 node SG exact rule을 통해 기존 S2S VPN과
`10.10.20.12:8445` 전용 CONNECT proxy로 전달한다. proxy는 `tuf-repo-cdn.sigstore.dev:443`만
허용하며 다른 public egress나 default route는 만들지 않는다. 새로운 AWS API가 필요하면
public egress가 아니라 정확한 endpoint·SG rule을 별도 검토한다.

Route 53 Resolver inbound endpoint 두 개는 OPNsense Unbound가 EKS private API의 AWS DNS zone만
조건부 전달하는 용도다. endpoint IP는 OpenTofu output으로만 소비하며, EKS endpoint IP를
고정 host override로 선언하지 않는다.

이 root의 backend는 `platform/infra/aws/tofu-app-network/v1/terraform.tfstate`다. Jenkins는
plan만 수행하며 첫 state 생성과 apply는 `TOFU-STATE` 잠금 아래 administrator가 소유한다.
`tofu-app-vpn`만 이 root의 HR route table output과 `tofu-network`의 기존 VGW output을 함께
읽어 on-prem route를 별도 resource로 추가할 수 있다.
