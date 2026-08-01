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

같은 날 `NET-03`에서 VLAN 20~50의 임시 IPv4 bootstrap 방화벽 경계를 적용하고 재부팅 후에도 저장 설정과 PF 런타임이 유지됨을 확인했다. 실제 주소와 검증 범위는 아래 표와 [NET-03 runbook](runbook/opnsense-vlan-bootstrap-firewall.md)을 따른다.

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

## 현재 NET-03 IPv4 bootstrap 경계

VLAN 20~50에는 다음 순서의 임시 정책이 `LIVE`다. 이 정책은 서비스 포트를 미리 열지 않고 구축에 필요한 이름 해석·시간 동기화와 공개 Web 용도의 RFC1918 외 egress만 제공한다.

| 순서 | 출발 | 도착 | 정책 |
|---|---|---|---|
| 1 | 각 project VLAN | 해당 VLAN OPNsense gateway | DNS TCP/UDP 53 허용 |
| 2 | 각 project VLAN | 해당 VLAN OPNsense gateway | NTP UDP 123 허용 |
| 3 | 각 project VLAN | RFC1918 목적지 | 차단·기록 |
| 4 | 각 project VLAN | 그 밖의 목적지 | TCP 80/443 허용 |
| 5 | 각 project VLAN | 위에 없는 목적지·포트 | PF implicit deny |

RFC1918 차단 alias는 `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`을 포함하고 공개 Web port alias는 80과 443만 포함한다. 따라서 뒤의 Web 허용이 OPNsense·Proxmox 관리면, HOME이나 다른 project VLAN의 TCP 80/443을 우회하지 못한다. 기존 LAN/HOME 규칙은 재배열하지 않았고, MGMT에서 시작한 project VLAN 관리 연결의 stateful 응답은 유지된다.

project VLAN에는 routed IPv6 prefix·RA·IPv6 gateway가 없어 IPv6 broad allow를 만들지 않았다. DHCP도 활성화하지 않았고 automatic outbound NAT를 유지했다. 이 경계는 모든 신규 서비스를 위한 최종 allowlist가 아니며, `NET-04`에서 실제 서비스 통신표와 `vlan-verify hardened` 결과로 최소화한다.

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

방화벽에서는 DATA VLAN의 `NET03_PRIVATE_V4` 차단 규칙보다 앞선 순서(seq 1315)에
`AWSNET01_VPC_V4` alias 목적지 허용 규칙을 두었다. 이 규칙은 프로토콜·포트를 좁히지 않은
임시 규칙이며 `NET-04`가 실제 통신표로 다시 판정한다.

역방향(AWS에서 온프레미스로 신규 연결)은 허용하지 않는다. OPNsense는 IPsec 터널에
`pass out on enc0 ... keep state`만 두므로 온프레미스가 개시한 흐름과 그 응답만 지난다.

오프사이트 백업 전송은 이 VPN을 쓰지 않고 계속 공인 AWS API endpoint로 나간다.

## 목표 방화벽 정책

기본값은 VLAN 간 차단이다. 아래 허용은 서비스가 실제로 요구하는 목적지와 포트로 구현한다.

| 출발 | 도착 | 정책 |
|---|---|---|
| `PLATFORM` | `MGMT` | 차단 |
| `DMZ` | `MGMT` | 차단 |
| `ACCESS` | 관리·플랫폼·데이터 대상 | Warpgate가 중계할 관리 포트만 허용 |
| `PLATFORM` | `DATA` | 서비스별 PostgreSQL·S3 포트만 허용 |
| `DMZ` | `PLATFORM` | Keycloak·필수 control API만 허용 |
| `DMZ` | `DATA` | 기본 차단; 제품 요구가 검증된 경우만 예외 |
| `DATA` | 인터넷 | 업데이트·AWS S3 등 필요한 egress만 허용 |
| 외부 | 내부 | 공개하기로 한 Traefik·NetBird endpoint만 허용 |
| 각 VLAN | OPNsense | DNS·NTP·DHCP 등 기반 포트만 허용; 관리 UI는 차단 |

