# IP · VLAN · DNS 계획

이 문서는 네트워크 주소의 단일 진실 원천이다. `LIVE`는 검증된 현재값, `RESERVED`는 설치 전 예약, `TARGET`은 전환 후 목표다.

## 물리 인터페이스

| OPNsense 장치 | 현재 | 목표 |
|---|---|---|
| `igc1` | `LIVE` WAN, ISP DHCP | 유지 |
| `igc0` | 미할당, carrier 없음 | 예비; 복구 경로는 OOB 콘솔이 담당 |
| `igc2` | `LIVE` Proxmox 직결 VLAN 10·20·30·40·50 tagged-only trunk; 부모 무주소 | 유지 |
| `igc3` | `LIVE` HOME | 유지, 프로젝트 범위 밖 |

`igc2`는 tagged-only 802.1Q trunk다. 부모 인터페이스에는 주소를 두지 않고 VLAN 인터페이스만 사용한다.

## 주소 규칙

랩은 `10.10.0.0/16` 안에서 VLAN ID와 세 번째 옥텟을 맞춘다.

| 호스트 부분 | 용도 |
|---|---|
| `.1` | OPNsense VLAN gateway |
| `.2-.9` | 물리 네트워크 장비 예약 |
| `.10-.49` | 고정 노드·VM |
| `.50-.99` | VIP·고정 서비스 예약 |
| `.100-.199` | DHCP가 필요한 VLAN의 동적 범위 |
| `.200-.254` | 실험·이전용 예약 |

서버 VLAN에는 필요가 확인되기 전까지 DHCP를 만들지 않는다.

## 현재 네트워크 기준선

2026-07-31 `NET-02R` 검증에서 OPNsense 저장 설정과 재부팅 후 런타임 모두 LAN=`vlan01`, VLAN 20~50 논리 인터페이스·gateway, 부모 `igc2` 무주소 상태로 일치했다. Proxmox 관리는 `vmbr0.10`으로 유지됐고, 격리 namespace에서 untagged VLAN 10은 ARP 응답이 없으며 tagged VLAN 10~50은 모두 gateway ARP 응답이 있었다.

2026-08-03 `NET-04`에서 VLAN 20~50의 임시 bootstrap 경계를 현재 배포 host와 실제
서비스 통신표에 맞춘 최종 IPv4 규칙으로 교체했다. 저장 의미값, PF runtime, 실제 source별
`vlan-verify hardened`, 최종 drift 없음은
[NET-04 runbook](runbook/opnsense-vlan-firewall-hardening.md)을 따른다.

| 주소 | 대상 | 상태 |
|---|---|---|
| `10.10.10.1/24` | `opnsense` VLAN 10 MGMT gateway | `LIVE`; `vlan01` |
| `10.10.10.10/24` | `proxmox-01` (`vmbr0.10`) | `LIVE` |

현재 LAN DHCP는 `10.10.10.100-10.10.10.245`다. 임시 설치 환경의 동적 주소는 문서에 고정 배정으로 올리지 않는다.

## 목표 VLAN

VLAN 번호는 보안 등급 순서가 아니라 역할 식별자다. 실제 신뢰 경계는 방화벽 규칙이 만든다.

| VLAN | 이름 | 대역 | 주 대상 |
|---|---|---|---|
| 10 | `MGMT` | `10.10.10.0/24` | OPNsense · Proxmox |
| 20 | `PLATFORM` | `10.10.20.0/24` | k3s |
| 30 | `ACCESS` | `10.10.30.0/24` | Warpgate |
| 40 | `DMZ` | `10.10.40.0/24` | NetBird · 공개 진입면 |
| 50 | `DATA` | `10.10.50.0/24` | PostgreSQL · 로컬 S3 |
| 60 | `HOME` | `10.10.60.0/24` | 프로젝트 범위 밖 |

### 고정 배정

