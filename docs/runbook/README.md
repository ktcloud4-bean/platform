# 운영 runbook

runbook은 실제 장비에서 검증한 사람 중심 절차만 둔다. 목표 구조는 `docs/architecture.md`, 정확한 주소는 `docs/ip-plan.md`, 반복 가능한 기계 동작은 컴포넌트의 `scripts/`가 소유한다.

## 문서 경계

| 위치 | 책임 |
|---|---|
| 컴포넌트 `README.md` | 구성 이유와 금지 사항 |
| 컴포넌트 `scripts/` | 반복 실행 가능한 명령 |
| `docs/runbook/` | 전제·영향·판정·중단·복구 |

## 필수 항목

1. 목적과 검증일
2. 전제조건과 접근 권한
3. 예상 영향과 공유 잠금
4. 실행 순서와 중단 조건
5. 성공 판정
6. 실패 시 원상복구
7. 시크릿과 보존하면 안 되는 출력

UI 위치나 명령을 추측해 미리 작성하지 않는다. 첫 PoC는 백로그 작업이며, 성공·실패와 복구를 실제로 확인한 뒤 runbook으로 승격한다.

## 현재 runbook

- [`opnsense-interface-reassignment.md`](opnsense-interface-reassignment.md) — 2026-07-28 검증된 물리 인터페이스 재할당 절차
- [`proxmox-manual-install.md`](proxmox-manual-install.md) — 2026-07-30 검증된 Proxmox VE 수동 설치 선택값과 판정
- [`rocky9-template-and-baseline.md`](rocky9-template-and-baseline.md) — 2026-07-30 검증된 Rocky Linux 9 Cloud-Init Template 및 Ansible Baseline 절차
- [`proxmox-acme.md`](proxmox-acme.md) — 2026-07-30 검증된 Proxmox VE 네이티브 ACME DNS-01 관리 TLS 절차
- [`opnsense-oob-console-recovery.md`](opnsense-oob-console-recovery.md) — 2026-07-30 검증된 OOB 콘솔 복구 경로와 lockout 복구 drill
- [`opnsense-proxmox-tagged-trunk.md`](opnsense-proxmox-tagged-trunk.md) — 2026-07-31 `NET-02R`에서 영속 할당·재부팅·tagged-only 경로를 재검증한 trunk 절차
- [`opnsense-vlan-bootstrap-firewall.md`](opnsense-vlan-bootstrap-firewall.md) — 2026-07-31 `NET-03`에서 적용·재부팅·실제 VLAN source로 검증한 IPv4 bootstrap 방화벽 절차
- [`opnsense-vlan-firewall-hardening.md`](opnsense-vlan-firewall-hardening.md) — 2026-08-03 `NET-04`에서 실제 통신표로 최소화하고 source별 hardened 검증을 마친 최종 VLAN 방화벽 절차
- [`proxmox-opentofu-vm-creation.md`](proxmox-opentofu-vm-creation.md) — 2026-07-31 `VM-01`에서 적용·게스트 검증·재부팅·무변경 재계획까지 확인한 서비스 VM 생성 절차
- [`opnsense-suricata-ids.md`](opnsense-suricata-ids.md) — 2026-07-31 `NIDS-01`에서 적용·재부팅·DMZ 런타임 및 경보 검증 완료한 Suricata alert-only IDS 절차
- [`k3s-single-node-baseline.md`](k3s-single-node-baseline.md) — 2026-07-31 `K3S-01`에서 단일 Node·SQLite·기본 구성요소·PVC·재부팅·NET-03을 검증한 k3s 기준선
- [`k3s-sqlite-datastore-backup-restore.md`](k3s-sqlite-datastore-backup-restore.md) — 2026-08-01 `BKP-01`에서 온라인 SQLite·server token 암호화 backup, 최소권한 S3, 격리 VM 음성·양성 복원과 정리를 검증한 절차
- [`integrated-disaster-recovery-drill.md`](integrated-disaster-recovery-drill.md) — 2026-08-02 `BKP-05` 통합 drill의 계층 의존성, RPO/RTO, 저장소 밖 입력과 실제 중단 지점
- [`netbird-selfhost.md`](netbird-selfhost.md) — 2026-07-31 `NB-01`에서 배포·재부팅·로컬 Owner 로그인과 백업을 검증한 NetBird self-host 절차
- [`warpgate-privileged-access.md`](warpgate-privileged-access.md) — 2026-07-31 `WG-01`에서 버전 선정·선언형 배포·역할 제한·감사/세션 기록·재부팅·격리 복원을 검증한 Warpgate 기준선
- [`vault-raft-baseline.md`](vault-raft-baseline.md) — 2026-07-31 `VAULT-01`에서 GitOps 배포·TLS·초기화/unseal·Pod 재시작 복구를 검증한 Vault 단일 replica Raft 기준선
- [`seaweedfs-s3-offsite-backup.md`](seaweedfs-s3-offsite-backup.md) — 2026-07-31 `BKP-04`에서 전송·격리 위치 복원·최소권한 음성 시험·실패 경보를 검증한 AWS S3 오프사이트 사본 절차
- [`aws-site-to-site-vpn.md`](aws-site-to-site-vpn.md) — 2026-07-31 `AWS-NET-01`에서 터널 확립·양방향 대조·기본 경로 불변·재부팅·장애 격리와 복구를 검증한 OPNsense↔AWS IPsec 절차
- [`vault-secrets-engines.md`](vault-secrets-engines.md) — 2026-08-01 `VAULT-02`에서 Kubernetes auth 허용·거부, policy 격리, 동적 DB 자격증명의 TLS 접속과 revoke, 내부 PKI 발급·폐기, audit 기록을 검증한 Vault 구성 절차
- [`headlamp-oidc-rbac.md`](headlamp-oidc-rbac.md) — `HEADLAMP-02`의 Keycloak OIDC·Pomerium Route·Kubernetes RBAC 전환과 독립 복구 절차(완료 증거 수집 전)
