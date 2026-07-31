# 실행 백로그

기준일: 2026-07-31. 이 문서는 현재 상태와 작업 의존성만 소유한다. 목표 구조는 `architecture.md`, 주소는 `ip-plan.md`를 따른다.

## 현재 상태

| 계층 | 상태 | 근거 |
|---|---|---|
| OPNsense | `DONE` | 공인 WAN, 2FA, LAN/HOME 재배치, ACME·드리프트 도구와 VLAN gateway 영속성 검증 완료 |
| Proxmox | `DONE` | PVE 9.2.0 / pve-manager 9.2.2 설치 기준선 및 `PVE-ACME-01` 관리 TLS 검증 완료 |
| 자원 예산 | `DONE` | VM 0개 상태의 실측 기준표·과할당 한계·정지 기준; 값은 `capacity-plan.md` |
| VM 선언 (OpenTofu) | `DONE` | provider·state 경계와 5개 VM 공통 모듈; 생성 gate 충족 |
| VLAN trunk | `DONE` | OPNsense–Proxmox VLAN 10·20·30·40·50 tagged-only 경로와 OPNsense 재부팅 영속성 검증 완료 |
| VM 생성 | `DONE` | 서비스 VM 5대 생성·게스트 검증·재부팅·무변경 재계획 완료 |
| k3s·플랫폼 서비스 | `READY` | `VM-01` 완료로 VM 껍데기 확보; 작업별 병렬 진행 |

2026-07-31 `NET-02R`에서 OPNsense의 논리 `lan`을 `vlan01`로 영속 재할당하고 VLAN 20~50 논리 인터페이스와 gateway를 저장했다. 재부팅 후에도 부모 `igc2`는 무주소이고 VLAN 10~50 주소·직접 연결 route가 유지됐다. Proxmox 격리 namespace에서 untagged VLAN 10은 ARP 응답이 없고 tagged VLAN 10~50은 모두 gateway ARP 응답이 있었으며, 임시 자원은 제거했다. OPNsense·Proxmox SSH와 strict TLS, 내부 DNS, PF·Dnsmasq, OPNsense drift 없음과 Proxmox 저장 설정 불변도 확인했다.

2026-07-31 `NET-03`에서 VLAN 20~50에 gateway DNS·NTP와 공개 Web 용도의 RFC1918 외 TCP 80/443만 허용하고 RFC1918을 먼저 차단·기록하는 임시 IPv4 bootstrap 경계를 적용했다. 각 실제 VLAN source의 `vlan-verify bootstrap`은 적용 직후와 OPNsense 재부팅 후 모두 통과했다. 모든 BLOCK에는 같은 서비스의 최신 MGMT ALLOW control이 있었고, MGMT에서 각 project client로 시작한 TCP payload와 stateful 응답도 확인했다. 저장 rule 16개와 PF 확장 rule 24개, automatic NAT, 기존 LAN/HOME rule, 관리 SSH·strict TLS·DNS·NTP, Proxmox 영속 설정 불변, 임시 자원 제거와 OPNsense drift 없음까지 확인했다. 따라서 `NET-03`은 완료했고 직접 후속인 `VM-01`과 `AWS-NET-01`만 `READY`로 연다.

2026-07-31 `VM-01`에서 template 9000 full clone으로 서비스 VM 5대를 한 번의 apply로 만들었다. state 5개와 Proxmox config, 게스트 런타임 세 계층이 일치했고 `tofu plan`은 무변경이다. 각 게스트는 자기 VLAN gateway를 default route·DNS·NTP source로 쓰며, 실제 VM source의 `vlan-verify bootstrap`이 적용 후와 순차 재부팅 후 각각 5대 × 18 probe 전부 PASS했다. 모든 BLOCK은 VLAN 10 임시 client에서 만든 최신 MGMT ALLOW control과 대조했다. 공통 baseline은 1차 적용 후 2차·재부팅 후 3차 모두 `changed=0`이었다. Proxmox 영속 네트워크와 template config는 불변이고 임시 자원은 제거했으며 capacity 지표는 어떤 경고 구간에도 들어가지 않았다. 따라서 `VM-01`을 완료하고 직접 후속인 `NIDS-01`·`K3S-01`·`PG-01`·`MINIO-01`·`NB-01`·`WG-01`만 `READY`로 연다. `NETBOX-01`은 선행이 충족돼도 조건부 lane이므로 `DEFERRED`를 유지한다.

이 과정에서 두 가지를 보정했다. 첫째, API token role은 `PVE/API2/Qemu.pm`의 설정 권한만으로 부족했다. clone이 원본 template의 `net0`으로 bridge 접근을 검사하므로 `/sdn/zones/localnetwork/vmbr0`와 사용할 VLAN tag 경로에 `SDN.Use`가 필요했다. 둘째, 공통 baseline이 배포판 기본 공개 NTP pool을 그대로 두어 `NET-03` 아래에서 게스트가 동기화되지 못했다. gateway NTP 응답과 공개 NTP timeout을 각각 측정해 확인한 뒤, 공개 포트를 열지 않고 게스트 chrony source만 해당 VLAN gateway로 바꿨다. 절차와 함정은 [VM-01 runbook](runbook/proxmox-opentofu-vm-creation.md)이 소유한다.

## 멀티 에이전트 규칙

상태는 `READY`, `BLOCKED`, `DEFERRED`, `DONE`만 쓴다.

1. 한 세션은 작업 ID 하나와 그 소유 범위만 변경한다.
2. 선행 ID가 모두 `DONE`이어야 `READY`다.
3. 같은 잠금이 있는 작업은 동시에 실행하지 않는다.
4. 작업자는 완료 증거를 확보하면 같은 세션에서 맡은 ID를 `DONE`으로 갱신하고, 모든 선행이 충족된 직접 후속 ID만 `READY`로 연다.
5. 완료 보고에는 변경 파일, 라이브 검증, 실패 시 복구 지점, 후속 영향 ID를 포함한다.
6. 계획만 만든 것은 완료가 아니다. `DONE`은 표의 완료 증거가 확보된 상태다.

### 공유 잠금

| 잠금 | 보호 대상 |
|---|---|
| `PVE-LIVE` | Proxmox 설치·네트워크·스토리지 |
| `OPNSENSE-LIVE` | OPNsense API/UI·방화벽·DNS |
| `TOFU-STATE` | 동일 OpenTofu state의 plan/apply |
| `K3S-BOOTSTRAP` | k3s·Argo CD 초기 제어면 |
| `VAULT-INIT` | Vault initialize·unseal·seal migration |
| `PUBLIC-DNS` | Cloudflare DNS·공개 origin 변경 |
| `K3S-HEAVY` | Wazuh·관측·SOAR처럼 큰 워크로드의 최초 적용 |

