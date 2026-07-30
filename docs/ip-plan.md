# IP · VLAN · DNS 계획

이 문서는 네트워크 주소의 단일 진실 원천이다. `LIVE`는 검증된 현재값, `RESERVED`는 설치 전 예약, `TARGET`은 전환 후 목표다.

## 물리 인터페이스

| OPNsense 장치 | 현재 | 목표 |
|---|---|---|
| `igc1` | `LIVE` WAN, ISP DHCP | 유지 |
| `igc0` | 미할당, carrier 없음 | 예비; 복구 경로는 OOB 콘솔이 담당 |
| `igc2` | `LIVE` untagged LAN | Proxmox 직결 tagged-only 802.1Q trunk |
| `igc3` | `LIVE` HOME | 유지, 프로젝트 범위 밖 |

트렁크 전환 전까지 `igc2`는 Phase 1 LAN이다. 전환 후에는 부모 인터페이스에 주소를 두지 않고 VLAN 인터페이스만 사용한다.

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

## 현재 Phase 1

| 주소 | 대상 | 상태 |
|---|---|---|
| `10.10.10.1/24` | `opnsense` LAN gateway | `LIVE` |
| `10.10.10.10/24` | `proxmox-01` | `LIVE` |

현재 LAN DHCP는 `10.10.10.100-10.10.10.245`다. 임시 설치 환경의 동적 주소는 문서에 고정 배정으로 올리지 않는다.

## 목표 VLAN

VLAN 번호는 보안 등급 순서가 아니라 역할 식별자다. 실제 신뢰 경계는 방화벽 규칙이 만든다.

| VLAN | 이름 | 대역 | 주 대상 |
|---|---|---|---|
| 10 | `MGMT` | `10.10.10.0/24` | OPNsense · Proxmox |
| 20 | `PLATFORM` | `10.10.20.0/24` | k3s |
| 30 | `ACCESS` | `10.10.30.0/24` | Warpgate |
| 40 | `DMZ` | `10.10.40.0/24` | NetBird · 공개 진입면 |
| 50 | `DATA` | `10.10.50.0/24` | PostgreSQL · MinIO |
| 60 | `HOME` | `10.10.60.0/24` | 프로젝트 범위 밖 |

### 고정 배정

| 주소 | 호스트 | 상태 |
|---|---|---|
| `10.10.10.1` | `opnsense` | `LIVE`; VLAN 전환 후 VLAN 10 gateway |
| `10.10.10.10` | `proxmox-01` | `LIVE` |
| `10.10.20.1` | OPNsense `PLATFORM` gateway | `TARGET` |
| `10.10.20.10` | `k3s-01` | `RESERVED` |
| `10.10.30.1` | OPNsense `ACCESS` gateway | `TARGET` |
| `10.10.30.10` | `warpgate-01` | `RESERVED` |
| `10.10.40.1` | OPNsense `DMZ` gateway | `TARGET` |
| `10.10.40.10` | `netbird-01` | `RESERVED` |
| `10.10.50.1` | OPNsense `DATA` gateway | `TARGET` |
| `10.10.50.10` | `postgres-01` | `RESERVED` |
| `10.10.50.20` | `minio-01` | `RESERVED` |

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
    └─ minio-01:           VLAN 50
```

- VLAN 1과 native/untagged 트래픽을 최종 트렁크에 사용하지 않는다.
- 관리 VLAN 전환은 OOB 콘솔 복구 경로를 검증한 뒤에만 한다.
- Proxmox bridge는 VLAN을 전달하고, VLAN 간 라우팅은 OPNsense만 담당한다.

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
| `minio-01.imcherry5778.xyz` | canonical host | MinIO VM | 내부 | Unbound 등록 |
| `warpgate-01.imcherry5778.xyz` | canonical host | Warpgate VM | 내부 | Unbound 등록 |
| `netbird-01.imcherry5778.xyz` | canonical host | NetBird VM | 내부 | Unbound 등록 |
| `sso.imcherry5778.xyz` | service alias | Keycloak | 외부 인증 연동 가능 | 미등록 |
| `access.imcherry5778.xyz` | service alias | Pomerium Routes Portal | 보호된 외부 접근 가능 | 미등록 |
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
| `minio.imcherry5778.xyz` | service alias | MinIO API | 내부, 비 Pomerium 데이터 경로 | 미등록 |

canonical host의 주소는 이 문서의 고정 배정 표를 참조한다. `Unbound 등록`은 내부 host override 상태이며 공개 DNS 상태와는 별개다. service alias는 해당 서비스와 진입 경로를 검증한 뒤 등록한다.

Keycloak issuer는 `https://sso.imcherry5778.xyz`로 고정한다. k3s 웹 서비스의 내부 레코드는 Traefik 진입 주소를 가리키고, 공개 서비스는 공인 DNS와 Unbound override를 함께 검증한다.

## 인증서 이름과 공개 DNS 경계

공인 인증서는 서비스 계층별로 발급한다. OPNsense, Proxmox와 k3s는 인증서 private key와 DNS API token을 공유하지 않는다.

- Proxmox 인증서 식별자는 위 표의 canonical host 하나다. 별도 service alias나 wildcard 이름을 추가하지 않는다.
- Proxmox 관리 endpoint는 내부 주소의 HTTPS 8006을 유지한다. 공인 인증서 발급은 public A/AAAA, Cloudflare proxy, NAT 또는 443 공개를 뜻하지 않는다.
- DNS-01은 공개 zone에 임시 `_acme-challenge` TXT만 만들며 발급 후 제거한다. 내부 Unbound host override는 그대로 유지한다.
- 공인 CA의 Certificate Transparency log에는 canonical hostname이 공개될 수 있지만 내부 주소는 인증서에 넣지 않는다.

인증서 소유권과 사설 CA 대안은 [ADR-0009](adr/0009-proxmox-native-acme-management-tls.md)을 따른다.
