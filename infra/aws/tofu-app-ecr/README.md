# HR application ECR root

이 root는 `frontend`, `employee-service`, `hr-service` 세 image repository를 소유한다. 세
repository 모두 immutable tag, push scan, AES256 encryption, force delete 금지와 rollback을 위한
tagged image 90개 보존을 강제한다. Jenkins는 digest와 SBOM·Cosign artifact를 검증한 뒤에만
release tag를 push하며, GitOps는 tag가 아닌 digest를 참조한다.

backend는 `platform/infra/aws/tofu-app-ecr/v1/terraform.tfstate`다. Jenkins는 init·validate·plan
전용이며 최초 생성은 administrator가 `TOFU-STATE` 잠금 아래 별도 승인으로 수행한다.