## 주 경로

```text
PVE-01 → DNS-01 · CAP-01 · OS-01 · AUTO-01 · REC-01
DNS-01 + CAP-01 → IAC-01
PVE-01 + DNS-01 + AUTO-01 + IAC-01 → PVE-ACME-01
PVE-01 + REC-01 + NET-01 → NET-02 → NET-02R → NET-03
CAP-01 + OS-01 + IAC-01 + PVE-ACME-01 + NET-03 → VM-01
VM-01 → NIDS-01 · K3S-01 · PG-01 · S3-DESIGN-01 · NB-01 · WG-01
VM-01 + S3-DESIGN-01 → S3-01

기반 병렬 작업 → 백업 복구 gate → 공급망·정책 → 공개·최소권한
→ Loki → kube-prometheus-stack → Wazuh → Shuffle
```

## 1. 베어메탈과 재현성

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `PVE-01 DONE` | Proxmox 수동 설치·선택값 runbook (`docs/runbook/proxmox-manual-install.md`)·재부팅 검증 | 없음 | `PVE-LIVE` | `PVE-ACME-01`, 이후 전체 | 목표 NVMe, 설치 버전·filesystem·storage 선택, `ip-plan` 기반 network 적용 증거, 관리 UI·SSH와 재부팅 후 정상 |
| `DNS-01 DONE` | Unbound에 물리·VM canonical host record 등록 | `PVE-01` | `OPNSENSE-LIVE` | `IAC-01`, `PVE-ACME-01`, 모든 VM | 정·역방향 이름 해석, 미배포 service alias 없음, drift 없음 |
| `OPN-DRIFT-01 DONE` | OPNsense drift 조회의 env 입력과 TLS 검증·비상 fallback 강화 (`infra/opnsense/`) | `DNS-01` | `OPNSENSE-LIVE` | `REC-01`, `NET-02`, `NET-02R`, `NET-03` | 실제 값을 실행하지 않는 env parser 회귀 테스트, canonical hostname strict TLS와 DNS 우회 검증, insecure 경고·`--update` 차단, 라이브 drift 없음, Git·로그의 자격증명 부재 |
| `CAP-01 DONE` | CPU·RAM·thin storage·호스트 여유 예산 확정 (`docs/capacity-plan.md`) | `PVE-01` | `PVE-LIVE` | `VM-01`, PVC 용량 | VM 0개 상태의 `pvesm`·`lvs`·`vgs`·`free`·`lscpu` 실측 기준표, RAM 과할당 금지·thin 프로비저닝 상한·지표별 정지 기준 기록 |
| `AUTO-01 DONE` | 공식 `answer.toml` 템플릿과 자동설치 ISO PoC (`infra/proxmox/installer/`) | `PVE-01` | 없음 | `PVE-ACME-01`, 재설치 | 원본 ISO checksum, 템플릿·생성·검증 절차, Git의 비밀·생성 ISO 부재, 별도 VM/가상 디스크 무인 설치; 실물 디스크 미사용 |
| `PVE-ACME-01 DONE` | Proxmox 네이티브 ACME DNS-01 관리 인증서·설치 후 재현 절차 (`infra/proxmox/acme/`) | `PVE-01`, `DNS-01`, `AUTO-01`, `IAC-01` | `PVE-LIVE`, `PUBLIC-DNS`, `TOFU-STATE` | `VM-01` | 라이브 버전의 plugin schema 확인, staging DNS-01과 기본 인증서 복귀 후 production 발급, canonical 단일 FQDN의 SAN·chain·만료·8006 strict TLS, `pveproxy`·API·console 정상, 자동 갱신 timer와 challenge TXT 정리, `proxmox_insecure=false` plan 무변경, Git·로그·명령 인자의 토큰 부재 |
| `OS-01 DONE` | Rocky Linux 9 Minimal cloud-init template·Ansible 공통 baseline | `PVE-01` | `PVE-LIVE` | 모든 VM | VMID 9000 template 생성, clone 후 SSH key, 시간, 저장소, qemu-agent, 재부팅, Ansible 멱등성 검증 |
| `IAC-01 DONE` | OpenTofu provider·state·VM 공통 모듈 (`infra/proxmox/tofu/`) | `PVE-01`, `DNS-01`, `CAP-01` | `TOFU-STATE` | `PVE-ACME-01`, `VM-01` | secret 없는 init/validate/plan, state 보관 방식과 import 경계 검증 |
| `NET-01 DONE` | `vlan-verify`의 bootstrap/hardened profile과 테스트 | 없음 | 없음 | `NET-02`, `NET-02R`, `NET-04` | 현재망 회귀 테스트, 기대 허용·차단을 exit code로 판정 |
| `REC-01 DONE` | OOB 콘솔 복구 경로 검증·lockout 복구 drill (`docs/runbook/opnsense-oob-console-recovery.md`) | `PVE-01` | `OPNSENSE-LIVE` | `NET-02`, `NET-02R` | 주 LAN 주소 상실 상태에서 관리 경로 도달 실패와 OOB 콘솔 생존을 같은 시점에 관측, 콘솔로 복구 후 원상복귀, drift 없음, runbook 검증 |
| `REC-02 DEFERRED` | `igc0` 물리 RECOVERY 포트 추가 | `REC-01` | `OPNSENSE-LIVE` | 없음 | 현장에서 케이블 연결 후 주 LAN 없이 GUI 접근과 원상복귀 |

`PVE-01`은 디스크를 지우는 작업이다. 자동설치 PoC는 수동 설치에서 확인한 값을 사용하되 현재 물리 노드에 재실행하지 않는다. `PVE-ACME-01`은 443 전환이나 공개 경로 추가가 아니라 설치 후 8006의 서버 신뢰를 닫는 작업이다. `REC-01`은 OOB 콘솔이 랩 네트워크와 독립으로 동작함을 확인했다. OOB는 HOME 뒤에 있어 WAN·HOME이 손상되면 함께 끊기므로, 그 경우를 위한 `igc0` 물리 포트는 현장 접근이 가능할 때 `REC-02`로 검토한다. 부트스트랩과 자동화 경계는 [ADR-0001](adr/0001-proxmox-bootstrap-reproducibility.md), Proxmox 인증서 소유권은 [ADR-0009](adr/0009-proxmox-native-acme-management-tls.md), OpenTofu provider·state 경계는 [ADR-0008](adr/0008-opentofu-provider-and-state-boundary.md)을 따른다.

