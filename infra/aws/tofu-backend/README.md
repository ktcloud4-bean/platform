# OpenTofu Remote State Backend · OpenTofu

이 Root는 OpenTofu / Terraform의 Remote State를 보관하기 위한 전용 S3 버킷 및 동시성 락(Lock) 관리를 위한 DynamoDB 테이블을 소유합니다.
ADR-0008에 따라 파괴 방지를 위해 S3 버킷과 DynamoDB 테이블 모두 `prevent_destroy = true`가 필수 적용되어 있습니다.

## 실행

```bash
cd platform/infra/aws/tofu-backend
tofu init
tofu plan
tofu apply
```