초기 구축 중 임시 규칙이 필요하면 설명·만료 조건·삭제 작업 ID를 함께 기록한다. 최종 공개 전에 `vlan-verify` hardened profile과 실제 서비스 통신으로 검증한다.

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
| `sso.imcherry5778.xyz` | service alias | Keycloak | 외부 인증 연동 가능 | Unbound alias → `k3s-01` (`10.10.20.10`) |
| `access.imcherry5778.xyz` | service alias | Pomerium 보호 Dashy 포털 | 보호된 외부 접근 가능 | Unbound alias → `k3s-01` (`10.10.20.10`); POM-01 등록 |
| `argo.imcherry5778.xyz` | service alias | Argo CD | Pomerium | 미등록 |
| `headlamp.imcherry5778.xyz` | service alias | Headlamp | Pomerium | 미등록 |
| `vault.imcherry5778.xyz` | service alias | Vault | 내부 관리 경로만 | 미등록 |
| `git.imcherry5778.xyz` | service alias | Gitea | Pomerium | 미등록 |
| `jenkins.imcherry5778.xyz` | service alias | Jenkins | Pomerium | 미등록 |
| `sonar.imcherry5778.xyz` | service alias | SonarQube | Pomerium | 미등록 |
| `harbor.imcherry5778.xyz` | service alias | Harbor | UI는 Pomerium, registry API는 별도 인증 | 미등록 |
| `awx.imcherry5778.xyz` | service alias | AWX | Pomerium | 미등록 |
| `grafana.imcherry5778.xyz` | service alias | Grafana | Pomerium | 미등록 |
| `netbird.imcherry5778.xyz` | service alias | NetBird control plane | 외부 | 미등록 |
| `warpgate.imcherry5778.xyz` | service alias | Warpgate 서비스 | 내부·NetBird 경유 | 미등록 |
| `postgres.imcherry5778.xyz` | service alias | PostgreSQL | 내부, 비 HTTP | 미등록 |
| `s3.imcherry5778.xyz` | service alias | SeaweedFS S3 API | 내부, 비 Pomerium 데이터 경로 | Unbound alias 등록; TLS S3 TCP 8333 |

canonical host의 주소는 이 문서의 고정 배정 표를 참조한다. `Unbound 등록`은 내부 host override 상태이며 공개 DNS 상태와는 별개다. service alias는 해당 서비스와 진입 경로를 검증한 뒤 등록한다.

Keycloak issuer는 `https://sso.imcherry5778.xyz`로 고정한다. k3s 웹 서비스의 내부 레코드는 Traefik 진입 주소를 가리키고, 공개 서비스는 공인 DNS와 Unbound override를 함께 검증한다.

## 인증서 이름과 공개 DNS 경계

공인 인증서는 서비스 계층별로 발급한다. OPNsense, Proxmox와 k3s는 인증서 private key와 DNS API token을 공유하지 않는다.

- Proxmox 인증서 식별자는 위 표의 canonical host 하나다. 별도 service alias나 wildcard 이름을 추가하지 않는다.
- Proxmox 관리 endpoint는 내부 주소의 HTTPS 8006을 유지한다. 공인 인증서 발급은 public A/AAAA, Cloudflare proxy, NAT 또는 443 공개를 뜻하지 않는다.
- DNS-01은 공개 zone에 임시 `_acme-challenge` TXT만 만들며 발급 후 제거한다. 내부 Unbound host override는 그대로 유지한다.
- 공인 CA의 Certificate Transparency log에는 canonical hostname이 공개될 수 있지만 내부 주소는 인증서에 넣지 않는다.

인증서 소유권과 사설 CA 대안은 [ADR-0009](adr/0009-proxmox-native-acme-management-tls.md)을 따른다.
