# HR application database root

이 root는 private Aurora PostgreSQL Serverless v2 cluster, DB subnet/log group과 세 Secrets
Manager secret을 소유한다. DB subnet과 RDS security group은 `tofu-app-network`의 v1 remote
state 출력만 소비하므로 CI나 운영자가 ID를 복사해 주입하지 않는다. Aurora master password는
AWS managed secret으로 생성하며 tfvars에 넣지 않는다.
`employee-service`와 `hr-service` password는 각각 다른 secret으로 생성된다. 두 DB role의 SQL
생성은 EKS migration Job이 master와 두 service secret을 한 번만 읽어 수행한다.

Aurora는 public access 금지, storage encryption, 7일 automated backup, final snapshot, deletion
protection과 `prevent_destroy`를 함께 강제한다. Serverless v2 capacity는 0.5~4 ACU로 제한한다.
서비스 Pod는 자기 secret만 IRSA로 읽으며 master secret은 migration Job 외에는 접근할 수 없다. backend는
`platform/infra/aws/tofu-app-db/v1/terraform.tfstate`다.