| 주소 | 호스트 | 상태 |
|---|---|---|
| `10.10.10.1` | `opnsense` | `LIVE`; `vlan01` |
| `10.10.10.10` | `proxmox-01` | `LIVE`; `vmbr0.10` |
| `10.10.20.1` | OPNsense `PLATFORM` gateway | `LIVE` |
| `10.10.20.10` | `k3s-01` | `LIVE`; VMID 120 |
| `10.10.30.1` | OPNsense `ACCESS` gateway | `LIVE` |
| `10.10.30.10` | `warpgate-01` | `LIVE`; VMID 130 |
| `10.10.40.1` | OPNsense `DMZ` gateway | `LIVE` |
| `10.10.40.10` | `netbird-01` | `LIVE`; VMID 140 |
| `10.10.50.1` | OPNsense `DATA` gateway | `LIVE` |
| `10.10.50.10` | `postgres-01` | `LIVE`; VMID 150 |
| `10.10.50.20` | `object-01` | `LIVE`; VMID 151; SeaweedFS S3 |

2026-07-31 `VM-01`에서 다섯 주소를 cloud-init 고정 배정으로 적용하고 재부팅 후까지 검증해 `RESERVED`에서 `LIVE`로 올렸다. 각 게스트는 자기 VLAN gateway를 default route와 DNS resolver로 쓰고, 실제 source에서 실행한 `vlan-verify bootstrap`이 통과했다. VMID 규칙과 VM 계약은 [`infra/proxmox/tofu/README.md`](../infra/proxmox/tofu/README.md)가 소유한다.

2026-07-31 `S3-01`은 같은 주소·VMID 151·200 GiB disk를 보존한 채 canonical 이름을
`object-01`로 전환했다. Unbound에는 `object-01` A/PTR과 `s3` service alias가
등록됐고, 이전 `minio-01` canonical override는 제거했다. 두 canonical 이름은 동시에
유지하지 않는다.

### Kubernetes 내부 대역

| 대역 | 용도 | 상태 |
|---|---|---|
| `10.42.0.0/24` | 단일 `k3s-01` node의 Pod CIDR | `LIVE`; Node `spec.podCIDR` 실측 |

이 node slice만 Keycloak의 신뢰 proxy 범위로 쓴다. Traefik 밖 출발지가
`X-Forwarded-*`를 보내도 Keycloak이 신뢰하지 않는다. 노드 추가로 Pod CIDR이 늘어나면
전체 cluster CIDR을 넓게 신뢰하지 말고 실제 ingress source 범위를 다시 검증한다.

## 물리 토폴로지

```text
OPNsense igc2
    │ tagged-only: VLAN 10, 20, 30, 40, 50
    │
Proxmox NIC ── VLAN-aware bridge
    ├─ Proxmox management: VLAN 10
    ├─ k3s-01:             VLAN 20
    ├─ warpgate-01:        VLAN 30
    ├─ netbird-01:         VLAN 40
    ├─ postgres-01:        VLAN 50
    └─ object-01:          VLAN 50
```

- VLAN 1과 native/untagged 트래픽을 최종 트렁크에 사용하지 않는다.
- 관리 VLAN 전환은 OOB 콘솔 복구 경로를 검증한 뒤에만 한다.
- Proxmox bridge는 VLAN을 전달하고, VLAN 간 라우팅은 OPNsense만 담당한다.

## 현재 NET-04 IPv4 최소 경계

VLAN 20~50의 source는 VLAN 전체가 아니라 위 고정 배정 표의 현재 배포 VM `/32`로
한정한다. 각 source는 자기 gateway의 DNS TCP/UDP 53과 NTP UDP 123을 쓰며, 비공개·
특수용 IPv4를 먼저 차단한 뒤 public IPv4 TCP 80/443만 쓴다. 실제 cross-VLAN 예외는
다음 여섯 경로뿐이다.

- `k3s-01` → `postgres-01` TCP 5432
- `k3s-01` → `object-01` TCP 8333
- `warpgate-01` → `k3s-01` TCP 443
- `warpgate-01` → `netbird-01` TCP 443
- `warpgate-01` → 현재 여섯 관리 host TCP 22
- `netbird-01` → `k3s-01` TCP 443

