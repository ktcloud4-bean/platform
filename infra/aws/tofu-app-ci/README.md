# HR Jenkins ECR publisher root

이 root는 on-prem Jenkins가 HR image 세 개만 ECR에 push하도록 IAM user와 inline policy를
소유한다. VPC·EKS·Aurora·ECR repository 자체와 deployment 권한은 소유하지 않는다.

## credential 경계

`aws_iam_access_key`는 이 root에 선언하지 않는다. access key secret을 OpenTofu state에 넣지
않기 위해서다. root apply로 정확히 하나의 publisher user가 생긴 뒤, 운영자가 별도 승인 아래
access key 하나를 발급해 Vault의 HR Jenkins 전용 path에만 저장한다. Jenkins는 build 끝에
workspace·registry login을 제거하며 Kubernetes/EKS·Git write credential은 받지 않는다.

publisher user의 권한은 다음으로 한정된다.

- ECR authorization token 1개
- `frontend`, `employee-service`, `hr-service` repository의 layer upload, immutable image
  manifest push/read 및 image metadata 조회

repository 삭제, lifecycle/policy 변경, EKS/Kubernetes, Secrets Manager, IAM 관리와 다른 ECR
repository는 허용하지 않는다. `force_destroy = false`이므로 남은 access key가 있으면 IAM user
삭제도 실패한다.

backend key는 `platform/infra/aws/tofu-app-ci/v1/terraform.tfstate`다. 이 root는 Jenkins의
OpenTofu plan job 범위 밖이며 administrator만 `TOFU-STATE` 잠금으로 apply한다.
