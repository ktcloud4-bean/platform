# HR application EKS root

이 root는 private-only EKS 1.36 cluster, AL2023 managed node group, EKS managed core add-on,
control-plane audit log, ALB Controller IRSA와 HR 서비스/migration Job IRSA를 소유한다. public
EKS API는 끄고 `tofu-app-network`의 PLATFORM CIDR 제한 security group만 연결한다.

ALB Controller는 private ECR에 mirror한 image로 설치해야 하며, private cluster에서는 Shield/WAF/
WAFv2와 ACM certificate discovery를 사용하지 않는다. `employee-service`, `hr-service` role은 각자
자기 DB secret ARN 하나만 읽고, `hr-db-migrate` role만 master와 두 service secret을 읽는다.

Aurora DB root state와 app network v1 state가 먼저 존재해야 IRSA policy의 secret ARN과 private
subnet·private EKS API security group을 참조할 수 있다. CI나 운영자가 ID를 복사해 주입하지 않는다. backend는
`platform/infra/aws/tofu-app-eks/v1/terraform.tfstate`이며 Jenkins pipeline은 이 root를 apply하지
않는다.