## 2. VLAN과 VM 기반

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `NET-02 DONE` | 최초 OPNsense–Proxmox tagged-only trunk 전환 이력 (`docs/runbook/opnsense-proxmox-tagged-trunk.md`) | `PVE-01`, `REC-01`, `NET-01` | `PVE-LIVE`, `OPNSENSE-LIVE` | `NET-02R` | 당시 런타임 전환은 확인됐지만 OPNsense 영속 완료 증거는 재점검에서 철회했고 `NET-02R`에서 보정·재검증함 |
| `NET-02R DONE` | OPNsense VLAN 논리 할당·gateway 영속성 보정과 tagged-only trunk 재검증 (`docs/runbook/opnsense-proxmox-tagged-trunk.md`) | `NET-02`, `REC-01`, `NET-01` | `PVE-LIVE`, `OPNSENSE-LIVE` | `NET-03`, 모든 VM 주소·경로 | 저장 설정에서 LAN=`vlan01`, VLAN 20~50 논리 할당·gateway, 부모 `igc2` 무주소; 런타임 직접 route·관리 SSH/TLS/DNS·tagged 성공·untagged 차단; OPNsense 재부팅 후 동일; drift 없음 |
| `NET-03 DONE` | VLAN 기본 deny와 bootstrap 허용 정책 ([runbook](runbook/opnsense-vlan-bootstrap-firewall.md)) | `NET-02R` | `OPNSENSE-LIVE` | 모든 서비스 통신 | 저장 rule 16개와 PF 확장 24개 일치; 실제 VLAN 20~50에서 DNS·NTP·공개 Web 허용과 관리망·HOME·project 간 차단, 최신 ALLOW control, MGMT stateful 응답; 재부팅 후 재검증, 임시 자원 제거, drift 없음 |
| `VM-01 DONE` | 5개 VM을 한 OpenTofu apply로 생성 | `CAP-01`, `OS-01`, `IAC-01`, `PVE-ACME-01`, `NET-03` | `TOFU-STATE`, `PVE-LIVE` | 3단계 전체 | strict TLS로 계획된 VLAN·disk·cloud-init, qemu-agent, gateway 통신, 재계획 무변경 |
| `NIDS-01 DONE` | OPNsense Suricata PCAP alert-only IDS 기준선 | `VM-01` | `OPNSENSE-LIVE` | `EDGE-01`, `AUDIT-01`, `WAZUH-01` | DMZ(`vlan04`) alert-only 적용, 부모/WAN 제외, IPS 비활성, HOME_NET 프로젝트 VLAN 전용, 대표 경보 탐지 확인, CPU/손실 기준 통과, OPNsense 재부팅 후 유지 및 drift 없음 |

동일 state에서 VM별 apply를 병렬 실행하지 않는다. `VM-01`이 VM 껍데기를 한 번에 만든 뒤 아래 OS 서비스 작업을 병렬화한다.

2026-07-31 `NIDS-01`에서 OPNsense Suricata 8.0.6 PCAP alert-only IDS를 DMZ(`vlan04`) 논리 프로젝트 VLAN에 적용했다. 부모 `igc2` 및 WAN `igc1`은 대상에서 제외하고 IPS/Drop/LogPayload를 비활성화했으며 HOME_NET은 프로젝트 VLAN 10~50만 포함하도록 구성했다. DMZ 내 `netbird-01`과의 통신 및 대표 경보(SSH/TCP 관측 및 alert 룰)가 `eve.json`에 긍정 증명되었고, CPU(~0.5%) 및 메모리(RES ~95MB), 패킷 loss 0%로 완벽한 기준을 충족했다. OPNsense 재부팅 후에도 `suricata_interface="vlan04"` 및 서비스 자동 기동이 유지되었으며, `vlan-verify` 유닛 테스트 통과 및 `check-drift.sh`에서 "드리프트 없음"을 확인했다. 선행 작업이 남아 있는 `EDGE-01`·`AUDIT-01`·`WAZUH-01` 및 `NIPS-01`은 여전히 대기 중이므로 이 시점에 새로 열 직접 후속 작업은 없다. PLATFORM (`vlan02`)은 `K3S-01` 완료 후 확대를 검토한다.

`NET-02R`은 정상인 Proxmox VLAN-aware bridge와 `vmbr0.10`을 바꾸지 않고 대조군으로 검증했다. OPNsense 설치본의 Assignment API와 config library로 저장된 논리 할당·주소를 보정했으며, `NET-03`의 기본 deny·bootstrap 허용 규칙은 섞지 않았다. 기존 runbook은 영속 증거가 없던 최초 절차를 구분하고 `NET-02R`에서 검증한 적용·재부팅·복구 판정으로 다시 승격했다. `NET-03`은 이 기반 위에 임시 IPv4 bootstrap 경계만 추가했으며, 실제 서비스 통신표로 최소화하는 작업은 후속 `NET-04` 범위다.

`IAC-01`이 만든 구성은 `OS-01`의 실제 template VMID와 VLAN 준비 여부가 모두 확정되기 전까지 리소스를 0개 계획한다. 현재 자체 서명 인증서를 반영한 `proxmox_insecure=true`는 `PVE-ACME-01`의 라이브 검증 전까지 유지한다. `VM-01`은 인증서 검증 우회를 먼저 제거하고 두 생성 gate를 라이브에서 확인하며, 세부 항목은 [`infra/proxmox/tofu/README.md`](../infra/proxmox/tofu/README.md)가 소유한다.

## 3. 병렬 기반 서비스