정확한 rule·alias 의미값과 순서, 소유 작업, 근거, rollback은
[NET-04 runbook](runbook/opnsense-vlan-firewall-hardening.md)이 소유한다. EDGE-01이 추가한
ACCESS→NetBird TCP 443 exact rule과 rollback은
[공개 진입 runbook](runbook/netbird-public-edge.md)이 소유한다. 같은 DATA VLAN의
host 간 통신은 OPNsense를 지나지 않으므로 OPNsense 차단 근거로 쓰지 않는다. project
VLAN에는 routed IPv6 prefix·RA·gateway가 없고 IPv6 broad allow를 만들지 않았다. 기존
LAN/HOME 규칙, DHCP와 automatic outbound NAT도 바꾸지 않았다.

## AWS 사설 착지점

2026-07-31 `AWS-NET-01`에서 OPNsense와 AWS를 policy-based Site-to-Site VPN으로 연결했다.
토폴로지 결정은 [ADR-0011](adr/0011-aws-site-to-site-vpn-boundary.md), 절차와 증거는
[AWS VPN runbook](runbook/aws-site-to-site-vpn.md)이 소유한다.

| 대역 | 대상 | 상태 |
|---|---|---|
| `10.20.0.0/16` | AWS 사설 착지점 VPC | `LIVE`; 인터넷 gateway 없음 |
| `10.20.1.0/24` | 사설 서브넷 (단일 AZ) | `LIVE` |

랩 대역 `10.10.0.0/16`, 계정 default VPC `172.31.0.0/16`과 겹치지 않는다. 터널의 IPsec
traffic selector는 `10.10.50.0/24 ↔ 10.20.0.0/16`이며, 이 selector 밖 출발지는 암호화
계층에서 이미 통신할 수 없다. AWS 쪽 터널 endpoint 주소는 재생성 때마다 바뀌므로 이
문서에 고정값으로 적지 않고 OpenTofu output에서 읽는다.

`AWS-NET-01`이 만들었던 DATA→VPC 전체 프로토콜 임시 rule과 `AWSNET01_VPC_V4` alias는
현재 서비스 소비자가 없어 2026-08-03 `NET-04`에서 제거했다. IPsec connection과
traffic selector는 유지하지만 새 DATA→VPC 연결은 기본 차단한다.

역방향(AWS에서 온프레미스로 신규 연결)은 허용하지 않는다. OPNsense는 IPsec 터널에
`pass out on enc0 ... keep state`만 두므로 온프레미스가 개시한 흐름과 그 응답만 지난다.

오프사이트 백업 전송은 이 VPN을 쓰지 않고 계속 공인 AWS API endpoint로 나간다.

## 방화벽 정책

기본값은 VLAN 간 차단이다. 아래 허용은 서비스가 실제로 요구하는 목적지와 포트로 구현한다.

| 출발 | 도착 | 정책 |
|---|---|---|
| `PLATFORM` | `MGMT` | 차단 |
| `DMZ` | `MGMT` | 차단 |
| `ACCESS` | 관리·플랫폼·데이터 대상 | Warpgate 중계 관리 포트와 Warpgate direct peer의 NetBird control TCP 443만 허용 |
| `PLATFORM` | `DATA` | 서비스별 PostgreSQL·S3 포트만 허용 |
| `DMZ` | `PLATFORM` | Keycloak·필수 control API만 허용 |
| `DMZ` | `DATA` | 기본 차단; 제품 요구가 검증된 경우만 예외 |
| `DATA` | 인터넷 | 업데이트·AWS S3 등 필요한 egress만 허용 |
| 외부 | 내부 | NetBird TCP 80/443·UDP 3478만 허용; Traefik 공개는 `EDGE-02 DEFERRED` |
| 각 VLAN | OPNsense | DNS·NTP·DHCP 등 기반 포트만 허용; 관리 UI는 차단 |

2026-08-03 `NET-04`가 공개 진입을 제외한 배포 서비스 경계를 구현하고 실제 source별
`vlan-verify hardened`로 검증했다. 초기 구축 중 임시 규칙이 필요하면 설명·만료 조건·
삭제 작업 ID를 함께 기록하고, 서비스 추가 때는 NET-04 통신표와 exact host·port 경계를
함께 갱신한다. `EDGE-01`은 Warpgate direct peer의 control 연결을 위해 ACCESS의
`warpgate-01`에서 DMZ의 `netbird-01` TCP 443로 가는 host 단위 예외 하나만 추가한다.
NetBird 단독 외부 공개 정책은 `EDGE-01`, 조건부 Cloudflare HTTP 공개는 `EDGE-02`가 소유한다.

