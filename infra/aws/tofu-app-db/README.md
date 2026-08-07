# 애플리케이션 데이터베이스 계층 · OpenTofu

이 Root는 RDS PostgreSQL 데이터베이스를 소유합니다.
ADR-0008에 따라 파괴 방지를 위해 `prevent_destroy = true`가 필수 적용되어 있습니다.

## 실행

```bash
cd platform/infra/aws/tofu-app-db
tofu init
tofu plan -var-file=<외부 tfvars>
tofu apply -var-file=<외부 tfvars>
```