다음 기반 서비스 작업은 `VM-01` 이후 서로 독립적으로 진행한다. 단일 k3s·스토리지 선택은 [ADR-0002](adr/0002-single-node-k3s-and-local-storage.md), VM 분리 기준은 [ADR-0003](adr/0003-service-vm-boundaries.md), 로컬 S3 구현은 [ADR-0010](adr/0010-seaweedfs-local-s3.md)을 따른다.

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `K3S-01 DONE` | 단일 노드 k3s·SQLite 기준선 (`infra/ansible`, k3s bootstrap) | `VM-01` | `K3S-BOOTSTRAP` | 모든 k3s 앱 | `v1.36.2+k3s1`, 재부팅 후 Node Ready, CoreDNS·Traefik·ServiceLB, SQLite 위치·무결성, PVC 데이터 유지, Ansible·NET-03 재검증 |
| `PG-01 DONE` | PostgreSQL VM·서비스별 DB/role·TLS | `VM-01` | 없음 | Keycloak·플랫폼 앱 | PostgreSQL 16.14(Rocky AppStream GPG 서명), verify-full TLS(canonical FQDN/pg_stat_ssl), sslmode=disable 차단 & pg_hba_file_rules 오류 0, 최소 service role(keycloak_user/verify_user) DB/schema 권한 격리, 타 VLAN probe 차단, 재부팅 후 데이터·TLS·role 유지, pg_dump/pg_restore 복구, chrony/QGA/capacity 정상, Ansible 멱등(changed=0) |
| `S3-DESIGN-01 DONE` | 미배포 MinIO 계획을 SeaweedFS 로컬 S3로 전환하고 제품 중립 이름·state 마이그레이션·호환성 gate 결정 | `VM-01` | 없음 | `S3-01`, 모든 백업 | 새 ADR과 목표 아키텍처·주소 전환 경계, 기존 VMID·주소·디스크 불변, destroy/create 금지와 rollback, 클라이언트별 S3 복원 gate 문서화, state·라이브 VM identity 읽기 전용 대조와 변경 명령 0 |
| `S3-01 DONE` | 기존 VM을 `object-01`로 제자리 이름 전환하고 SeaweedFS master·volume·filer·S3를 선언형 배포 | `VM-01`, `S3-DESIGN-01` | `TOFU-STATE`, `PVE-LIVE`, `OPNSENSE-LIVE` | 모든 백업 | state 복구 사본·`moved` 선언과 destroy/create 0 plan, VMID·주소·디스크 보존, canonical DNS·hostname 일치, 고정 version·digest·license, TLS S3, 최소권한 계정·bucket policy, versioning·multipart·presigned URL·checksum, 재부팅 후 object 유지, Ansible check/diff·2회차 changed=0, 임시 자원·자격증명 제거 |
| `MINIO-01 DEFERRED` | 배포 시작 전 upstream 유지 중단으로 폐기한 MinIO 구현 계획; `S3-01`이 대체 | `VM-01` | 없음 | 없음 | 재실행하지 않음; [ADR-0010](adr/0010-seaweedfs-local-s3.md)의 재검토 조건이 생기면 새 결정으로만 검토 |
| `NB-01 DONE` | NetBird 기본 self-host와 로컬 Owner 복구 계정 | `VM-01` | `PUBLIC-DNS · OPNSENSE-LIVE` | 원격 진입 | 외부 peer 연결, relay 경로, 로컬 Owner 로그인과 백업 가능 |
| `WG-01 DONE` | Warpgate 기본 배포와 로컬 복구 계정 | `VM-01` | 없음 | 특권 접근 | Warpgate v0.26.1 고정·checksum·SBOM, 비-root + systemd hardening + SELinux label, 세션 중계와 기록 생성·제품 조회, 대상별 역할 허용/거부, 로컬 복구 로그인 성공·실패, 재부팅 후 유지, 격리 인스턴스 복원, Ansible 멱등(changed=0) |
| `AWS-NET-01 READY` | OPNsense↔AWS Site-to-Site VPN | `NET-03` | `OPNSENSE-LIVE` | AWS 사설 연동 | 양방향 대상 대역만 통신, 인터넷 기본 경로 불변, 장애 시 롤백 |

2026-07-31 `K3S-01`에서 k3s `v1.36.2+k3s1`을 정확한 binary checksum과
고정 release commit의 install script로 선언하고 SELinux Enforcing을 유지했다.
재부팅 뒤 단일 Node `Ready`, SQLite `quick_check=ok`, CoreDNS 실제 해석,
Traefik·ServiceLB 실제 HTTP, local-path PVC Bound·데이터 유지와 metrics-server를
확인했다. 공통 baseline과 k3s role은 모두 `changed=0`이고, 설치 후와 재부팅 후
MGMT·k3s `vlan-verify`가 각각 18/18 PASS했으며 임시 네트워크·Kubernetes 자원을
제거했다. 기본 local-path 삭제 helper의 SELinux 환경 timeout은 정확한 test 경로를
수동 정리하고 `STOR-01` 재검토 항목으로 남겼다. 직접 후속 중 선행이 충족된
`GITOPS-01`과 `STOR-01`만 `READY`로 연다.

2026-07-31 `PG-01`에서 Rocky 9 공식 AppStream 모듈 `postgresql:16` (16.14, GPG Key ID 702d426d350d275d 서명)으로 PostgreSQL 16 기준선을 Ansible로 선언하고 postgres-01(10.10.50.10)에 적용했다.
canonical FQDN `postgres-01.imcherry5778.xyz` 대상 host-specific TLS bootstrap leaf를 생성하고 client `sslmode=verify-full` 연결과 `pg_stat_ssl` TLS 1.3 사용을 라이브 증명했다. `sslmode=disable` 원격 연결 차단과 `pg_hba_file_rules` 오류 0개를 확인했다.
최소 권한 service role(`keycloak_user`, `verify_user`)과 전용 DB(`keycloak`, `verify_db`)를 선언하여 자신의 DB에만 접속 및 DDL/DML을 허용하고, 타 DB/role 생성/superuser 기능 및 public schema 접근 거부를 양성·음성 시험으로 증명했다.
DATA 밖 외부 VLAN 차단은 strict host key를 적용한 `netbird-01`(VLAN 40) 및 `warpgate-01`(VLAN 30)에서 읽기 전용 TCP probe(5432)로 검증했다.
`postgres-01` 단독 재부팅 후 marker 데이터, TLS 및 role 권한 유지를 확인했고, `pg_dump`/`pg_restore`로 별도 폐기 가능한 `recovery_db` 복구 및 marker 검증 후 정리했다.
chrony 시간 동기화(Stratum 4), systemd failed unit 0개, QGA 응답 정상과 98GiB(사용률 2%) 여유를 확인했으며, Ansible syntax-check, check/diff 및 2회차 실행 멱등성(`changed=0, failed=0`)을 모두 입증했다.
직접 후속 작업(`VAULT-02`, `KC-01`, `BKP-03` 등)의 선행조건을 재계산한 결과, `VAULT-01`, `INGRESS-01`, `MINIO-01` 등 미완료 선행이 남아 있어 새로 `READY`로 여는 직후 작업은 없다.

