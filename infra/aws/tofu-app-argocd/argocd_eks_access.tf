# k3s Argo CD는 AWS 실행 주체가 아니므로, Vault가 보관하는 access key는 이 전용 user의
# AssumeRole 하나로만 제한한다. access key 자체는 state에 남기지 않으며 aws_iam_access_key를
# 선언하지 않는다.
resource "aws_iam_user" "argocd_credential_issuer" {
  name = "${local.name_prefix}-argocd-eks-credential-issuer"
  path = "/service/argocd/"

  tags = {
    Name    = "${local.name_prefix}-argocd-eks-credential-issuer"
    Purpose = "Vault-held source credential for the private EKS Argo CD destination"
  }
}

resource "aws_iam_role" "argocd_eks" {
  name = "${local.name_prefix}-argocd-eks-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { AWS = aws_iam_user.argocd_credential_issuer.arn }
    }]
  })

  tags = {
    Name    = "${local.name_prefix}-argocd-eks-role"
    Purpose = "Private EKS API role assumed only by the k3s Argo CD controller"
  }
}

resource "aws_iam_user_policy" "argocd_assume_eks" {
  name = "${local.name_prefix}-assume-eks-only"
  user = aws_iam_user.argocd_credential_issuer.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumeOnlyTheHrEksRole"
      Effect   = "Allow"
      Action   = ["sts:AssumeRole"]
      Resource = aws_iam_role.argocd_eks.arn
    }]
  })
}

# argocd-k8s-auth는 이 target role로 짧은 EKS bearer token을 만든다. cluster endpoint
# 연결에는 exact DescribeCluster만 허용한다.
resource "aws_iam_role_policy" "argocd_eks_token" {
  name = "describe-private-hr-eks-only"
  role = aws_iam_role.argocd_eks.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescribeExactCluster"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = data.terraform_remote_state.app_eks.outputs.eks_cluster_arn
      },
      {
        Sid      = "GenerateEksAuthenticationToken"
        Effect   = "Allow"
        Action   = ["sts:GetCallerIdentity"]
        Resource = "*"
      },
    ]
  })
}

# AWS Load Balancer Controller CRD와 internal ALB lifecycle은 cluster-scoped resource를
# 포함한다. 그래서 EKS가 제공하는 cluster-admin access policy를 별도 target role 하나에만
# 붙인다. source credential user에는 이 권한이 직접 없다.
resource "aws_eks_access_entry" "argocd" {
  cluster_name  = data.terraform_remote_state.app_eks.outputs.eks_cluster_name
  principal_arn = aws_iam_role.argocd_eks.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "argocd_cluster_admin" {
  cluster_name  = data.terraform_remote_state.app_eks.outputs.eks_cluster_name
  principal_arn = aws_iam_role.argocd_eks.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.argocd]
}
