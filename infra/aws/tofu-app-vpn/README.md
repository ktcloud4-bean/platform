# HR application VPN root

이 root는 `tofu-network`가 소유한 `10.20.0.0/16` shared VPC의 기존 VGW를 read-only remote
state로 참조한다. VPN connection과 selector는 `tofu-network`가 단일 shared
`10.10.0.0/16 ↔ 10.20.0.0/16` connection으로 소유한다. 이 root는 HR private route table의
PLATFORM return route만 소유하며 새 VPN, PSK 또는 tunnel endpoint를 만들지 않는다.

순서:

1. `tofu-app-network`를 먼저 적용해 `v1` state를 만든다.
2. 이 root plan은 HR private route table마다 PLATFORM return route 하나만 만드는지 확인한다.
3. 기존 k3s Argo가 EKS destination을 관리하므로 EKS→Gitea 역방향 SSH는 열지 않는다. k3s
   Pomerium과 Argo node source `/32`의 EKS API·internal ALB TCP 443만 실제 흐름으로 검증한다.

Jenkins plan credential에는 이 state key 권한을 주지 않으며, administrator OpenTofu만 apply를
수행한다.
