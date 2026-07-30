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
- [`proxmox-opentofu-vm-creation.md`](proxmox-opentofu-vm-creation.md) — 2026-07-31 `VM-01`에서 적용·게스트 검증·재부팅·무변경 재계획까지 확인한 서비스 VM 생성 절차
- [`opnsense-suricata-ids.md`](opnsense-suricata-ids.md) — 2026-07-31 `NIDS-01`에서 적용·재부팅·DMZ 런타임 및 경보 검증 완료한 Suricata alert-only IDS 절차
