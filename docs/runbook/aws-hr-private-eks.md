# AWS-HR-01 private EKS 운영

## 경계와 소유권

HR workload는 shared VPC `10.20.0.0/16`의 private EKS·Aurora에만 배치한다. public DNS,
NAT, Internet Gateway, public EKS endpoint와 internet-facing ALB는 만들지 않는다.

| 계층 | 소유자 | 경계 |
|---|---|---|
| shared VPC·VGW·단일 S2S VPN | `infra/aws/tofu-network` | `10.10.0.0/16 ↔ 10.20.0.0/16` 암호화 가능 대역 |
| HR subnet·PrivateLink·security group·Resolver | `tofu-app-network` | EKS node, Aurora, AWS API의 private path |
| HR private return route | `tofu-app-vpn` | HR subnet에서 PLATFORM return만 |
| EKS·IRSA | `tofu-app-eks` | private API와 workload AWS 권한 |
| Argo EKS destination | `tofu-app-argocd` | Vault runtime credential·EKS access entry |
| ALB private alias | `tofu-app-routing` | controller-created ALB의 Route 53 private alias만 |
| App manifests | `gitops/apps/hr-system` | signed ECR digest·PSS·NetworkPolicy·Ingress |

`tofu-app-routing`은 ALB를 import하지 않는다. AWS Load Balancer Controller가 Kubernetes
Ingress lifecycle로 ALB를 만들고, 해당 root는 생성 뒤 stable private alias만 적용한다.

## 실제 흐름

```text
NetBird client → k3s Traefik → Pomerium
  www: /platform-users, admin: /hr-admins
                         ↓ IPsec
               internal ALB :80 → EKS frontend :8080
                                      ├→ employee-service :8000
                                      └→ hr-service :8000 → Aurora :5432

k3s Argo → EKS private API :443
ClusterFirst Pod → CoreDNS private-zone forward → k3s-01:1053
OPNsense Unbound → k3s-01:1053 → Route 53 Resolver endpoint :53
```

단일 VPN selector는 허용 rule이 아니다. OPNsense에서 `k3s-01`만 Resolver DNS TCP/UDP 53,
EKS API TCP 443, internal ALB TCP 80을 개시할 수 있다. application namespace는 VPC CNI
NetworkPolicy default-deny를 쓰고 CoreDNS DNS, AWS HTTPS/DB egress만 별도로 허용한다. EKS
node security group도 VPC resolver뿐 아니라 CoreDNS Pod가 있는 private application subnet의
DNS TCP/UDP 53을 허용해야 ClusterFirst Pod DNS가 동작한다.

## 배포 순서

1. `tofu-app-network`, `tofu-app-vpn`, `tofu-app-eks`, `tofu-app-argocd`의 no-change plan과
   Argo EKS runtime registration을 확인한다.
2. `aws_hr_dns_relay` Ansible role과 CoreDNS `coredns` child Application을 적용한다. relay는
   두 AWS private zone만 Route 53 Resolver inbound endpoint로 전달하고, CoreDNS는 그 두 zone만
   `k3s-01:1053`로 전달한다.
3. 지원 API로 OPNsense의 두 AWS private zone 조건부 forward, `www`·`admin`의 exact
   Unbound alias와 세 exact firewall rule을 적용·검증한다.
4. immutable Git SHA로 platform root를 전환해 AWS Load Balancer Controller와
   `hr-system-bootstrap` child를 healthy로 만든다. bootstrap은 namespace와 migration IRSA
   ServiceAccount를 먼저 만들고, 그 뒤 `hr-system` migration Job과 service Pod를 sync한다.
5. controller-created `hr-system-prod` ALB가 확인된 뒤에만 `tofu-app-routing`을 apply한다.
6. Pomerium `www`·`admin` route를 같은 immutable SHA로 sync하고, root와 child
   `targetRevision`을 literal `main`으로 복귀한다.

`admin` browser admission은 Keycloak의 `/hr-admins` group membership이 별도로 필요하다.
어떤 사람이 HR 관리자가 될지는 GitOps나 OpenTofu가 추정하지 않는다. 선택된 사용자에게만
group을 부여하고, HR application의 DB-level HR 권한도 별도로 판정한다.

## 검증과 rollback

검증은 root/child `Synced/Healthy`, migration 성공, 세 서비스 Ready, controller-created
internal ALB, private alias DNS, 그리고 `k3s-01`에서 EKS private API와 ALB 흐름을 한 번씩
판정한다. 공개 DNS/NAT를 확인 수단으로 만들지 않는다.

merge 전 실패는 `platform-root`를 기록해 둔 main SHA로 되돌려 새 workload와 route를
prune한다. merge 후 서비스 rollback은 새 FIX 작업에서 signed 이전 digest를 선언해 Argo로
수행한다. Aurora, VPN, shared VPC, state를 workload rollback의 일부로 destroy하지 않는다.
