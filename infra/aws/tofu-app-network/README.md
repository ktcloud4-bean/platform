# 애플리케이션 네트워크 계층 · OpenTofu

이 root는 애플리케이션 VPC, public·app private·DB private subnet, NAT Gateway와 EKS node/RDS
security group을 소유한다. public subnet은 NAT Gateway와 internet-facing ELB용일 뿐, 새 instance에
공인 IP를 자동 배정하지 않는다.

EKS private application subnet의 egress는 다음으로 고정한다.

- ECR API/DKR와 STS: 각 AZ의 Interface VPC endpoint HTTPS
- S3: Gateway VPC endpoint HTTPS
- RDS: RDS security group의 PostgreSQL 5432/TCP

일반 인터넷 egress와 RDS의 새 outbound flow는 선언하지 않는다. 다른 AWS API가 필요하면
`0.0.0.0/0` 예외를 추가하지 않고, 목적 endpoint와 보안 그룹 규칙을 별도 검토한다.

## 실행 경계

Jenkins는 이 root를 `init`·`validate`·`plan`만 수행한다. backend 없는 최초 plan은 state 객체를
만들지 않는다. 최초 실제 생성은 완료된 plan의 대상·비용 검토와 명시 승인을 거쳐
`TOFU-STATE` 잠금 아래 administrator가 같은 `v1` backend로 실행한다.
