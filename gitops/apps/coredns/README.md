# CoreDNS private AWS zone forwarding

`coredns-custom`은 k3s packaged CoreDNS가 이미 import하는 optional ConfigMap이다.
CoreDNS의 `cluster.local` Service/Pod DNS와 일반 재귀 경로는 건드리지 않는다.

`AWS-HR-01-FIX-01`은 ClusterFirst Pod가 `aws.imcherry5778.xyz`와 EKS private API
zone을 조회할 때만 `k3s-01:1053` DNS relay로 전달한다. relay는 다시 Route 53 Resolver
inbound endpoint로 두 zone만 전달한다. 따라서 Pomerium이 internal ALB 별칭을 해석할 수
있고, 이 ConfigMap이 랩 DNS나 public DNS의 새 단일 원본이 되지 않는다.

rollback은 이 Application을 이전 revision으로 되돌려 ConfigMap을 prune한 뒤 CoreDNS
Deployment를 한 번 재시작한다. VPN, Route 53, OPNsense forwarder, Pomerium Route와
NetworkPolicy는 rollback 대상이 아니다.