## DNS와 도메인

랩 도메인은 `imcherry5778.xyz`다. OPNsense Unbound가 내부 응답과 split DNS를 담당하고, Kubernetes CoreDNS는 클러스터 내부 이름만 담당한다.

| 이름 | 종류 | 대상 | 노출 | 내부 DNS |
|---|---|---|---|---|
| `opnsense.imcherry5778.xyz` | canonical host | OPNsense 관리 | 내부 | Unbound 등록 |
| `proxmox-01.imcherry5778.xyz` | canonical host | Proxmox 관리 | 내부 | Unbound 등록 |
| `k3s-01.imcherry5778.xyz` | canonical host | k3s 노드 | 내부 | Unbound 등록 |
| `postgres-01.imcherry5778.xyz` | canonical host | PostgreSQL VM | 내부 | Unbound 등록 |
| `object-01.imcherry5778.xyz` | canonical host | SeaweedFS 로컬 S3 VM | 내부 | Unbound 등록; A/PTR `10.10.50.20` |
| `warpgate-01.imcherry5778.xyz` | canonical host | Warpgate VM | 내부 | Unbound 등록 |
| `netbird-01.imcherry5778.xyz` | canonical host | NetBird VM | 내부 | Unbound 등록 |
| `sso.imcherry5778.xyz` | service alias | Keycloak | 내부·NetBird 경유; 외부 OIDC는 `EDGE-02 DEFERRED` | Unbound alias → `k3s-01` (`10.10.20.10`) |
| `access.imcherry5778.xyz` | service alias | Pomerium 보호 Dashy 포털 | 내부·NetBird 경유; clientless 공개는 `EDGE-02 DEFERRED` | Unbound alias → `k3s-01` (`10.10.20.10`); POM-01 등록 |
| `argo.imcherry5778.xyz` | service alias | Argo CD | Pomerium; 실제 권한은 Argo 자체 OIDC·RBAC가 판정 | Unbound alias → `k3s-01` (`10.10.20.10`); GITOPS-02 등록, 내부 AAAA·공개 A/AAAA 0건 |
| `headlamp.imcherry5778.xyz` | service alias | Headlamp | Pomerium | `TARGET`; HEADLAMP-02 `OPNSENSE-LIVE` 승인 뒤 Unbound alias → `k3s-01` (`10.10.20.10`), 내부 AAAA·공개 A/AAAA 0건 |
| `vault.imcherry5778.xyz` | service alias | Vault | Pomerium 미경유 표준 Ingress; 실제 권한은 Vault 자체 OIDC·policy가 판정 | Unbound alias → `k3s-01` (`10.10.20.10`); VAULT-03 등록, 내부 AAAA·공개 A/AAAA 0건 |
| `git.imcherry5778.xyz` | service alias | Gitea | UI는 Pomerium, Git data는 사설 SSH | Unbound alias → `k3s-01` (`10.10.20.10`); SCM-01 등록, 내부 AAAA 0건 |
| `jenkins.imcherry5778.xyz` | service alias | Jenkins | Pomerium | Unbound alias → `k3s-01` (`10.10.20.10`); CI-01 등록, 내부 AAAA 0건 |
| `sonar.imcherry5778.xyz` | service alias | SonarQube | Pomerium | Unbound alias → `k3s-01` (`10.10.20.10`); QUALITY-01 등록, 내부 AAAA 0건 |
| `harbor.imcherry5778.xyz` | service alias | Harbor | UI는 Pomerium, registry API는 별도 인증 | Unbound alias → `k3s-01` (`10.10.20.10`); REG-01 등록 |
| `awx.imcherry5778.xyz` | service alias | AWX | Pomerium | Unbound alias → `k3s-01` (`10.10.20.10`); AWX-01 등록 |
| `grafana.imcherry5778.xyz` | service alias | Grafana | Pomerium | Unbound alias → `k3s-01` (`10.10.20.10`); OBS-02 등록, 내부 AAAA·공개 A/AAAA 0건 |
| `prometheus.imcherry5778.xyz` | service alias | Prometheus | Pomerium | Unbound alias → `k3s-01` (`10.10.20.10`); OBS-02 등록, 내부 AAAA·공개 A/AAAA 0건 |
| `alertmanager.imcherry5778.xyz` | service alias | Alertmanager | Pomerium | Unbound alias → `k3s-01` (`10.10.20.10`); OBS-02 등록, 내부 AAAA·공개 A/AAAA 0건 |
| `netbird.imcherry5778.xyz` | service alias | NetBird control plane | 외부 DNS-only A; 공개 AAAA 없음 | 미등록 |
| `warpgate.imcherry5778.xyz` | service alias | Warpgate 서비스 | 내부·NetBird 경유 | Unbound alias → `warpgate-01` (`10.10.30.10`); WG-02 등록 |
| `postgres.imcherry5778.xyz` | service alias | PostgreSQL | 내부, 비 HTTP | 미등록 |
| `s3.imcherry5778.xyz` | service alias | SeaweedFS S3 API | 내부, 비 Pomerium 데이터 경로 | Unbound alias 등록; TLS S3 TCP 8333 |

