# 애플리케이션 네트워크 계층 · OpenTofu

이 Root는 애플리케이션 배포용 VPC, 서브넷(Public, App Private, DB Private), NAT Gateway, 기본 보안 그룹(EKS Node SG, RDS SG)을 소유합니다.

## 실행

```bash
cd platform/infra/aws/tofu-app-network
tofu init
tofu plan
tofu apply
```
