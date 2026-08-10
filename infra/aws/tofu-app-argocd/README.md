# HR Argo CD private EKS access root

이 root는 기존 k3s Argo CD가 private HR EKS destination을 관리할 때 필요한 IAM 경계를 소유한다.
`argocd-eks-credential-issuer` user는 target role 하나에 대한 `sts:AssumeRole`만 받고, EKS
권한은 그 role의 EKS Access Entry에만 있다. AWS Load Balancer Controller의 CRD와 internal ALB
resource가 cluster-scoped이므로 target role에는 `AmazonEKSClusterAdminPolicy`가 필요하다.

`aws_iam_access_key`는 선언하지 않는다. access key secret이 OpenTofu state에 남지 않도록 root
apply 뒤 전용 user key 하나를 별도로 발급해 Vault `kv/aws-hr-01/argocd`에만 보관한다. Argo CD
application controller의 Vault Agent가 memory volume에 AWS shared credentials file을 렌더링하고,
cluster Secret은 `argocd-k8s-auth`와 role ARN·공개 EKS CA만 가진다.

backend key는 `platform/infra/aws/tofu-app-argocd/v1/terraform.tfstate`다. `tofu-app-eks` state가
먼저 있어야 하며 Jenkins에는 이 state 및 credential issuer 권한을 주지 않는다.