canonical host의 주소는 이 문서의 고정 배정 표를 참조한다. `Unbound 등록`은 내부 host override 상태이며 공개 DNS 상태와는 별개다. service alias는 해당 서비스와 진입 경로를 검증한 뒤 등록한다.

Keycloak issuer는 `https://sso.imcherry5778.xyz`로 고정한다. k3s 웹 서비스의 내부 레코드는 Traefik 진입 주소를 가리키고, 공개 서비스는 공인 DNS와 Unbound override를 함께 검증한다.

`EDGE-01`의 공개 권위 DNS allowlist는 DNS-only `netbird.imcherry5778.xyz` A 한 건이며
그 밖의 A·AAAA·CNAME은 0건이다. 이전 `ktcloud4-acer` 프로젝트가 Tailscale CGNAT 주소에
만들었던 DNS-only A 26건과 중단된 Cloudflare Tunnel을 가리키는 proxied CNAME 5건은 더
이상 사용하지 않는 잔여로 확인해 제거했다. 보존한 `netbird` A는 작업 시작 시 현재 WAN과
달랐던 값을 교정했으며 DNS-only와 TTL 120초를 유지한다. `access`·`sso` 공개 A와 Traefik 대상 WAN
NAT는 만들지 않는다. 외부 OIDC 셀프서비스나 clientless Portal이 필요해지면
`EDGE-02`에서 hostname·origin·WAF·TCP 443 소유권을 함께 재설계한다.

## 인증서 이름과 공개 DNS 경계

공인 인증서는 서비스 계층별로 발급한다. OPNsense, Proxmox, k3s와 Warpgate는 인증서 private key와 DNS API token을 공유하지 않는다.

- Proxmox 인증서 식별자는 위 표의 canonical host 하나다. 별도 service alias나 wildcard 이름을 추가하지 않는다.
- Proxmox 관리 endpoint는 내부 주소의 HTTPS 8006을 유지한다. 공인 인증서 발급은 public A/AAAA, Cloudflare proxy, NAT 또는 443 공개를 뜻하지 않는다.
- Warpgate 인증서 식별자는 `warpgate.imcherry5778.xyz` 한 이름이다. 내부 Unbound alias와 TCP 8888을 유지하며 public A/AAAA·NAT를 만들지 않는다.
- NetBird 와일드카드 인증서는 DNS-only 공개 A와 기존 TCP 80/443·UDP 3478 경로에서만 쓰며 Cloudflare proxy나 다른 서비스 origin에 재사용하지 않는다.
- DNS-01은 공개 zone에 임시 `_acme-challenge` TXT만 만들며 발급 후 제거한다. 내부 Unbound host override는 그대로 유지한다.
- 공인 CA의 Certificate Transparency log에는 canonical hostname이 공개될 수 있지만 내부 주소는 인증서에 넣지 않는다.

인증서 소유권과 사설 CA 대안은 [ADR-0009](adr/0009-proxmox-native-acme-management-tls.md)을 따른다.
