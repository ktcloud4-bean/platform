# AWS-HR-01의 Argo controller는 EKS destination용 source credential bundle 하나만 읽는다.
# Jenkins ECR publisher와 다른 workload의 Vault path는 열지 않는다.
path "kv/data/aws-hr-01/argocd" {
  capabilities = ["read"]
}

path "kv/metadata/aws-hr-01/argocd" {
  capabilities = ["read"]
}
