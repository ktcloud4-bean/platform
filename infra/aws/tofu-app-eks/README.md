# 애플리케이션 EKS 컴퓨팅 계층 · OpenTofu

이 Root는 EKS 쿠버네티스 클러스터, 매니지드 노드그룹, ALB Controller 전용 IRSA IAM Role을 소유합니다.

## 실행

```bash
cd platform/infra/aws/tofu-app-eks
tofu init
tofu plan -var-file=<외부 tfvars>
tofu apply -var-file=<외부 tfvars>
```
