# ADR-0022: HR EKS를 기존 AWS shared VPC와 기존 k3s Argo CD에 통합

## 배경

`AWS-NET-01`은 이미 사설 AWS VPC, VGW, OPNsense Customer Gateway와 DATA 전용 VPN state를
소유한다. `AWS-HR-01`의 초기 선언은 별도 VPC와 VGW를 만들었으나, HR workload도 기존 AWS VPC에
통합해야 한다는 운영 의도와 맞지 않았다. 별도 VPC는 S2S 연결·endpoint·운영 control plane을
중복시키고, EKS 안에 새 Argo CD를 bootstrap하면 source Git 접근을 위해 AWS에서 온프레미스로 향하는
추가 경계가 필요해진다.

## 결정

기존 `tofu-network`는 shared VPC, VGW, Customer Gateway와 DATA VPN의 유일한 소유자로 유지한다.
`tofu-app-network`는 그 state를 read-only로 읽고 HR 전용 application/DB subnet, route table,
PrivateLink endpoint와 security group만 소유한다. VPC나 default security group을 import하거나
중복 선언하지 않는다.

HR용 VPN은 기존 VGW와 Customer Gateway를 참조하는 별도 policy-based connection으로 만든다. 기존
DATA selector를 넓히지 않고, HR에 필요한 PLATFORM VLAN만 별도 selector와 static route로 연결한다.

GitOps control plane은 기존 k3s Argo CD를 유지하고 EKS를 destination cluster로 등록한다. EKS에는
Argo CD를 별도 설치하지 않으며, Argo의 EKS 권한은 전용 IAM principal, EKS Access Entry와 Vault
runtime credential으로 제한한다.

## 검토한 대안

- 별도 HR VPC를 계속 유지한다: 의도한 단일 AWS 사설망과 달라지고 VPN·endpoint·운영 경계가 중복돼
  채택하지 않는다.
- 기존 DATA VPN selector를 넓힌다: 기존 검증된 DATA 경로의 영향 범위가 커지고 새 HR 실패가 DATA
  경로를 방해할 수 있어 채택하지 않는다.
- EKS 안에 별도 Argo CD를 설치한다: source Git을 향한 역방향 네트워크 허용과 bootstrap image lifecycle이
  필요해져 채택하지 않는다.
- Transit Gateway를 도입한다: VPC 하나와 온프레미스 사이트 하나인 현재 구조에서는 비용과 운영면만
  늘어나므로 채택하지 않는다.

## 결과

기존 VPC에 배치된 EKS와 Aurora는 VPC를 제자리에서 변경할 수 없으므로, 초기 별도 VPC의 리소스는
final snapshot을 확보한 뒤 제거하고 shared VPC에 재생성한다. ECR repository와 Jenkins image publisher는
VPC 비종속 자원이므로 유지한다.

각 root는 자기 state만 바꾸며, legacy state를 옮기거나 합치지 않는다. 새 VPN connection state는
tunnel PSK를 포함할 수 있으므로 administrator OpenTofu만 접근하고 Jenkins plan 권한에는 넣지 않는다.

## 재검토 조건

두 번째 AWS VPC나 다른 온프레미스 사이트가 실제로 필요해져 Transit Gateway가 단순한 VGW보다
경계를 줄이는 경우, 또는 EKS가 독립된 GitOps control plane·소스 repository 복제를 요구하는 경우다.
