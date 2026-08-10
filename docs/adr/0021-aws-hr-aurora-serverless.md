# ADR-0021: HR DB는 private Aurora PostgreSQL Serverless v2로 선택

## 배경

`AWS-HR-01`의 private RDS PostgreSQL instance 최초 생성은 Free account plan의 backup retention 제한으로
거부됐다. Aurora PostgreSQL Serverless도 Free plan에서는 `WithExpressConfiguration`을 요구한다. 이 API
경로는 writer instance와 internet access gateway를 자동 생성하며, 현재 고정한 OpenTofu AWS provider에는
해당 인자가 없다. 이는 private VPC·internal ALB·Pomerium·S2S VPN만 사용하는 HR 경계와 양립하지 않는다.

## 결정

HR DB는 private subnet 안의 Aurora PostgreSQL Serverless v2 cluster와 단일 writer instance로 운영한다.
이 선언은 Paid account plan을 선행으로 요구한다. public endpoint·공인 egress·Express Configuration을 만들지
않고, EKS node security group에서 cluster PostgreSQL 5432/TCP만 허용한다.

master credential은 Aurora managed Secrets Manager secret으로 유지하고, service credential과 bootstrap HR
관리자 입력은 기존처럼 별도 Secrets Manager secret으로 분리한다. 7일 automated backup, encryption, final
snapshot, deletion protection, `prevent_destroy`, CloudWatch PostgreSQL log 보존을 적용한다.

## 검토한 대안

- Free plan에서 Express Configuration을 사용한다: 자동 internet access gateway와 provider 미지원으로
  private-only 경계를 보장할 수 없어 채택하지 않는다.
- Free plan에서 RDS PostgreSQL 보존을 1일로 낮춘다: Aurora 선택과 7일 PITR 기준을 함께 포기해야 하므로
  채택하지 않는다.
- EKS 안에 PostgreSQL을 직접 운영한다: DB와 cluster lifecycle·복구 경계를 다시 결합하므로 채택하지 않는다.

## 결과

Paid plan 전환 후 남은 eligible Free Tier credit은 Aurora를 포함한 청구에 자동 적용된다. credit 소진 뒤에는
Aurora storage와 ACU 사용량 비용이 발생하므로 Cost and Usage에서 credit 잔액을 감시한다. 실패한 RDS 최초
시도에서 남은 빈 parameter/log resource는 Aurora 최초 apply에서 정리했다.

## 재검토 조건

HR의 동시 사용자·데이터량이 4 ACU를 넘는다. reader·cross-region DR·다중 writer 요구가 생기거나
Aurora Free/Paid plan과 OpenTofu provider의 Express Configuration 지원 정책이 바뀐다.
