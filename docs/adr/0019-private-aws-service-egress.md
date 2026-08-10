# ADR-0019: 애플리케이션 AWS 네트워크의 service endpoint egress

## 배경

애플리케이션 network root는 EKS node와 RDS security group에 인터넷 전체 egress를 선언하고,
public subnet에서 instance 공인 IP를 자동 할당했다. 현재 app network state와 실제 리소스는
없으며, 이 선언은 Trivy `HIGH`·`CRITICAL` gate에서 차단된다. 목표 아키텍처는 AWS VPC를
on-premises와 사설 경로로 연결하고 최소 권한을 우선한다.

## 결정

public subnet은 NAT Gateway와 internet-facing ELB의 주소만 수용하고 instance 공인 IP 자동
할당은 끈다. EKS private application subnet은 ECR API/DKR, S3, STS의 VPC endpoint와 RDS
PostgreSQL 5432/TCP만 egress로 허용한다. RDS와 interface endpoint security group에는 새
outbound flow를 선언하지 않는다.

## 검토한 대안

- 전체 인터넷 egress를 유지하고 Trivy 예외를 둔다: ECR 필요성을 넘어 임의 목적지 접근을
  허용하므로 채택하지 않는다.
- NAT Gateway와 public subnet을 지금 제거한다: 향후 internet-facing ELB 요구까지 함께
  바꾸므로 이 CI 보정 범위를 넘는다.
- 필요한 AWS service endpoint를 그때마다 추가한다: 새 API 필요 시 목적·비용·정책을 다시
  검토할 수 있어 채택한다.

## 결과

EKS node의 이미지 pull·IRSA STS·S3 접근은 사설 endpoint 경로를 사용한다. AWS API를 더 쓰는
워크로드는 해당 endpoint와 exact rule 없이는 실패하며, 이를 공개 egress로 우회하지 않는다.
Interface endpoint에는 시간당·AZ별 비용이 생긴다.

## 재검토 조건

EKS control-plane endpoint 방식, 다른 AWS API, egress proxy, multi-account VPC 공유 또는
internet-facing workload의 실제 요구가 확정되면 재검토한다.