2026-07-31 `NB-01`에서 Rocky Linux 9.8 `netbird-01`(10.10.40.10, VMID 140)에 NetBird self-hosted control/relay를 Ansible로 선언하고 라이브 검증했다. netbird-server v0.73.0(통합 Management·Signal·Relay·Dex IdP), dashboard v2.90.8, Traefik v3.7.9을 Docker Compose + systemd unit(`netbird-compose.service`)으로 배포했다. TLS는 OPNsense ACME 와일드카드(`*.imcherry5778.xyz`, Let's Encrypt)를 Traefik file provider로 제공한다(ISP KT 환경 TCP 80 inbound 타임아웃으로 HTTP-01/DNS-01 Cloudflare zone 인식 실패를 OPNsense 우회로 해소). Cloudflare DNS A 레코드(`netbird.imcherry5778.xyz`, proxied:false)와 OPNsense NAT Port Forward(TCP 80/443, UDP 3478) 적용 후 `check-drift.sh --update` 완료했다. 라이브 검증: HTTPS HTTP/2 200 + Let's Encrypt 인증서, `/api/accounts` 401 거부, `/oauth2/.well-known/openid-configuration` 200, UDP 3478 STUN LISTEN, Dex 잘못된 자격증명 거부(`Invalid Email Address or password.`), 올바른 자격증명 HTTP 303 auth code redirect. VM 재부팅 후 `netbird-compose.service enabled + active`, 모든 컨테이너 자동 시작 확인. `/var/backups/netbird/` 백업(설정·DB 3개·TLS 인증서) 생성 및 tar 내용 검증 완료. Ansible 2회차 멱등성 `ok=33 changed=0 failed=0 skipped=1`. 용량: RAM 212.6 MiB(컨테이너 합계), 디스크 2.7/31 GiB(9%). 런북 `docs/runbook/netbird-selfhost.md` 작성 완료. `NB-02`의 선행(`NB-01`)이 충족되었으나 `KC-01` 미완료로 `NB-02`는 BLOCKED 유지.

2026-07-31 `STOR-01`에서 k3s packaged local-storage와 동일한 provisioner를 Ansible
소유 AddOn으로 선언하고 StorageClass의 `defaultVolumeType: local`을 유지했다. 새 PV는
`.spec.local`만 사용했고, 16Mi 요청에 32MiB bounded write가 성공해 capacity가 하드
quota가 아님을 확인했다. 재부팅 뒤 marker 내용·SHA-256이 같았으며 helper 전용
SELinux policy로 최종 PVC 삭제가 4초 안에 끝나 PV·helper·시험 경로가 자동 제거됐다.
검증 자원은 0이고 Node·기본 구성요소·DiskPressure·failed unit·멱등성 기준도 모두
통과했다. 직접 후속 `VAULT-01`은 `GITOPS-01`, `BKP-02`는 `GITOPS-01`과 `MINIO-01`이
남아 있으므로 새로 `READY`로 열지 않는다.

2026-07-31 `WG-01`에서 Warpgate를 `warpgate-01`에 Ansible로 선언 배포했다. 작업 시점의 최신
안정 릴리스 `v0.26.1`을 고정하고 GitHub Release asset digest의 SHA-256을 강제했으며 같은
릴리스의 CycloneDX SBOM도 검증해 보관했다. 참고값 `v0.23.4`는 `CVE-2026-63330`(세션 기록
WebSocket 도청, `< 0.25.6`)을 포함한 자문의 영향 범위 안이라 채택하지 않았다.
전용 비-root 서비스 계정, `ProtectSystem=strict`와 빈 `CapabilityBoundingSet`을 포함한 systemd
hardening, `bin_t`/`var_lib_t` 올바른 SELinux label과 `0600`/`0700` 최소 권한으로 적용했고
SELinux Enforcing을 유지했다. 라이브 검증에서 허용 role을 가진 사용자는 지정 대상에 접속해
고유 marker 명령을 실행했고, 같은 대상에 미할당 사용자와 잘못된 자격증명은 거부됐다. 감사
로그는 `UserAuthenticated1`·`UserAuthenticationFailed1`·`TargetSessionStarted1`/`Ended1`과
`Target ... not authorized`를 구분해 남겼고, 세션 기록 파일이 최소 권한·올바른 context로
생성돼 제품 API에서 조회됐다. `warpgate-01`만 재부팅해 boot ID 변경, failed unit 0, AVC 0,
자동 시작, 기록 SHA-256 불변, 로컬 복구 로그인·역할 제한·기존 감사 유지를 재확인했다.
SQLite 온라인 backup으로 일관 백업을 만들어 별도 data directory와 별도 port의 격리
인스턴스에서 로컬 관리자와 기록 metadata 복원을 확인한 뒤 복원 인스턴스·임시 백업·임시
계정·임시 Warpgate 객체를 모두 제거했다. Ansible은 syntax-check, check/diff, 적용, 2차 적용
`changed=0`, 재부팅 후 check와 적용 `changed=0`을 모두 통과했다.
**이 검증은 같은 VM의 loopback 대상에 한정되며 실제 운영 대상의 cross-VLAN 접근 증거가
아니다.** OPNsense·방화벽·공개 DNS는 변경하지 않았고 `MINIO-01`이 없으므로 원격 백업도
아니다. 직접 후속 `WG-02`는 `KC-01`이 남아 있어 `READY`로 열지 않는다.

2026-07-31 `S3-DESIGN-01`에서 아직 배포하지 않은 MinIO 계획을 SeaweedFS 로컬 S3로
전환했다. 기존 `minio-01` VMID·주소·200 GiB 디스크와 전용 DATA VM 경계는 유지하고,
목표 canonical 이름을 `object-01`, service alias를 `s3`로 정했다. 이번 작업은 문서만
바꿨으며 라이브 VM·DNS·OpenTofu 구성과 state는 변경하지 않았다. 실제 전환은
`S3-01`이 세 공유 잠금을 단독 소유하고 state 복구 사본과 `moved` 선언을 사용하며,
destroy/create가 보이면 적용을 중단한다. MinIO 관련 과거 완료 증거는 당시 사실로
보존하고 현재 의존성만 `S3-01`로 옮겼다. `VM-01`과 `S3-DESIGN-01`이 모두 완료됐으므로
직접 후속 `S3-01`만 `READY`로 연다.

읽기 전용 대조에서 mode `0600` OpenTofu state의 5개 리소스 중 기존 모듈 주소가
`module.service_vm["minio-01"]`이고 VMID 151·200 GiB·VLAN 50임을 확인했다. Proxmox
라이브에서도 VM 151은 실행 중이며 같은 이름·디스크·VLAN이고, 허용된 QGA hostname
조회도 `minio-01.imcherry5778.xyz`였다. 현재 canonical DNS만 해석되고 목표
`object-01`·`s3`는 아직 해석되지 않음을 확인했다. QGA 임의 명령 실행은 정책상
비활성이고 게스트 SSH host key는 인증된 저장소에 없어 새로 신뢰하지 않았으므로,
게스트 내부 제품 설치 여부는 이번 라이브 증거에 포함하지 않는다. 미배포 판정은
백로그와 Git 선언에 한정한다.

2026-07-31 `S3-01`에서 VMID 151의 기존 `minio-01`을 `object-01`로 제자리
전환했다. OpenTofu `moved`로 state 주소를 `module.service_vm["object-01"]`로 옮겼고,
변경 plan은 0 add·1 change·0 destroy, 최신 refresh plan은 5개 VM 모두 no-op였다.
VMID 151·MAC·VLAN 50·주소 `10.10.50.20`·200 GiB boot disk는 불변이다. Rocky 9/amd64에
SeaweedFS 4.40을 release SHA-256과 Apache-2.0 license SHA-256 검증으로 선언하고,
master·volume·filer·TLS S3 gateway를 비-root systemd unit과 SELinux Enforcing으로
배포했다. Unbound는 이전 minio canonical record를 제거하고 object A/PTR 및 `s3` alias를
등록했으며, OPNsense는 k3s-01에서 TCP 8333만 허용한다. 실제 최소권한 S3 identity로
bucket·PUT/GET/LIST/DELETE·versioning·두 version 조회·multipart·HTTPS presigned URL·SHA-256을
검증했고 다른 bucket·잘못된 credential·관리 endpoint는 거부됐다. 시험 자원은 모든
version, multipart, identity, credential, client 파일까지 API로 정리했다. object-01만 두
번 재부팅해 marker/version·TLS·네 unit 자동 시작을 확인했고 최종 Ansible check/diff 및
실제 적용은 모두 `changed=0, failed=0`이었다. 단일 VM·단일 disk라 HA나 물리 장애 복구
증거는 아니며 AWS S3 오프사이트 사본은 `BKP-04` 범위다. 상세 증거와 rollback은
[SeaweedFS S3 runbook](runbook/seaweedfs-s3.md)이 소유한다. 최신 선행조건을 다시 계산해
`BKP-01`, `BKP-02`, `BKP-04`만 `READY`로 열었고 `VAULT-02`가 남은 `BKP-03`은 `BLOCKED`를
유지한다.

## 4. k3s 제어면·인증

통합인증·관리 접근은 [ADR-0004](adr/0004-zero-trust-identity-and-management-access.md), Vault bootstrap과 seal 경계는 [ADR-0006](adr/0006-vault-seal-and-bootstrap-boundary.md)을 따른다.

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `GITOPS-01 DONE` | `gitops/` 생성·Argo CD bootstrap·root Application | `K3S-01` | `K3S-BOOTSTRAP` | 이후 k3s 앱 | 새 clone에서 bootstrap, Synced/Healthy, secret 원문 없음 |
| `HEADLAMP-01 READY` | Headlamp 기본 GitOps 배포·내부 bootstrap 접근 | `GITOPS-01` | 없음 | 초기 k3s 조회·`HEADLAMP-02` | Argo Synced/Healthy, 외부 ingress 없음, Headlamp SA 무권한, port-forward와 단기 reader token으로 리소스·로그 조회 |
| `STOR-01 DONE` | local-path 경로·`local` PV 타입·disk-pressure 검증 | `K3S-01` | `K3S-BOOTSTRAP` | 모든 PVC·`BKP-02` | 동적 PVC, capacity 미강제, 재부팅 후 데이터, SELinux 삭제 helper, 임계치 기준 |
| `INGRESS-01 READY` | Traefik 단일 ingress·별도 DNS-01 인증서 | `GITOPS-01` | `PUBLIC-DNS` | 모든 HTTP 앱 | 80→443, 내부·외부 split DNS, OPNsense 개인키 미복사, source IP 판정 |
| `VAULT-01 DONE` | Vault Raft 단일 replica·수동 Shamir 초기화 | `GITOPS-01`, `STOR-01` | `VAULT-INIT` | 모든 시크릿 소비자 | TLS, unseal·재시작, share/root token Git 부재, 로컬 복구 절차 |
| `VAULT-02 READY` | KV v2·Kubernetes auth·DB engine·PKI·audit policy | `VAULT-01`, `PG-01` | 없음 | 모든 플랫폼 앱 | 앱별 policy 격리, 단기 DB credential 폐기, 인증서·감사 이벤트 검증 |
| `KC-01 BLOCKED` | Keycloak 배포·realm·그룹/client role·일상/특권 ID | `PG-01`, `VAULT-02`, `INGRESS-01` | 없음 | Pomerium·Headlamp·NetBird·Warpgate·AWS | MFA, claim, 최소 role, 로컬 admin 복구, issuer 고정 |
| `CORAZA-01 BLOCKED` | Traefik HTTP-WASM Coraza + CRS PoC | `INGRESS-01` | 없음 | 공개 HTTP | 정상 요청·대표 CRS 차단·예외 정책·성능 기준 검증 |
| `POM-01 BLOCKED` | Pomerium Core·선언형 Route·Routes Portal | `KC-01`, `INGRESS-01`, `VAULT-02` | 없음 | 내부 웹 접근 | groups claim 허용/차단, Portal 표시, Keycloak 장애 시 독립 복구 경로 |
| `HEADLAMP-02 BLOCKED` | Headlamp Keycloak OIDC·Kubernetes RBAC·Pomerium Route | `HEADLAMP-01`, `POM-01` | `K3S-BOOTSTRAP` | k3s 일상 관리·`CAP-02` | 공유 cluster-admin SA 없음, 사용자별 조회·로그·exec·변경 allow/deny, bootstrap token 폐기, GitOps drift 없음, IdP 장애 시 break-glass kubeconfig |
| `NB-02 BLOCKED` | NetBird 일반 인증을 Keycloak OIDC로 전환 | `NB-01`, `KC-01` | 없음 | 원격 사용자 | 신규 OIDC 로그인·그룹 정책과 로컬 Owner 복구 모두 성공 |
| `WG-02 BLOCKED` | Warpgate SSO·역할·세션 정책 연동 | `WG-01`, `KC-01` | 없음 | 관리자 접근 | 일반/특권 분리, 허용 대상만 접속, IdP 장애 복구 검증 |
| `AWS-ID-01 BLOCKED` | Keycloak `AssumeRoleWithSAML`·AWS role 매핑 | `KC-01` | 없음 | AWS 콘솔 권한 | 그룹별 임시 role, 세션 만료, 과권한·지속키 없음 |

2026-07-31 `GITOPS-01`에서 Kubernetes `v1.36.2+k3s1`에 Argo CD `v3.5.0-rc3`
pre-release를 fixed tag·commit·manifest SHA-256·image digest로 bootstrap했다. root
Application은 GitHub private repository의 signed commit
`50383d78fcbba357a724d03c6e6f450569296a69`을 SSH 443 read-only deploy key로 읽어
`Synced/Healthy`가 됐다. drift self-heal·Git 제거 prune·repo-server Pod 한 개 복구·
동일 bootstrap diff·저장소 밖 credential만 쓴 fresh clone 재현과 사후 기준선을 모두
확인했다. 정식 v3.5 GA 전환은 별도 update 검증으로만 수행한다. 직접 후속을 최신
선행조건으로 재계산해 `HEADLAMP-01`, `INGRESS-01`, `VAULT-01`을 `READY`로 열었다.
`BKP-02`는 `S3-01`이 아직 `DONE`이 아니므로 `BLOCKED`를 유지한다. 적용·fresh clone·
rollback 경계는 [GITOPS-01 runbook](runbook/argocd-gitops-bootstrap.md)이 소유한다.

2026-07-31 `VAULT-01`에서 `hashicorp/vault:2.0.3`(Docker Hub 공식 organization, digest
`sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54`, BUSL-1.1
라이선스)을 `vault` namespace에 원시 manifest(Kustomize)로 선언하고, `platform-root` 하위에
전용 AppProject·child Application `vault`를 추가했다. 단일 replica StatefulSet과 Raft
storage, local-path PVC(`vault-data`, 4Gi)를 사용한다. TLS는 Kubernetes Secret이 아니라
PVC 내부 파일(mode 0600 key)로만 제공하며, host-specific 자체서명 leaf로 정상 hostname
성공과 잘못된 hostname·신뢰되지 않은 인증서 실패를 모두 라이브로 확인했다. Shamir
5 shares/threshold 3으로 초기화하고 HTTP API 요청 본문으로만 unseal해 CLI·shell 인자
노출을 피했다. `vault-0` 단독 재시작 후 sealed 상태와 비인증 요청 거부, 동일 key로
재unseal, 재시작 전후 `cluster_id`·Raft 구성 불변을 확인했다. `kubectl get secret -n vault`
0건과 Pod 로그에 key/root token 미포함을 검사했고, 초기화 출력은 저장소·클러스터 밖
mode 0600 임시 파일에만 남겨 사용자가 직접 암호화 장기 보관소로 이관하도록 안내했다.
공식 이미지 entrypoint가 `-config` 인자를 암묵적으로 중복 추가해 발생하는
`CrashLoopBackOff` 함정을 라이브로 재현·수정했다. 절차와 rollback 경계는
[VAULT-01 runbook](runbook/vault-raft-baseline.md)이 소유한다. `PG-01`도 `DONE`이므로
직접 후속 `VAULT-02`만 `READY`로 열었다. `KC-01`과 `BKP-03`은 각각 `INGRESS-01`·`VAULT-02`
등 남은 선행이 있어 `BLOCKED`를 유지한다.

## 5. 데이터 보호 gate

이 단계가 끝나기 전에는 복구 불가능한 운영 데이터를 넣거나 공개 경로를 완료 처리하지 않는다. 백업 도구별 소유 범위와 오프사이트 기준은 [ADR-0005](adr/0005-backup-and-offsite-recovery.md)를 따른다.

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `BKP-01 READY` | K3s SQLite·server token 전용 backup/restore | `K3S-01`, `S3-01` | `K3S-BOOTSTRAP` | 클러스터 복구 | 격리된 빈 VM에서 API 객체 복원; Velero와 별도임을 검증 |
| `BKP-02 READY` | Velero + node-agent/Kopia와 local PV restore PoC | `GITOPS-01`, `STOR-01`, `S3-01` | 없음 | 모든 k3s PVC | 테스트 namespace 삭제 후 리소스·파일 복원, hostPath 제약 판정 |
| `BKP-03 BLOCKED` | PostgreSQL native backup·Vault Raft snapshot | `PG-01`, `VAULT-02`, `S3-01` | 없음 | 인증·플랫폼 데이터 | 별도 DB/namespace에 point-in-time 또는 snapshot restore |
| `BKP-04 READY` | SeaweedFS 로컬 S3에서 AWS S3로 오프사이트 사본 생성 | `S3-01` | 없음 | 모든 백업의 물리 장애 대응 | 별도 최소권한 자격증명과 검증한 방식으로 전송, AWS S3에서 샘플 복원, 암호화·버전·보존·실패 경보 검증 |
| `BKP-05 BLOCKED` | 통합 재해복구 drill·RPO/RTO 기록 | `BKP-01`, `BKP-02`, `BKP-03`, `BKP-04` | `K3S-BOOTSTRAP` | 공급망·공개 전환 gate | Git+S3만으로 핵심 서비스 복구, 누락·시간·수동 절차 기록 |
| `PVE-BKP-01 DEFERRED` | 두 번째 SSD에 Proxmox VM backup | 두 번째 SSD 장착 | `PVE-LIVE` | 빠른 VM 복구 | 원본 NVMe와 다른 장치에 backup·restore; S3 앱 백업은 유지 |

## 6. 공급망과 정책

`BKP-05` 이후 실제 데이터를 가진 서비스를 늘린다. 서로 다른 앱 디렉터리는 병렬 작업할 수 있다.

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `CAP-02 BLOCKED` | 핵심 서비스 후 남은 CPU·RAM·disk 재예산 | `BKP-05`, `HEADLAMP-02` | 없음 | 아래 전체 | Proxmox·VM·Pod 실측과 stop/go 기준 |
| `SCM-01 BLOCKED` | Gitea | `CAP-02`, `PG-01`, `VAULT-02`, `POM-01` | 없음 | CI·Renovate | push/restore, SSO·RBAC, webhook 최소권한 |
| `REG-01 BLOCKED` | Harbor | `CAP-02`, `PG-01`, `VAULT-02`, `POM-01` | 없음 | CI·Trivy·Cosign | push/pull, robot account, retention, restore |
| `CI-01 BLOCKED` | Jenkins agent 격리와 pipeline 기준선 | `SCM-01`, `REG-01`, `VAULT-02` | 없음 | 공급망 E2E | 비밀 마스킹, 비특권 agent, 이미지 build/push |
| `QUALITY-01 BLOCKED` | SonarQube | `CAP-02`, `PG-01`, `VAULT-02`, `POM-01` | 없음 | CI quality gate | 분석·quality gate·restore·SSO |
| `AWX-01 BLOCKED` | AWX | `CAP-02`, `PG-01`, `VAULT-02`, `POM-01` | 없음 | VM 구성 자동화 | inventory·credential 격리, check/apply 승인 경계 |
| `UPDATE-01 BLOCKED` | Renovate | `SCM-01`, `VAULT-02` | 없음 | 의존성 변경 | 제한된 repo 권한, PR 생성, 자동 merge 금지 기준 |
| `SCAN-01 BLOCKED` | Trivy image/config/SBOM 검사 | `CI-01`, `REG-01` | 없음 | 서명·배포 gate | 취약점 기준·SBOM 저장·실패 pipeline |
| `SIGN-01 BLOCKED` | Cosign 서명·검증 방식 확정과 구현 | `REG-01`, `SCAN-01`, `VAULT-02` | 없음 | Kyverno | 키 소유·회전·복구, 서명·검증·거부 테스트 |
| `POL-01 BLOCKED` | Kyverno Audit + namespace NetworkPolicy 기준선 | `GITOPS-01`, `POM-01` | 없음 | 모든 workload | 위반 report, DNS·ingress·필수 egress 회귀 없음 |
| `E2E-01 BLOCKED` | Gitea→Jenkins→Sonar→Harbor→Trivy→Cosign→Argo E2E | `CI-01`, `QUALITY-01`, `SIGN-01`, `POL-01` | 없음 | 정책 Enforce | 정상 artifact 배포와 변조·미서명 artifact 차단 |
| `POL-02 BLOCKED` | 검증된 Kyverno 정책만 Enforce | `E2E-01` | 없음 | 모든 배포 | 예외 만료, rollback, 정상 릴리스 회귀 없음 |
| `FALCO-01 BLOCKED` | Falco runtime rule·출력 기준선 | `E2E-01`, `POL-01` | 없음 | Wazuh·Shuffle | 전용 테스트 이벤트 탐지, noise 기준, 대응 runbook 초안 |

## 7. 최소권한과 공개 경로

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `NET-04 BLOCKED` | 실제 통신표로 VLAN 규칙 최소화·hardened 검증 | `NB-02`, `WG-02`, `POM-01`, `BKP-05`, `E2E-01` | `OPNSENSE-LIVE` | 외부 공개·운영 통신 | 임시 rule 제거, `vlan-verify hardened`, drift 없음 |
| `EDGE-01 BLOCKED` | Cloudflare WAF·origin 제한·공개 DNS/NAT | `CORAZA-01`, `POM-01`, `NB-02`, `NIDS-01`, `NET-04` | `PUBLIC-DNS`, `OPNSENSE-LIVE` | 외부 사용자 | 허용 hostname만 공개, origin 직접 우회 차단, IDS 경보·복구 경로 독립 |
| `NIPS-01 DEFERRED` | 검증된 Suricata rule만 선택적 IPS로 승격 | `NIDS-01`, `NET-04` | `OPNSENSE-LIVE` | 전체 프로젝트 통신 | 정상 트래픽·오탐·부모 인터페이스·offloading·처리량·장애·즉시 rollback 검증; 공개의 필수 gate 아님 |
| `KMS-01 DEFERRED` | Vault Shamir→AWS KMS auto-unseal migration | `BKP-05` | `VAULT-INIT` | Vault 부팅·복구 | 사전 snapshot, KMS 장애 시험, seal rollback drill; VPN은 선행 아님 |

## 8. 조건부 NetBox lane

NetBox는 주 경로를 막지 않는다. 아래 조건 중 하나가 생길 때만 실행한다.

- 두 번째 Proxmox, 관리형 스위치, NAS 등 물리 자산 추가
- 포트·케이블 추적 또는 API IP 할당 필요
- AWX·DNS·모니터링이 공통 인벤토리를 요구

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `NETBOX-01 DEFERRED` | 채택 필요성·운영비용 gate | `NET-03`, `VM-01` | 없음 | `NETBOX-02` | 현재 Git 방식과 비교한 명확한 채택/기각 결정 |
| `NETBOX-02 DEFERRED` | Community read-only PoC | `NETBOX-01=채택`, `PG-01`, `KC-01` | 없음 | AWX inventory·주소 원본 | VLAN·장비·VM 모델, backup/restore, read-only API 소비 |
| `NETBOX-03 DEFERRED` | 단일 진실 원천 마이그레이션 | `NETBOX-02=통과` | `OPNSENSE-LIVE`, `TOFU-STATE` | `ip-plan`, OpenTofu, AWX, DNS | dual-write 제거, 생성 export·rollback·ADR 검증 |

## 9. 최종 관측·보안 운영

플랫폼 구축 속도를 막지 않도록 다음 작업은 모든 핵심 서비스와 공개 경로가 안정된 뒤 시작한다. 큰 워크로드는 `K3S-HEAVY` 잠금으로 하나씩 배포하고 매번 자원 여유를 다시 측정한다. 탐지·관측의 역할과 순서는 [ADR-0007](adr/0007-detection-and-observability-staging.md)을 따른다.

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `AUDIT-01 BLOCKED` | Suricata·Coraza·Falco·Kubernetes·Vault·Keycloak·Pomerium·접근 서비스 이벤트 분류 | `EDGE-01`, `POL-02`, `FALCO-01` | 없음 | Loki·Wazuh | 보안/운영 경계, 시각·사용자·요청 ID, 마스킹, 보존 기준 |
| `LOKI-01 BLOCKED` | Alloy·Loki와 제한된 운영 로그 수집 | `AUDIT-01` | `K3S-HEAVY` | Grafana | 보안 이벤트의 Wazuh 중복 저장 없음, label cardinality·retention·disk 상한 |
| `OBS-01 BLOCKED` | kube-prometheus-stack·Alertmanager·Grafana | `LOKI-01` | `K3S-HEAVY` | 운영 경보·Wazuh·Shuffle | node/PVC/backup/cert·OPNsense·수집 파이프라인 지표, 실제 경보 전달, disk 상한 |
| `WAZUH-01 BLOCKED` | Wazuh 배치·보안 소스 직접 수집·규칙 PoC | `AUDIT-01`, `OBS-01`, `FALCO-01`, `NIDS-01` | `K3S-HEAVY` | Shuffle | Suricata 등 대표 이벤트의 직접 탐지·검색·retention, Loki relay 없음, active response 비활성, 오탐·용량 gate |

## 10. 마지막 단계: Shuffle

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `SOAR-01 BLOCKED` | Shuffle read-only·사람 승인형 SOAR PoC | `OBS-01`, `WAZUH-01`, `FALCO-01` | `K3S-HEAVY` | 사고대응 | 경보 수신→정보 보강→통지→승인 흐름, 최소권한 credential |
| `SOAR-02 DEFERRED` | 되돌릴 수 있는 대응 한 가지 자동화 | `SOAR-01`, 검증된 incident runbook | 없음 | 접근 정책 | 반복 시험, 승인·감사·rollback; 방화벽·계정 무인 파괴 금지 |

Shuffle은 Jenkins·Argo CD·AWX의 배포 자동화를 대체하지 않는다. 보안 사건에 반응하는 흐름만 소유한다.
