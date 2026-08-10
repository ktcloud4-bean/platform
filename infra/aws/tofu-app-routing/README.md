# HR internal ALB routing root

`tofu-app-routing`은 AWS Load Balancer Controller가 Kubernetes `Ingress` lifecycle로
만든 internal ALB 자체를 선언하거나 import하지 않는다. 대신 `tofu-app-network`가 소유한
Route 53 private hosted zone에 `hr-system.alb.aws.imcherry5778.xyz` alias 하나를 선언한다.
Pomerium은 이 stable FQDN만 upstream으로 사용한다.

적용 순서는 다음과 같다.

1. `tofu-app-network`가 private hosted zone과 Resolver inbound endpoint를 적용한다.
2. Argo CD가 EKS의 AWS Load Balancer Controller와 HR `Ingress`를 healthy로 만든다.
3. 이 root가 controller-created `hr-system-prod` ALB를 data source로 확인한 뒤 alias를 적용한다.

ALB가 아직 없으면 `tofu plan`은 실패하는 것이 정상이며, 빈·추측 record를 만들지 않는다.
private hosted zone은 shared VPC에만 연결된다. OPNsense Unbound는
`aws.imcherry5778.xyz.`를 Resolver inbound endpoint로 조건부 forward해야 on-prem Pomerium도
이 별칭을 해석할 수 있다. public DNS/NAT는 이 root 범위 밖이며 만들지 않는다.
