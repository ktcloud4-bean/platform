# HR System on private EKS

이 directory는 `AWS-HR-01`의 세 signed ECR digest를 private EKS에 배포한다. 일반
service는 자기 Secrets Manager credential만 IRSA로 읽고, PreSync migration Job만 Aurora
master credential을 cluster identifier로 발견한다. secret ARN·credential 원문은 manifest에 없다.

namespace와 migration IRSA ServiceAccount는 `hr-system-bootstrap` child Application이 먼저
소유한다. Argo PreSync hook보다 앞선 독립 child health를 요구해 migration Pod가 존재하지 않는
ServiceAccount를 참조할 수 없게 한다.

AWS Load Balancer Controller가 `hr-system-prod` internal ALB와 그 security group을
`Ingress` lifecycle로 소유한다. 이 controller-owned AWS resource는 OpenTofu import 대상이
아니며, `tofu-app-routing`은 생성된 ALB의 stable Route 53 private alias만 소유한다. ALB는
`10.10.20.0/24`에서 온 HTTP/80만 받고, IPsec이 전송을 암호화한다. public DNS·NAT·Internet
Gateway는 만들지 않는다.

Pomerium의 `www`와 `admin` route는 alias를 통해 같은 ALB에 도달하되, Pomerium group과
application DB role이 각각 browser admission과 HR action 권한을 다시 판정한다. EKS VPC CNI
network policy standard mode가 이 namespace의 default-deny·DNS·frontend/API/AWS egress 정책을
실제로 강제한다.
