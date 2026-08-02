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

### 저장소 협업 정책

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `GIT-WF-01 DONE` | 병렬 worktree·rebase·단일 squash merge·사후 FIX 규칙을 `AGENTS.md`에 단일 원본으로 보강 | 없음 | 없음 | 모든 작업 | 작업 ID·브랜치·worktree 1:1, main 통합 직렬화, 재검증, 공개 main 재작성 금지, merge 후 정리 경계 |
| `GIT-WF-02 DONE` | 개발 작업의 승인·main 선행 live 검증·실패 rollback 규칙을 간소화 | `GIT-WF-01` | 없음 | 모든 작업 | 작업 배정 범위는 재승인하지 않음, production Argo는 main 유지, 성공은 main 1커밋·실패만 revert, 재시도는 새 FIX ID |
| `GIT-WF-03 DONE` | Argo 검증을 merge 전으로 옮겨 실패가 main 이력에 쌓이지 않게 규칙 교체 | `GIT-WF-02` | 없음 | 모든 작업 | `ARGO-ROOT` 잠금과 rebase 선행 아래 merge 전 라이브 검증, 실패는 같은 브랜치에서 재시도, main revert·OPS 스냅샷·재시도 FIX ID 커밋 폐지, 작업 ID 하나당 main 커밋 하나 |
| `GIT-WF-04 DONE` | `AGENTS.md` 안전 원칙 섹션을 단일 원본 문서로 되돌려 중복 제거 | `GIT-WF-03` | 없음 | 모든 작업 | 네 항목이 `README.md`·`.gitignore`·백로그 규칙 6에 이미 존재함을 확인하고 복제본만 삭제 |
| `GIT-WF-05 DONE` | 검증 범위·속도·실패 원인분석 원칙을 `AGENTS.md`에 명시 | `GIT-WF-04` | 없음 | 모든 작업 | 완료 증거 표 항목만 검증, 중복 검증 금지, 검증 도구는 대상 제약을 계산해 결정론적으로, 실패는 원인 특정 후 수정, 불안정한 검증은 도구부터 의심 |

2026-08-02 `GIT-WF-03`은 `GIT-WF-02`가 만든 "실패는 main에서 revert하고 재시도는 새 FIX ID"
규칙을 폐기했다. 그 규칙은 Argo 검증을 main에서만 할 수 있다고 전제해 실패 한 번마다 적용·
revert·rollback 스냅샷 커밋 세 개와 새 작업 ID·브랜치·worktree 한 벌을 만들었다. `HEADLAMP-02`는
이 경로로 `FIX-04`까지 가며 main 커밋 15개와 worktree 12개를 남기고도 `READY`에 머물렀다.
이제 Argo 검증은 `ARGO-ROOT` 잠금 아래 merge 전에 하고, 실패와 재시도는 작업 브랜치 안에서
끝내며, main에는 작업 ID 하나당 커밋 하나만 들어간다. `platform-root`를 브랜치 SHA로 고정하기
전 최신 `origin/main` rebase를 요구하는 것은 `VAULT-02` 때 다른 작업자의 선언이 원복된 사고를
막기 위해서다. 이 작업은 문서 규칙만 바꾸므로 라이브 검증 대상이 없다. 규칙 본문은
[`AGENTS.md`](../AGENTS.md)가 소유한다.

### 공유 잠금

| 잠금 | 보호 대상 |
|---|---|
| `PVE-LIVE` | Proxmox 설치·네트워크·스토리지 |
| `OPNSENSE-LIVE` | OPNsense API/UI·방화벽·DNS |
| `TOFU-STATE` | 동일 OpenTofu state의 plan/apply |
| `K3S-BOOTSTRAP` | k3s·Argo CD 초기 제어면 |
| `ARGO-ROOT` | `platform-root`의 `targetRevision` 검증용 전환 |
| `TRAEFIK-LIVE` | packaged Traefik HelmChartConfig·정적 plugin 등록·Pod 재기동 |
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
GITOPS-01 → INGRESS-01 → WAF-DESIGN-01 → CROWDSEC-PERF-01 → CROWDSEC-FIX-01

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
| `PVE-ACME-FIX-01 DONE` | Proxmox ACME DNS-01 자격증명을 전용 Cloudflare token으로 교체하고 갱신 불능 상태를 복구 (`infra/proxmox/acme/`) | `PVE-ACME-01` | `PVE-LIVE`, `PUBLIC-DNS` | Proxmox 관리 TLS 자동 갱신 | 라이브 plugin 저장값이 전용 token과 해시 일치(len 53), staging DNS-01 TXT 생성·검증·삭제 왕복 성공, production 재발급 후 issuer `CN=YR2`·serial 일치·만료 2026-10-30, 8006 strict TLS `ssl_verify=0` HTTP 200, `pve-daily-update.timer` active·`account=le-production`·`plugin=cf-dns` 연결, challenge TXT 잔여 없음, `pveproxy`·`pvedaemon`·`pve-cluster` active, `infra/opnsense/.env` 잔여 항목 제거로 `.env.example` 계약과 키 집합 일치, 회귀 검사 4/4 통과 |
| `SECRET-01 DONE` | 저장소 안 `.env` 4개를 `~/secrets/ktcloud4-bean/` 저장소 밖 단일 원본으로 이전 (`infra/opnsense`, `infra/proxmox`, `infra/proxmox/acme`, `gitops/apps/ingress`) | `PVE-ACME-FIX-01` | `PVE-LIVE`, `OPNSENSE-LIVE` | 모든 credential 입력 | 저장소 안 `.env` 0개, 네 스크립트 기본 경로가 저장소 밖 mode 0600 파일로 이동, symlink·비 0600·부재 입력 거부 확인, `check-drift.sh`(OPNsense 인증·조회)·`setup-acme.sh plugin`(저장값 해시 유지)·`inject-cloudflare-secret.sh`(env 검증 통과)·tofu 토큰 추출 검증, 비밀 아닌 값 `OPN_URL`·`OPN_CACERT`·`PROXMOX_ACME_EMAIL` 제거 후 동작 동일, `.env.example` 4개는 형식 계약으로 유지, 회귀 검사 통과 |
| `SECRET-02 DONE` | credential 입력 경로를 `KTC_SECRET_ROOT` 단일 환경변수로 통일하고 `.env.example` 4개를 제거해 형식 계약을 각 README로 이관 | `SECRET-01` | `OPNSENSE-LIVE` | 모든 credential 입력 | 세 스크립트가 `KTC_SECRET_ROOT` 주입을 따르고 미지정 시 기존 기본값과 동일 동작, 명시적 인자·`PVE_ACME_ENV_FILE` override가 계속 최우선, 존재하지 않는 root 지정 시 해당 경로로 실패해 주입 반영 확인, `.env.example` 4개 제거 후 각 README가 키 목록·형식 제약 소유, `check-drift.sh` 기본·커스텀 root 라이브 조회 성공, 회귀 검사 통과 |
| `SECRET-03 DONE` | crowdsec credential 입력을 `$KTC_SECRET_ROOT/crowdsec/env`로 옮기고 마지막 `.env.example` 제거 (`gitops/tools/crowdsec-01/`) | `SECRET-02` | 없음 | `CROWDSEC-FIX-01` 재적용 | `prepare-secret-input.sh`·`inject-secrets.sh` 기본 경로가 저장소 밖으로 이동하고 위치인자 override 유지, 입력 디렉터리 mode 0700 자동 생성과 기존 경로 미덮어쓰기 유지, 형식 계약 3 key를 `gitops/apps/crowdsec/README.md`가 소유, 저장소 `.env.example` 0개로 `.gitignore` 예외 제거, 라이브 secret 불변 확인(`crowdsec-01/crowdsec-01-bootstrap` 3 key·`kube-system/crowdsec-01-bouncer` `bouncer-key`), shellcheck 통과 |
| `OS-01 DONE` | Rocky Linux 9 Minimal cloud-init template·Ansible 공통 baseline | `PVE-01` | `PVE-LIVE` | 모든 VM | VMID 9000 template 생성, clone 후 SSH key, 시간, 저장소, qemu-agent, 재부팅, Ansible 멱등성 검증 |
| `IAC-01 DONE` | OpenTofu provider·state·VM 공통 모듈 (`infra/proxmox/tofu/`) | `PVE-01`, `DNS-01`, `CAP-01` | `TOFU-STATE` | `PVE-ACME-01`, `VM-01` | secret 없는 init/validate/plan, state 보관 방식과 import 경계 검증 |
| `NET-01 DONE` | `vlan-verify`의 bootstrap/hardened profile과 테스트 | 없음 | 없음 | `NET-02`, `NET-02R`, `NET-04` | 현재망 회귀 테스트, 기대 허용·차단을 exit code로 판정 |
| `REC-01 DONE` | OOB 콘솔 복구 경로 검증·lockout 복구 drill (`docs/runbook/opnsense-oob-console-recovery.md`) | `PVE-01` | `OPNSENSE-LIVE` | `NET-02`, `NET-02R` | 주 LAN 주소 상실 상태에서 관리 경로 도달 실패와 OOB 콘솔 생존을 같은 시점에 관측, 콘솔로 복구 후 원상복귀, drift 없음, runbook 검증 |
| `REC-02 DEFERRED` | `igc0` 물리 RECOVERY 포트 추가 | `REC-01` | `OPNSENSE-LIVE` | 없음 | 현장에서 케이블 연결 후 주 LAN 없이 GUI 접근과 원상복귀 |

`PVE-01`은 디스크를 지우는 작업이다. 자동설치 PoC는 수동 설치에서 확인한 값을 사용하되 현재 물리 노드에 재실행하지 않는다. `PVE-ACME-01`은 443 전환이나 공개 경로 추가가 아니라 설치 후 8006의 서버 신뢰를 닫는 작업이다. 다만 그 완료 증거는 토큰을 흘리지 않았는지만 요구했고 어떤 token이 실제로 저장됐는지는 확인하지 않았다. 2026-08-01 점검에서 `infra/proxmox/acme/.env`가 OPNsense용 token을 그대로 담고 있었고([ADR-0009](adr/0009-proxmox-native-acme-management-tls.md)가 금지하는 재사용), 라이브 plugin에는 그 어느 값과도 다른 32자 문자열이 저장돼 Cloudflare가 형식 단계에서 거부하는 상태였다. 발급된 인증서가 유효한 동안에는 이 상태가 드러나지 않고 만료 30일 전 자동 갱신에서야 실패하므로, `PVE-ACME-FIX-01`에서 전용 token으로 교체하고 staging DNS-01 왕복으로 실증한 뒤 production을 재발급했다. 같은 작업에서 `setup-acme.sh`의 계정 중복 판정(출력 형식 가정)과 `verify_cert`의 재시작 경합·staging issuer 오통과도 함께 고쳤다. `REC-01`은 OOB 콘솔이 랩 네트워크와 독립으로 동작함을 확인했다. OOB는 HOME 뒤에 있어 WAN·HOME이 손상되면 함께 끊기므로, 그 경우를 위한 `igc0` 물리 포트는 현장 접근이 가능할 때 `REC-02`로 검토한다. 부트스트랩과 자동화 경계는 [ADR-0001](adr/0001-proxmox-bootstrap-reproducibility.md), Proxmox 인증서 소유권은 [ADR-0009](adr/0009-proxmox-native-acme-management-tls.md), OpenTofu provider·state 경계는 [ADR-0008](adr/0008-opentofu-provider-and-state-boundary.md)을 따른다.

credential 입력 파일의 위치 규약은 `SECRET-02`가 소유한다. 실제 값은 `$KTC_SECRET_ROOT/<component>/env`에 mode `0600`으로 두며, `KTC_SECRET_ROOT`를 지정하지 않으면 `~/secrets/ktcloud4-bean`을 쓴다. 저장소는 운영자의 홈 구조를 가정하지 않고 형식 계약은 각 컴포넌트 README가 소유한다. `.gitignore`는 실수 커밋만 막을 뿐이고 `git clean -xfd`와 worktree 정리는 저장소 안 파일을 지우므로, 저장소 안에 원본을 두면 보관 수단이 되지 못한다. 비밀이 아닌 설정값은 이 파일에 섞지 않고 스크립트 상수나 `docs/ip-plan.md` 같은 기존 단일 원본이 소유한다.

## 2. VLAN과 VM 기반

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `NET-02 DONE` | 최초 OPNsense–Proxmox tagged-only trunk 전환 이력 (`docs/runbook/opnsense-proxmox-tagged-trunk.md`) | `PVE-01`, `REC-01`, `NET-01` | `PVE-LIVE`, `OPNSENSE-LIVE` | `NET-02R` | 당시 런타임 전환은 확인됐지만 OPNsense 영속 완료 증거는 재점검에서 철회했고 `NET-02R`에서 보정·재검증함 |
| `NET-02R DONE` | OPNsense VLAN 논리 할당·gateway 영속성 보정과 tagged-only trunk 재검증 (`docs/runbook/opnsense-proxmox-tagged-trunk.md`) | `NET-02`, `REC-01`, `NET-01` | `PVE-LIVE`, `OPNSENSE-LIVE` | `NET-03`, 모든 VM 주소·경로 | 저장 설정에서 LAN=`vlan01`, VLAN 20~50 논리 할당·gateway, 부모 `igc2` 무주소; 런타임 직접 route·관리 SSH/TLS/DNS·tagged 성공·untagged 차단; OPNsense 재부팅 후 동일; drift 없음 |
| `NET-03 DONE` | VLAN 기본 deny와 bootstrap 허용 정책 ([runbook](runbook/opnsense-vlan-bootstrap-firewall.md)) | `NET-02R` | `OPNSENSE-LIVE` | 모든 서비스 통신 | 저장 rule 16개와 PF 확장 24개 일치; 실제 VLAN 20~50에서 DNS·NTP·공개 Web 허용과 관리망·HOME·project 간 차단, 최신 ALLOW control, MGMT stateful 응답; 재부팅 후 재검증, 임시 자원 제거, drift 없음 |
| `NET-03A DONE` | Vault DB engine을 위한 k3s-01 → postgres-01 TLS TCP 5432 단일 경로 보정 ([runbook](runbook/opnsense-vault-postgres-path.md)) | `NET-03`, `PG-01`, `VAULT-01` | `OPNSENSE-LIVE` | `VAULT-02` | Vault Pod TCP가 OPNsense 양 VLAN에서 SYN/SYN-ACK으로 확인; `vlan02` 단일 IPv4 TCP 5432 PASS UUID·PF counter, 기존 S3 8333·관리 경로 불변, rollback backup hash·drift 없음 |
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
| `NB-01-FIX-01 DONE` | NetBird role에 커밋된 폐기 Cloudflare 토큰 기본값 제거 | `NB-01` | 없음 | NetBird 구성 입력 경계 | 현재 HEAD 실제 토큰 0건, 역할 내 Cloudflare 입력 참조 0건, Ansible 검증, 토큰 폐기 확인 및 공개 과거 이력 잔존 기록 |
| `WG-01 DONE` | Warpgate 기본 배포와 로컬 복구 계정 | `VM-01` | 없음 | 특권 접근 | Warpgate v0.26.1 고정·checksum·SBOM, 비-root + systemd hardening + SELinux label, 세션 중계와 기록 생성·제품 조회, 대상별 역할 허용/거부, 로컬 복구 로그인 성공·실패, 재부팅 후 유지, 격리 인스턴스 복원, Ansible 멱등(changed=0) |
| `AWS-NET-01 DONE` | OPNsense↔AWS Site-to-Site VPN | `NET-03` | `OPNSENSE-LIVE` | AWS 사설 연동 | 양쪽 관점 일치한 IKEv2 SA, 실제 VM의 payload 정방향과 selector 밖 대조 차단, 역방향 허용·차단 양쪽 실증, 기본 경로 불변, 재부팅 후 자동 복구, 장애 격리·복구, 임시 자원 제거·plan 무변경·PSK 미커밋 |

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

2026-07-31 `AWS-NET-01`에서 OPNsense와 AWS를 policy-based Site-to-Site VPN으로 연결했다.
AWS 착지점은 `infra/aws/tofu-network` 별도 state root가 소유하며 오프사이트 백업 root와
state를 공유하지 않는다. 10개 리소스를 적용했고 최종 재-plan은 무변경이다. VPC에는 인터넷
gateway를 두지 않아 유일한 외부 경로가 VPN이며, BGP 대신 static routing을 써서 터널이
기본 경로를 바꿀 수 없다. OPNsense 26.7의 swanctl Connections로 IKEv2·`aes256-sha256-modp2048`
단일 연결을 만들고 traffic selector를 DATA VLAN ↔ VPC 대역으로 좁혔다.

라이브 검증에서 OPNsense `swanctl`의 IKE `ESTABLISHED`·Child `INSTALLED`와 AWS telemetry의
터널 `UP`·`AcceptedRouteCount` 1이 일치했다. 실제 VM `object-01`에서 ICMP 3/3(약 6.9ms)과
HTTP marker payload를 받아 정방향을 payload로 판정했고, SA 카운터가 양방향으로 증가해
트래픽이 실제 터널을 지난 것을 확인했다. selector 밖인 PLATFORM·ACCESS 출발지는 같은
목적지로 모두 실패했으며 모든 BLOCK에 같은 시점 `object-01` 성공을 대조로 두었다.
역방향은 임시 허용 규칙이 있을 때 연결과 payload가 온프레미스 listener에 도착했고, 규칙을
제거한 뒤 재시도 3회분 동안 0건이었다. 기본 경로는 계속 WAN이고 커널 라우팅 테이블에 VPC
대역 항목이 생기지 않았다. OPNsense 재부팅 34초 뒤 SA가 자동 재확립됐고 방화벽 규칙과
`enc0` 인바운드 부재까지 재부팅 전과 같았다. IPsec 서비스를 내리자 AWS 경로만 끊기고
DNS·인터넷 HTTPS·관리 SSH는 영향이 없었으며 다시 올리자 복구됐다.

검증 인스턴스와 보안 그룹 5개, 온프레미스 임시 listener를 모두 제거했다. 스냅샷 갱신 뒤
실제 PSK 문자열로 검색해 평문이 남지 않은 것을 확인했고 drift는 없다. `normalize.py`에
PSK 마스킹 회귀 테스트를 추가했다.

남은 한계는 명시한다. 터널 2는 AWS 쪽에만 있어 AWS가 터널 1을 유지보수하면 단절될 수 있고,
WAN이 ISP DHCP 임대라 주소가 바뀌면 Customer Gateway 교체가 필요하다. DATA VLAN 허용 규칙은
프로토콜·포트를 좁히지 않은 임시 규칙이며 `NET-04`가 다시 판정한다. 이 작업이 만든 것은
검증된 경로이지 그 위에 올릴 서비스가 아니다. VPN Connection은 존재하는 시간에 비례해
과금되므로 유지 여부는 필요에 따라 gate 변수로 결정한다. 상세는
[AWS VPN runbook](runbook/aws-site-to-site-vpn.md)과 [ADR-0011](adr/0011-aws-site-to-site-vpn-boundary.md)이
소유한다. 백로그에서 `AWS-NET-01`을 선행으로 갖는 작업이 없으므로 새로 `READY`로 여는
후속은 없다. `AWS-ID-01`은 `KC-01`이, `KMS-01`은 `BKP-05`가 남아 있고 VPN은 그 선행이 아니다.

## 4. k3s 제어면·인증

통합인증·관리 접근은 [ADR-0004](adr/0004-zero-trust-identity-and-management-access.md), Vault bootstrap과 seal 경계는 [ADR-0006](adr/0006-vault-seal-and-bootstrap-boundary.md)을 따른다.

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `GITOPS-01 DONE` | `gitops/` 생성·Argo CD bootstrap·root Application | `K3S-01` | `K3S-BOOTSTRAP` | 이후 k3s 앱 | 새 clone에서 bootstrap, Synced/Healthy, secret 원문 없음 |
| `HEADLAMP-01 DONE` | Headlamp 기본 GitOps 배포·내부 bootstrap 접근 | `GITOPS-01` | 없음 | 초기 k3s 조회·`HEADLAMP-02` | Argo Synced/Healthy, 외부 ingress 없음, Headlamp SA 무권한, port-forward와 단기 reader token으로 리소스·로그 조회 |
| `STOR-01 DONE` | local-path 경로·`local` PV 타입·disk-pressure 검증 | `K3S-01` | `K3S-BOOTSTRAP` | 모든 PVC·`BKP-02` | 동적 PVC, capacity 미강제, 재부팅 후 데이터, SELinux 삭제 helper, 임계치 기준 |
| `INGRESS-01 DONE` | Traefik 단일 ingress·별도 DNS-01 인증서 | `GITOPS-01` | `PUBLIC-DNS`, `OPNSENSE-LIVE` | 모든 HTTP 앱 | 80→443, 내부·외부 split DNS, OPNsense 개인키 미복사, source IP 판정 |
| `VAULT-01 DONE` | Vault Raft 단일 replica·수동 Shamir 초기화 | `GITOPS-01`, `STOR-01` | `VAULT-INIT` | 모든 시크릿 소비자 | TLS, unseal·재시작, share/root token Git 부재, 로컬 복구 절차 |
| `VAULT-02 DONE` | KV v2·Kubernetes auth·DB engine·PKI·audit policy ([runbook](runbook/vault-secrets-engines.md)) | `VAULT-01`, `PG-01`, `NET-03A` | 없음 | 모든 플랫폼 앱 | 바인딩 SA만 로그인·타 SA/role 403, policy allow/deny 403, 동적 DB credential의 TLSv1.3 verify-full 접속·타 DB 거부·revoke 후 인증 실패와 role 삭제, PKI 체인 검증·CRL 폐기·공인 이름 거부, audit 108건과 평문 시크릿 0건, vault ns Secret 0건 유지 |
| `KC-01 DONE` | Keycloak 배포·realm·그룹/client role·일상/특권 ID | `PG-01`, `VAULT-02`, `INGRESS-01` | 없음 | Pomerium·Headlamp·NetBird·Warpgate·AWS | MFA, claim, 최소 role, 로컬 admin 복구, issuer 고정 |
| `KC-01-FIX-01 DONE` | bootstrap 메모리 시크릿 정리를 fail-closed로 보정 | `KC-01` 배포 선언 | 없음 | Keycloak bootstrap | Agent/bootstrap 동일 UID, 렌더링 파일 정리 실패 시 Job 실패, v1 prune·v2 성공 |
| `WAF-DESIGN-01 DONE` | 실패한 direct Coraza connector를 폐기하고 CrowdSec AppSec 전환 경계 결정 | `INGRESS-01` | 없음 | `CORAZA-01`, `CROWDSEC-01`, `CROWDSEC-PERF-01`, `CROWDSEC-FIX-01`, `EDGE-01`, `AUDIT-01` | 새 ADR·목표 아키텍처·의존성 정합성, 실패 재현 자산의 비활성 evidence 격리, 라이브 변경 0 |
| `CORAZA-01 DEFERRED` | Traefik HTTP-WASM Coraza + CRS 직접 PoC; 호환 실패로 폐기하고 `CROWDSEC-01`이 대체 | `INGRESS-01` | 없음 | 없음 | 재실행하지 않음; [ADR-0012](adr/0012-crowdsec-appsec-origin-waf.md)의 재검토 조건이 생기면 새 결정·새 작업으로만 검토 |
| `CROWDSEC-01 DEFERRED` | CrowdSec AppSec(Coraza + OWASP CRS) route-scoped PoC 최초 시도; CRS ConfigMap 바이트 훼손과 AppProject prune 순서 결함으로 revert | `INGRESS-01`, `WAF-DESIGN-01` | 없음 | `CROWDSEC-FIX-01` | 공개 main enablement와 rollback 이력을 재작성하지 않음; [실패 증거](evidence/crowdsec-fix-01/README.md)를 기준으로 FIX에서만 보정 |
| `CROWDSEC-PERF-01 DONE` | rollback 상태에서 CrowdSec 성능 실패의 client/DNS/TCP/TLS 측정 경로를 분리하고 warm-up 계약 보정 | `INGRESS-01`, `WAF-DESIGN-01` | 없음 | `CROWDSEC-FIX-01` | read-only 1,000건 cold 대조, concurrency 10 지속 HTTP/2 1,000건×3회, 신규 연결·실패 0, 라이브 Argo/HCC/Traefik 불변, ADR 기준값 미완화 |
| `CROWDSEC-FIX-01 DONE` | byte-preserving CRS snapshot·offline AppSec startup·API round-trip·영구 AppProject로 CrowdSec AppSec route-scoped PoC 보정 | `INGRESS-01`, `WAF-DESIGN-01`, `CROWDSEC-PERF-01` | `TRAEFIK-LIVE` | 공개 HTTP·`EDGE-01` | immutable 공급망·49개 byte hash·3.7.4 격리 호환, route 200/403·exact 예외·control·decision 0, WAF 증분 1~3ms와 Tailscale 외생 지연 분리, working set 잔류 10Mi·verifier RSS 보정, fail-closed·rollback·단일 재기동·기존 ingress 회귀 없음 |
| `POM-01 DONE` | Pomerium Core·선언형 Route·Dashy Portal | `KC-01`, `INGRESS-01`, `VAULT-02` | 없음(단, 내부 DNS 적용은 실제 `OPNSENSE-LIVE` 승인 필요) | 내부 웹 접근 | groups claim 허용/차단, Portal 표시, Keycloak 장애 시 독립 복구 경로 |
| `HEADLAMP-02 DONE` | Headlamp Keycloak OIDC·Kubernetes RBAC·Pomerium Route | `HEADLAMP-01`, `POM-01` | `K3S-BOOTSTRAP` | k3s 일상 관리·`CAP-02` | 공유 cluster-admin SA 없음, 사용자별 조회·로그·exec·변경 allow/deny, bootstrap token 폐기, GitOps drift 없음, IdP 장애 시 break-glass kubeconfig |
| `HEADLAMP-02-FIX-05 DONE` | Headlamp v0.44.0의 `/clusters/main` HttpOnly cookie 경계에 맞게 browser verifier를 보정하고 HEADLAMP-02 전체 경계를 재도입 | `HEADLAMP-01`, `POM-01` | `K3S-BOOTSTRAP` | k3s 일상 관리·`CAP-02` | cookie path 회귀 테스트, 사용자 OIDC·RBAC 전체 live·rollback·break-glass 재검증 |
| `NB-02 DONE` | NetBird 일반 인증을 Keycloak OIDC로 전환 | `NB-01`, `KC-01` | 없음 | 원격 사용자 | 신규 OIDC 로그인·그룹 정책과 로컬 Owner 복구 모두 성공 |
| `WG-02 DONE` | Warpgate SSO·역할·세션 정책 연동 | `WG-01`, `KC-01` | `OPNSENSE-LIVE`, `PUBLIC-DNS` | 관리자 접근 | 일반/특권 분리, 허용 대상만 접속, IdP 장애 복구 검증 |
| `AWS-ID-01 DONE` | Keycloak `AssumeRoleWithSAML`·AWS role 매핑 | `KC-01` | 없음 | AWS 콘솔 권한 | 그룹별 임시 role, 세션 만료, 과권한·지속키 없음 |

2026-08-01 `POM-01`에서 Pomerium Core `v0.33.0`과 Dashy `4.5.0`을 각 공식
multi-arch image index digest로 고정하고 전용 AppProject·child Application·namespace에
GitOps 배포했다. 기존 packaged Traefik 뒤의 ClusterIP HTTP upstream과 표준 Ingress만 써서
HelmChartConfig·정적 plugin·entrypoint·Traefik Pod를 바꾸지 않았고, 적용 전후 Traefik
UID `046738f1-1b1a-4709-a0c3-f41d4168420d`, restart 0과 HelmChartConfig
resourceVersion/generation `66161/10`이 같았다. Argo root·child는 immutable revision에서
`Synced/Healthy`, Pomerium namespace Secret은 0건이며 confidential client secret은 Vault
KV v2에서 전용 ServiceAccount·`audience=vault` Agent init container와 memory `emptyDir`로만
소비한다.

실제 Keycloak claim에서 `imcherry`의 `/platform-users`만 보호 Route 200과 Dashy 보호 타일
표시를 얻고, `/platform-users`가 없는 `imcherry-admin`은 같은 시점 Route 403과 타일 미표시가
됐다. MFA 없는 token 요청 거부, logout 뒤 재인증, 5분 session 실제 만료 뒤 재인증,
정확한 `access` TLS hostname 성공·잘못된 hostname 실패·HTTP 301을 확인했다. Pomerium과
Dashy Pod를 각각 재생성한 뒤 UID 변경·Ready와 같은 전체 검증·session 만료를 다시 통과했다.
승인된 복구 drill에서는 `platform` realm 비활성 중에도 trusted SSH와 root-only k3s
kubeconfig로 Pomerium health를 조회하고 Pod를 90초 안에 재생성했으며, master realm 복구
ID로 즉시 realm을 활성화해 일상 token 200과 전체 검증을 재확인했다. Git 추적 파일과 전체
Pomerium/Dashy Pod 로그의 client secret·JWT 원문은 0건이다.

승인된 `OPNSENSE-LIVE` 범위에서는 기존 `k3s-01` override에
`access.imcherry5778.xyz → 10.10.20.10` Unbound alias 한 건만 추가했다. 내부 A만 응답하고
내부 AAAA와 공개 A/AAAA는 0건이며 공개 DNS·NAT·Cloudflare는 변경하지 않았고 sanitized
snapshot 갱신 뒤 drift 없음이다. 직접 후속 중 모든 선행이 충족된 `HEADLAMP-02`와
`POL-01`만 `READY`로 열었다. `NET-04`와 `EDGE-01`은 각각 다른 미완료 선행이 남아
`BLOCKED`를 유지한다.

2026-08-01 `AWS-ID-01`은 세 번째 AWS identity state root에서 Keycloak SAML provider와
일상/특권 분리 temporary role을 적용했다. daily/privileged console SAML, 무그룹 role 없음·STS
거부, 최소권한 allow/deny, 900초 만료, 사람용 IAM access key 0, 검증용 임시 user 제거와 최종
OpenTofu plan 무변경을 확인했다. 현재 백로그에서 `AWS-ID-01`을 선행으로 갖는 직접 후속은
없으므로 새로 `READY`로 연 작업은 없다.

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

2026-08-01 `HEADLAMP-01`에서 Headlamp `v0.44.0` 공식 image를 digest로 고정하고
원시 manifest(Kustomize)와 전용 AppProject·child Application으로 배포했다. Service는
`ClusterIP`만 사용하고 Ingress·IngressRoute는 0개다. 서버 `headlamp` ServiceAccount에는
workload 리소스 RBAC binding이 없으며, 자동 token mount 대신 만료 600초의 projected
token만 명시적으로 사용한다. 별도 `headlamp-reader`는 namespace·node·Pod·Service·Event·
기본 workload·Job 조회와 `pods/log get`만 허용한다. TokenRequest로 받은 TTL 600초 token을
mode 0600 임시 파일과 이중 loopback port-forward에만 두고 Headlamp proxy에서 리소스·로그
200을 확인했다. Secret 조회와 create·추가 TokenRequest·update·delete·exec는 403이었고
모든 변경 요청은 dry-run으로 제한했다. 장기 ServiceAccount token Secret과 token 원문의
Git·로그 잔류는 0건이다. immutable revision 재동기화 뒤 Argo root·child
`Synced/Healthy`, Pod 1/1·restart 0, Node `Ready`·DiskPressure `False`를 확인했다.
`HEADLAMP-02`는 `POM-01` 선행이 남아 `BLOCKED`를 유지한다. 접근·검증·Git revert rollback은
[Headlamp 내부 bootstrap 기준선](../gitops/apps/headlamp/README.md)이 소유한다.

2026-07-31 `INGRESS-01` staging preflight에서 Unbound가 공인 zone 전체를 Dnsmasq로
forward해 내부 exact A override 밖의 공개 SOA·NS를 NODATA로 만드는 것을 확인했다.
명시적으로 추가 승인한 `OPNSENSE-LIVE` 잠금 아래 해당 query-forward row만 비활성화하고
Unbound를 재구성했다. 내부 canonical A 9개와 PTR 7개는 유지됐고, 내부 resolver의 공개
SOA·NS가 Cloudflare authoritative 결과와 일치했으며 CoreDNS를 사용하는 임시 Pod에서도
동일했다. PF·NAT·DHCP·공개 DNS는 바꾸지 않았고 임시 namespace를 제거한 뒤 OPNsense
drift 없음까지 확인했다. 인증서·redirect·restart 검증이 남았으므로 `INGRESS-01`은
`READY`를 유지한다.

2026-07-31 같은 작업의 staging 재검증에서 packaged Traefik `3.7.4` 하나와 기존
imageID를 유지하고 DNS-01 발급에 성공했다. Cloudflare API 쓰기 직후 Unbound가
NXDOMAIN을 1800초 negative cache하던 경쟁은 두 resolver의 propagation 확인을 30초
지연하고, 실패 재시도 전에 남은 정확한 challenge TXT cache만 한 번 flush해 해소했다.
두 authoritative NS에서 TXT `0→1→0`, 정확한 SAN·staging chain·잘못된 hostname 실패,
위조 XFF 비신뢰와 `ClientHost=10.10.60.2`, 인증서 발급 뒤 Pod 교체 시 fingerprint·HTTPS
200·ACME 파일 불변을 확인했다. Argo revision 일치·Synced/Healthy, Git/live
HelmChartConfig 일치, Traefik·ServiceLB 단일 인스턴스, 전체 Pod·Node·DiskPressure·용량·
failed unit과 OPNsense drift도 정상이다. ingress 전용 token은 live Secret과 일치하고
Git 이력·diff에 없지만, 최신 main의 NB-01 defaults에는 이 token과 다른 `cfat_` 형식
credential이 추적된 별도 보안 차이가 있다. production 전에 해당 credential을
Cloudflare에서 폐기·회전하고 소유 작업에서 Git 경계를 교정해야 한다. production DNS-01,
system strict TLS와 80→443 redirect도 별도 승인 전이므로 `INGRESS-01 READY`,
`CORAZA-01 BLOCKED`, `KC-01 BLOCKED`를 유지한다.

2026-07-31 `INGRESS-01` production 승인 뒤 NB-01 defaults에 노출됐던 별도 Cloudflare
token의 폐기를 사용자에게 확인받고 승격했다. staging ACME state가 같은 SAN을 전역
TLS store에 제공해 production 요청을 막는 동작을 확인해 staging 파일 하나만 0바이트로
정리했으며, production resolver를 명시한 폐기형 IngressRoute로 DNS-01을 발급했다. 두
authoritative NS의 TXT `0→1→0`, Let's Encrypt `YR1` chain·정확한 SAN·유효기간,
system strict TLS 성공과 잘못된 hostname 실패를 확인했다. HTTP는 path/query를 보존한
HTTPS Location으로 permanent `301`을 반환했다. 정상·위조 XFF에서
`ClientHost=10.10.60.2`와 backend 전달 경계가 같고 위조 값은 제거됐다. Pod 교체 뒤
certificate fingerprint·strict HTTPS·redirect·ACME 파일이 유지됐고 TXT 재생성은 없었다.
public A·AAAA·NAT는 만들지 않았으며 내부 A `10.10.20.10`과 외부 NXDOMAIN의 split DNS를
재확인했다. k3s·OPNsense·Proxmox 인증서 public key는 모두 달랐고 ingress private key는
PVC의 mode `0600` ACME 파일에만 있다. 최종 Argo revision 일치·Synced/Healthy,
Git/live HCC 일치, 단일 Traefik·IngressClass·ServiceLB, 전체 Pod·Node·DiskPressure·용량·
failed unit·OPNsense drift를 확인하고 임시 namespace·TXT·port-forward를 제거했다.
`INGRESS-01`을 `DONE`, 직접 후속 `CORAZA-01`만 `READY`로 열며 `VAULT-02`가 남은
`KC-01`은 `BLOCKED`를 유지한다.

2026-08-01 `WAF-DESIGN-01`에서 packaged Traefik `3.7.4`와 catalog 고정
`coraza-http-wasm-traefik v0.3.0`을 같은 image digest에서 격리 재검증했다. plugin을
정적으로 load한 control route는 200이지만 최소 middleware와 full CRS middleware를
attach하면 OOM 없이 Traefik이 exit 2와 `fatal error: runtime: split stack overflow`로
종료됐다. 라이브 HelmChartConfig·route·Argo·DNS·인증서에는 Coraza 자원을 만들지
않았고 이 설계 작업도 라이브 변경을 수행하지 않았다. direct connector 구현은
`CORAZA-01 DEFERRED`로 폐기하고, 재현 파일은 활성 `gitops/` 경로가 아닌
[폐기 증거](evidence/coraza-01/README.md)로 격리했다.

대체 경로는 [ADR-0012](adr/0012-crowdsec-appsec-origin-waf.md)에 따라 Traefik process
안에서 Coraza WASM을 실행하지 않고 별도 CrowdSec AppSec가 Coraza·OWASP CRS 검사를
수행하며 route-scoped community bouncer가 판정만 연결한다. `CROWDSEC-01`은 전용 내부
test route 이외 middleware 적용, community blocklist·IP ban·Console enrollment,
Cloudflare·OPNsense·DNS·인증서·entrypoint 변경을 금지한다. bouncer 정적 등록은
middleware attach 범위와 달리 HelmChartConfig 변경과 유일한 Traefik Pod 재기동을
일으키므로 source·고정값·정상 트래픽 영향·성능 기준·rollback을 제시한 별도 승인을
받기 전에는 적용하지 않는다. `INGRESS-01`과 `WAF-DESIGN-01`이 `DONE`이므로
`CROWDSEC-01`만 `READY`로 열었다. `EDGE-01`은 `POM-01`·`NB-02`·`NET-04`가 남아
`BLOCKED`, `AUDIT-01`도 기존 선행이 남아 `BLOCKED`를 유지한다.

2026-08-01 `CROWDSEC-01` enablement는 AppSec init에서 CRS snapshot 49개가 모두
SHA-256 불일치해 live gate 전에 중단했다. 원본 파일은 마지막 LF를 포함했지만
Helm template의 YAML `|-` 직렬화가 ConfigMap value의 마지막 LF를 제거했고,
소스 디렉터리를 bind mount한 Docker 격리 시험은 이 Kubernetes 경계를 통과하지
않아 결함을 찾지 못했다. 즉시 main revert로 원래 ingress를 회복했으나 root가
AppProject를 Application보다 먼저 prune해 finalizer가 `project not found`로 멈추는
두 번째 결함도 확인했다.

공개 main 뒤 발견한 결함이므로 기존 ID를 재개하지 않고 `CROWDSEC-FIX-01`이
별도 branch·worktree에서 보정한다. 이 FIX는 비밀이 없는 최소 AppProject를
enablement보다 먼저 영구 기반으로 남기고, CRS를 deterministic binary archive로
전달하며, 실제 Kubernetes API 직렬화 후의 archive·49개 파일 hash를 검증한다.
사용자는 영구 기반, 수정 enablement, live evidence·`DONE` 순서의 main 3커밋
예외를 승인했다. Traefik 재기동은 enablement 후 한 번만 허용하며 직전에
`KC-01` 상태와 시점을 다시 확인한다. `EDGE-01`은 이 FIX와 `POM-01`·`NB-02`·
`NET-04`가 모두 완료될 때까지 `BLOCKED`를 유지한다.

2026-08-01 수정 enablement `0d6ff16125d49e282f9ea01c765b3dd428f0e5cf`는 CRS 49개
Kubernetes API byte hash, 정상·공격·exact 예외·control과 기존 ingress 회귀를
통과했다. 그러나 성능 도구가 1,000개 요청마다 별도 process로 DNS·TCP·TLS 연결을
새로 만들어 control/WAF p95가 모두 약 `333ms`였고 ADR의 절대 `100ms` gate를 넘었다.
증분은 `-1.521ms`, `3.348ms`였지만 gate를 완화하지 않고 round 3을 중단한 뒤 rollback
`f4841207ca71901566117a03c3c8998b42bfafef`로 AppSec Application·namespace·Secret과
Traefik 정적 등록을 제거했다. root·ingress·keycloak은 rollback SHA에서
`Synced/Healthy`, HCC generation `9`, Traefik Pod UID
`30abf3ac-5239-498e-b2e1-e445f17ea9c5`, restart `0`, Ready로 회복했다.

`CROWDSEC-PERF-01`은 이 상태를 변경하지 않고 [성능 측정 진단](evidence/crowdsec-perf-01/README.md)을
수행했다. client→ingress RTT 평균 `72.472ms`에서 cold DNS/TCP/TLS 포함 p95는
`336.934ms`, concurrency 10의 warmed HTTP/2 연결을 재사용한 1,000건 세 round p95는
`72.517ms`·`72.827ms`·`72.867ms`였다. 전체 실패와 측정 구간의 신규 연결은 0이었고
전후 Argo revision, HCC generation/resourceVersion, Traefik Pod UID·restart·imageID가
동일했다. ADR의 p95 증분 `20ms`·절대 `100ms`는 유지하고 warm-up 의미만 고정했다.
따라서 `CROWDSEC-PERF-01`은 `DONE`, 직접 후속 `CROWDSEC-FIX-01`은 `READY`다. 다음
enablement는 이 측정 방식으로 WAF/control을 다시 검증하며, Traefik 재기동 전에 다섯
항목과 현재 적용 시점을 다시 승인받는다. `EDGE-01`은 `CROWDSEC-FIX-01` 외에도
`POM-01`·`NB-02`·`NET-04`가 남아 `BLOCKED`를 유지한다.

2026-08-01 `CROWDSEC-FIX-01`은 최신 main과 `KC-01 DONE`·`Synced/Healthy`를 적용 직전에
재확인하고, 사용자가 승인한 다섯 항목과 시점에 따라 signed enablement
`27db9b352020821b8b5e2cc9a6ab00822d9bcaab`를 적용했다. 저장소 밖 mode `0600` 파일로
bootstrap·bouncer Secret을 주입한 뒤 원문을 즉시 파기했고 Git의 secret 원문은 0건이다.
HCC generation `9 → 10`, Traefik Deployment `13 → 14`, Pod UID가 정확히 한 번
교체됐으며 기존 `3.7.4` image digest·restart `0`을 유지했다. root·ingress·keycloak·
crowdsec은 같은 SHA에서 `Synced/Healthy`다.

정상 control/WAF `200`, rule `913100` 공격 `403`, exact URI+UA 예외만 `200`, 세 negative
예외 `403`, middleware 없는 control 공격 `200`, decision `[]`와 Hub update 로그 0건을
확인했다. persistent HTTP/2 control/WAF 각 1,000건×3회에서 실패·신규 연결은 0이고 WAF
p95는 `78.090/76.286/77.373ms`, control 대비 증분은 `3.955/3.409/3.447ms`였다.
Traefik 평균 CPU 증분 `8.833m`, peak `78m`, Node CPU peak `6%`, 당시 RSS로 표기한
working set baseline/60초 idle `40/53Mi`로 기존 verifier를 통과했지만 실제 RSS는
측정하지 않았다. AppSec Pod 삭제 중 WAF fail-closed `403`·control `200`,
자동 복구 후 둘 다 `200`, Traefik UID 불변을 확인했다. 기존 ingress spec·인증서·301·
source IP·Keycloak issuer와 Node health도 회귀가 없다. 앞선 signed rollback은 영구
AppProject를 둔 finalizer prune과 HCC/Traefik 회복을 실제 입증했고 merge 후 결함은 새
FIX ID의 signed Git revert로 처리한다. 이 결과는 이후 최신 main 재검증 전의 성공 후보이며
아직 `CROWDSEC-FIX-01 DONE`을 확정하지 않는다.

POM-01·NB-02 통합 뒤 최신 main `5029d74e0dcbdb3a322b3cc5046bbc501cf0ac85`에서 전체
증거를 다시 검증했다. 기능·공급망·격리 startup은 통과했지만 WAF p95
`105.554/105.530/107.479ms`가 절대 `100ms` 기준을 모두 초과했고, 당시 RSS로 표기한
round 종료 working set도 `58/68/69Mi`로 연속 증가했다. evidence/`DONE`은 merge하지 않고 signed revert
`1315f9dc0a68fb85995b2ff8b23e725b9c7d37c5`로 enablement만 제거했다. HCC `10 → 11`,
Traefik Deployment `14 → 15`, 새 Pod ready·restart `0`과 인증서·301·source IP·Keycloak·
Pomerium 회복을 확인했다. 기존 p95 필터 오류는 branch에서 보정했고 같은 실행은 working set
monotonic 검사도 실패했지만 실제 RSS gate는 미측정이다. 따라서 `CROWDSEC-FIX-01`은 `BLOCKED`이며 `EDGE-01`도 이 작업과
`NET-04`가 남아 `BLOCKED`를 유지한다.

후속 enablement 없는 조사에서 최종 6,000개 원본 요청을 다시 계산했다. 정상 control
p95 `104.104/104.370ms`와 WAF p95 `105.554/105.530ms`의 차이는 약 `1~3ms`였고,
round3 control의 60개 spike는 10개 worker에서 같은 index에 동기 발생했다. rollback 상태의
같은 client에서도 warmed p95 `105.414/105.755/105.270ms`, ping 평균 `103.681ms`가
재현됐다. 경로는 direct endpoint가 없는 Tailscale subnet router의 Tokyo DERP relay이고
peer ping도 `99~102ms`여서 절대 p95 실패는 CrowdSec이 없는 공통 경로가 원인이다.

또한 기존 verifier의 `kubectl top` memory가 실제 RSS가 아닌 working set임을 확인했다.
당시 `58/68/69Mi`는 working set으로 재분류하며 삭제된 enabled Pod의 실제 RSS는 사후
복원할 수 없다. verifier는 kubelet `rssBytes`와 `workingSetBytes`를 별도 기록하고 route·
ping도 고정하도록 보정했다. 조사 전후 Argo/HCC/Traefik은 불변이고 enablement·재기동은
없었다. 같은 client의 read-only control p95가 `100ms` 아래로 회복되고 새 승인으로 enabled
실제 RSS를 측정하기 전까지 `CROWDSEC-FIX-01 BLOCKED`와 `EDGE-01 BLOCKED`를 유지한다.

사용자는 Tailscale DERP 공통 지연을 CrowdSec 실패에서 제외하고 추가 성능 부하 없이
기존 WAF 증분·CPU·memory 증거를 수용해 enablement와 Traefik 1회 재기동 뒤 기능·회귀만
검증하도록 승인했다. signed main enablement
`af9b5bd15baabd316772150dc12b392e612b95bf`에서 HCC `11 → 12`, Traefik Deployment
`15 → 16`, Pod UID
`dc5f3c99-9e72-40bb-8851-bfbaadee2e5c → 745d8a7d-f9e1-4fa1-8f01-d62530990d2b`로
정확히 한 번 교체됐고 image digest는 불변, restart는 `0`이다.

control·WAF 정상 `200`, rule `913100` 공격 `403`, exact URI+UA 예외 `200`, 세 negative
예외 `403`, middleware 없는 control 공격 `200`, LAPI decision `0`을 다시 확인했다.
기존 ingress object·인증서 fingerprint·path/query 보존 `301`·HTTPS `404`·source IP/XFF,
Keycloak issuer·Pomerium `302`, Node와 전체 Pod health도 정상이다. runtime Secret 원문은
Git 밖 mode `0600` 입력으로만 주입하고 즉시 파기했다. root·ingress·keycloak·pomerium·
crowdsec은 `targetRevision: main`, enablement SHA에서 모두 `Synced/Healthy`다. 따라서
`CROWDSEC-FIX-01`은 `DONE`이다. `EDGE-01`은 다른 선행 `NET-04`가 남아 `BLOCKED`를
유지한다.

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

2026-08-01 `VAULT-02`에서 Vault의 앱 소비 기반을 만들고 라이브 검증했다. KV v2, Kubernetes
auth, PostgreSQL database engine, 내부 PKI, audit device를 두고 앱별 policy로 경계를 나눴다.
Vault 내부 구성은 Argo의 대상이 아니므로 `infra/vault/scripts/configure.sh`가 재현을 소유하고
policy 원문은 Git이 소유한다.

Kubernetes auth는 Vault Pod에 만료 1시간 projected ServiceAccount token을 마운트하고
`system:auth-delegator`만 바인딩해 TokenReview를 호출하게 했다. 장기 reviewer token을
Kubernetes Secret에 두는 방식을 쓰지 않았고, 그 결과 `vault` namespace의 Secret은 계속 0건이다.
대가로 StatefulSet 변경 때 Pod가 재생성되어 수동 unseal이 필요했고 사용자가 직접 수행했다.

라이브 검증에서 바인딩된 ServiceAccount만 로그인했고 다른 SA와 다른 namespace에 바인딩된
role은 `403 service account name not authorized`였다. `keycloak` policy를 가진 token은 자기
경로만 읽었고 타 앱 경로·자기 경로 쓰기·`sys/mounts`는 모두 `403 permission denied`였다.
동적 PostgreSQL 자격증명은 k3s 안에서 `sslmode=verify-full`로 붙어 `pg_stat_ssl`이 TLSv1.3을
보고했고, `keycloak_user`만 상속하며 superuser가 아니고 다른 DB는 CONNECT 권한 없음으로
거부됐다. `sslmode=disable`은 `pg_hba.conf`가 거절했다. revoke 후 같은 자격증명은 인증에
실패했고 PostgreSQL에서 role이 실제로 사라졌다. 내부 PKI는 발급 인증서가 `openssl verify` OK,
폐기 후 CRL 등재를 확인했고 공인 zone 이름 발급은 role이 거부했다. audit은 108건이 기록되고
거부 12건도 남았으며 `client_token`은 HMAC으로 가려지고 KV 시험값 문자열은 로그에서 0건이었다.

PostgreSQL 관리 계정 `vault_admin`은 superuser가 아니라 `CREATEROLE`과 `keycloak_user`의
ADMIN OPTION만 가진다. 연결 직후 `rotate-root`로 사람이 아는 비밀번호를 폐기했다. 검증용
Pod·namespace·ServiceAccount·auth role·KV 시험값·동적 lease를 모두 제거했고 PostgreSQL에 남은
동적 role은 0개다. Vault init·unseal·seal migration·Raft 구성과 공인 인증서·공개 경로는
건드리지 않았다.

이 작업은 `gitops/root/`와 Argo `platform-root`가 실질적 공유 자원임을 드러냈다. 작업 중
다른 작업자가 `platform-root`의 targetRevision을 자기 브랜치로 고정하면서 이미 적용됐던 Vault
Pod 선언이 원복됐고, Pod가 다시 만들어져 unseal을 한 번 더 해야 했다. 그래서 GitOps 선언은
검증 전에 main으로 먼저 통합했고 `VAULT-02`는 main 커밋 두 개를 쓴다. 통합 순서 규칙은
`GIT-WF-01`이 보강했다.

남은 한계는 명시한다. Vault 내부 구성은 Argo가 동기화하지 않아 드리프트를 자동으로 잡지
못하며 `configure.sh`는 재실행 가능하지만 완전한 멱등성 도구는 아니다. TTL 만료는 revoke로
대체 검증했고 1시간 경과 관측은 포함하지 않는다. 앱이 시크릿을 받아가는 경로(Agent injector·
CSI 등)는 정하지 않았으며 `KC-01`이 결정한다. 상세는
[Vault runbook](runbook/vault-secrets-engines.md)과 [`infra/vault/README.md`](../infra/vault/README.md)가
소유한다. 선행을 다시 계산해 `KC-01`(`PG-01`·`VAULT-02`·`INGRESS-01` 충족)과
`BKP-03`(`PG-01`·`VAULT-02`·`S3-01` 충족)을 `READY`로 연다. `POM-01`은 `KC-01`이 남아
`BLOCKED`를 유지한다.

2026-08-01 `KC-01`에서 Keycloak `26.7.0` 공식 image를 digest로 고정하고 `platform` realm과
고정 issuer `https://sso.imcherry5778.xyz`를 GitOps로 배포했다. 일상 ID `imcherry`는
`/platform-users`만, 특권 ID `imcherry-admin`은 `/platform-privileged`와
`/keycloak-readers`만 가진다. `kc-verify`는 `fullScopeAllowed=false`이며 groups mapper와
`realm-management/view-users` scope만 명시했다. 실제 access token에서 일상 groups만 있고
관리 role은 0개였으며, 특권 token에는 `view-users`와 내장 composite `query-users`·
`query-groups`만 있었다. MFA 미입력은 `400 invalid_grant`, HMAC-SHA256 TOTP 입력은 200이었다.
Users API는 일상 403·특권 200, Clients API는 특권에도 403이었다.

master realm의 개인 복구 ID `imcherry-kc-recovery`는 public `kc-recovery` client의
Authorization Code + PKCE + TOTP만 사용하고 password grant·implicit·service account·client
secret은 쓰지 않는다. 이 로컬 ID로 `platform` realm을 비활성화했을 때 platform token은
`403 access_denied`였지만 master 관리 API는 200이었고, 같은 경로로 realm을 다시 활성화한 뒤
일상 token 200을 확인했다. 최초 bootstrap v1은 Agent UID 100이 만든 메모리 파일을 UID 1000
컨테이너가 지우지 못하는 결함을 라이브에서 발견해 완료 Pod를 즉시 삭제했다. 공개 main 뒤
결함이므로 별도 `KC-01-FIX-01` branch·worktree와 main 커밋으로 v2를 만들었다. v2는 두
컨테이너가 UID 1000을 쓰고 정리 실패를 exit 1로 처리하며, init/main exit 0·정리 오류 0건과
v1 prune를 확인했다.

시크릿 소비는 [ADR-0013](adr/0013-keycloak-secret-consumption.md)에 따라 cluster-wide injector,
privileged CSI DaemonSet, Kubernetes Secret 동기화 operator를 추가하지 않고 명시적 Vault Agent
init이 projected ServiceAccount token으로 자기 KV 경로만 읽어 메모리 `emptyDir`에 렌더링한다.
상시 Keycloak 컨테이너에는 ServiceAccount token이 없다. 장기 DB pool이 만료되는 동적 계정을
안전하게 다시 읽는 경로가 없어 PG-01의 고정 `keycloak_user` 암호를 KV에 두고 승인된 Pod
재생성과 함께 회전한다. 프로비저닝에서 `keycloak` DB에 `verify-full` TLSv1.3으로 접속했고
비 TLS와 `verify_db` 접속은 거부됐다. 실제 Keycloak 세션도 `keycloak_user`·TLSv1.3이었다.

OPNsense에는 기존 `k3s-01` host의 `sso` alias 한 건만 지원 API로 추가했다. 내부 A는
`10.10.20.10`, 내부 AAAA와 공개 resolver의 A·AAAA는 없고, Unbound 저장 모델·runtime·drift
없음을 확인했다. 공인 인증서는 정확한 hostname으로 TLS 1.3 검증에 성공하고 HTTP는 301로
HTTPS에 전환됐다. Argo root·Keycloak은 계속 `targetRevision: main`에서 Synced/Healthy이고
Keycloak namespace의 Secret은 0건이다. Deployment Pod 삭제 뒤 UID가 바뀐 새 Pod에서 전체
인증 검증을 반복했다. 노드 boot ID가 `2ec08a0c-0dcf-461f-acb7-7bf8bbd67695`에서
`5bbaeac3-55f3-4f22-bdd2-16618c7dc415`로 바뀐 재부팅 뒤에는 예상대로 Shamir Vault가 sealed여서
사용자 승인으로 key 원문을 출력하지 않고 stdin `sys/unseal key=-` 경로만 사용했다. Vault·
Keycloak·모든 Argo 앱이 복귀한 뒤 MFA·issuer·claim·권한·복구 ID·PostgreSQL TLS를 다시
검증했다. 최종 Keycloak 사용량은 CPU 112m·RAM 568Mi, 노드는 CPU 1%·RAM 3,493Mi(14%)였다.
Git 추적 파일과 전체 Keycloak Pod 로그의 시크릿 원문은 0건이다.

선행을 다시 계산하면 `POM-01`은 `KC-01`·`INGRESS-01`·`VAULT-02`, `NB-02`는 `NB-01`·
`KC-01`, `WG-02`는 `WG-01`·`KC-01`, `AWS-ID-01`은 `KC-01`이 모두 `DONE`이므로 이 네 직접
후속만 `READY`로 연다. `HEADLAMP-02`는 `POM-01`이 아직 `READY`라 `BLOCKED`를 유지한다.

2026-08-01 `NB-02`에서 NetBird v0.73.0의 embedded Dex 단일 IdP 제약을 확인하고 control plane을
digest 고정 management·signal·relay 이미지로 분리해 Keycloak `platform` realm에 연결했다.
Admin API는 전용 public `netbird-client`와 service `netbird-backend`, 최소 groups mapper만
선언했으며 기존 realm 객체와 bootstrap Job은 수정하지 않았다. 실제 dashboard `/nb-auth`
Authorization Code + PKCE + TOTP에서 `/platform-users` ID는 Management API 200, 비그룹 ID는
401이었다. MFA 누락, 무자격 token, 수명 300초가 지난 실제 token도 거부됐다.

일회성·1회 사용·ephemeral setup key로 v0.73.0 peer가 Management·Signal·Relay에 연결되고
overlay IP를 받은 뒤 peer·key·client state를 모두 제거했다. 전환 백업 SHA-256은
`60d779277f9540f741f286cf017bc4bca9fca56d4ea248ef16b1b96786ef8bb3`이고 세 SQLite DB
`quick_check`가 전환·재부팅 뒤에도 모두 통과했다. Keycloak과 Dex는 동시에 운용할 수 없어
로컬 Owner 복구를 백업 복원과 실제 Dex Authorization Code 로그인으로 정의했고, 두 차례
성공한 뒤 최종 상태를 Ansible role의 Keycloak OIDC로 재적용했다.

DMZ의 기존 RFC1918 BLOCK 실측에 따라 `10.10.40.10 → 10.10.20.10:443` 한 경로만 sequence
1216·logging enabled로 열었다. OPNsense 재부팅 뒤 UUID
`6bcca3bc-b23f-4713-987f-dd4c34790f8a`가 PF `@112`에 유지되고 discovery 200의 PASS 68 packets·
state 1, TCP 444 timeout의 기존 BLOCK 5 packets, drift 없음이 확인됐다. 재부팅 중 OPNsense의
단일 DNS 의존성으로 Keycloak readiness가 약 10분 9초 지연됐지만 Pod restart 없이 자동 복구된
뒤 그룹 허용·거부를 다시 통과했다. `netbird-01`만 재부팅한 뒤 unit enabled+active와 다섯
컨테이너 자동 시작, 인증 재통과, Ansible 2회차 `changed=0 failed=0`, 임시 자원·추적 파일의
secret 원문 0건을 확인했다. 외부 peer 대화형 로그인은 공개 `sso` DNS·NAT가 없어 미검증이며
`EDGE-01` 전 우회 노출하지 않는다.

2026-08-01 `WG-02`에서 Warpgate `v0.26.1`의 custom OIDC schema와 실제 관리 API를
기준으로 Keycloak 전용 confidential client·client-local full-path `groups` mapper와
`/platform-users → platform-users`, `/platform-privileged → platform-privileged` exact
mapping을 선언했다. 자동 사용자 생성과 기본 role 없이 일상·특권 SSO 사용자를 미리 만들고
공유 계정·password credential·수동 direct role은 두지 않았다. 실제 로그인 뒤에는 claim으로
동기화된 role만 남았고, 일상 ID는 일상 target만 성공·특권 target 403, 특권 ID는 특권 target만
성공·일상 target 403이었다. 잘못된 자격증명과 무그룹 경로도 거부됐으며 감사 로그에서 인증
성공·실패, 세션 시작·종료, `Target ... not authorized`를 구분했다. Terminal recording은
제품 API와 `0600 warpgate:warpgate`·`var_lib_t` 파일로 함께 확인했다.

승인된 IdP 복구 drill에서는 `platform` realm 비활성 중 SSO가 실패하는 동안 로컬 `admin`
로그인이 201이었고 master realm 복구 ID로 즉시 원복한 뒤 discovery와 SSO를 재통과했다.
Warpgate VMID 130만 재부팅해 boot ID 변경, failed unit 0, AVC 0, SELinux Enforcing, 서비스와
ACME timer 자동 시작, 기존 recording SHA-256 불변과 SSO·로컬 복구 재통과를 확인했다.
Warpgate 전용 DNS-01 인증서는 내부 service alias 한 이름만 포함하며 공개 A/AAAA·NAT는 0건,
잔여 ACME TXT도 0건이다.

승인된 `OPNSENSE-LIVE` 범위에서는 ACCESS의 `10.10.30.10 → 10.10.20.10:443/TCP` 한 경로만
기존 RFC1918 block보다 앞에 열고 `warpgate.imcherry5778.xyz → 10.10.30.10` Unbound alias
한 건만 추가했다. OPNsense 재부팅 뒤 저장 rule·alias와 PF runtime이 유지됐고 discovery 200의
PASS 598 packets, 같은 목적지 TCP 80과 다른 VLAN TCP 443 차단의 기존 BLOCK 6 packets를
같은 시점에 대조했다. 단일 DNS 의존성으로 Keycloak readiness가 약 10분 3초 지연됐지만 Pod
restart나 추가 조작 없이 복구됐고, 일상·특권 SSO와 로컬 admin을 다시 통과했다. strict 관리
TLS, sanitized drift 없음, OPNsense 테스트 18개도 통과했다.

Ansible syntax-check·check/diff·적용·2차 `changed=0`, Warpgate 재부팅 후 check `changed=0`,
최종 cleanup 적용 뒤 2차 적용과 check의 `changed=0`을 확인했다. 검증 target·known-host·임시
제품 사용자·OS 계정은 모두 0건이며 최종 운영 사용자는 `admin`, `imcherry`, `imcherry-admin`
세 명이다. 저장소 밖 비밀 18개와 tracked 파일·브랜치 blob·Warpgate journal을 exact 대조해
비밀 원문 0건, journal의 세션 marker 원문 0건, tracked recording payload 0건을 확인했다.
운영·복구 절차와 세션 정책은
[Warpgate Keycloak SSO·역할·세션 운영](runbook/warpgate-keycloak-sso.md)이 소유한다.

직접 후속 `NET-04`는 `BKP-05`·`E2E-01`이 남아 있고, `EDGE-01`은 `NET-04`가 남아 있으므로
둘 다 `BLOCKED`를 유지한다.

## 5. 데이터 보호 gate

이 단계가 끝나기 전에는 복구 불가능한 운영 데이터를 넣거나 공개 경로를 완료 처리하지 않는다. 백업 도구별 소유 범위와 오프사이트 기준은 [ADR-0005](adr/0005-backup-and-offsite-recovery.md)를 따른다.

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `BKP-01 DONE` | K3s SQLite·server token 전용 backup/restore | `K3S-01`, `S3-01` | `K3S-BOOTSTRAP` | 클러스터 복구 | 격리된 빈 VM에서 API 객체 복원; Velero와 별도임을 검증 |
| `BKP-02 DONE` | Velero + node-agent/Kopia와 local PV restore PoC | `GITOPS-01`, `STOR-01`, `S3-01` | 없음 | 모든 k3s PVC | 테스트 namespace 삭제 후 리소스·파일 복원, hostPath 제약 판정 |
| `BKP-03 DONE` | PostgreSQL native backup·Vault Raft snapshot | `PG-01`, `VAULT-02`, `S3-01` | 없음 | 인증·플랫폼 데이터 | 별도 DB/namespace에 point-in-time 또는 snapshot restore |
| `BKP-04 DONE` | SeaweedFS 로컬 S3에서 AWS S3로 오프사이트 사본 생성 | `S3-01` | 없음 | 모든 백업의 물리 장애 대응 | 별도 최소권한 자격증명과 검증한 방식으로 전송, AWS S3에서 샘플 복원, 암호화·버전·보존·실패 경보 검증 |
| `BKP-05 DONE` | 통합 재해복구 drill·RPO/RTO 기록 | `BKP-01`, `BKP-02`, `BKP-03`, `BKP-04` | `K3S-BOOTSTRAP` | 공급망·공개 전환 gate | Git+S3만으로 핵심 서비스 복구, 누락·시간·수동 절차 기록 |
| `PVE-BKP-01 DEFERRED` | 두 번째 SSD에 Proxmox VM backup | 두 번째 SSD 장착 | `PVE-LIVE` | 빠른 VM 복구 | 원본 NVMe와 다른 장치에 backup·restore; S3 앱 백업은 유지 |

2026-08-01 `BKP-02`에서 Velero 1.18.2와 AWS plugin 1.14.2를 고정 digest로,
node-agent와 내장 Kopia를 GitOps로 배포했다. CSI snapshot은 활성화하지 않았고 local-path
PVC에 명시한 filesystem backup만 사용했다. 전용 namespace `bkp-02-restore-test`와 PVC
`bkp-02-data`를 실제 삭제한 뒤 Backup `Completed`, Kopia PVB 8,388,633 bytes 처리,
Restore `Completed`, Kopia PVR 8,388,633 bytes 처리를 확인했다. marker SHA-256
`b32ae306b19b145a7729f851bb5829daa4a1a94b9ef3ee293a0235c7d13d22a4`와 8MiB payload
SHA-256 `d71a0b1d98dde113cc0e796d658154edc545c3df7670f2e74afd1f7c9db9c82f`는 원본·복원
Pod·host local-path에서 일치했고 제외 label의 ConfigMap은 복원되지 않았다.

검증 namespace·PVC·원본/복원 PV와 local directory, Backup/Restore/PVB/PVR 및 전용 Kopia
repository object는 native API와 S3 API에서 모두 부재를 확인했다. 빈 전용 bucket과
`Read/List/Write`만 가진 identity, Velero 운영 구성은 유지한다. 기존 Traefik/Vault
PVC/PV는 불변이고 Node `Ready=True`·`DiskPressure=False`, 전체 Argo Application은
`Synced/Healthy`다. credential 입력은 Git 밖 mode `0600`이며 Git과 일반 로그에 값을
남기지 않았다. 상세 증거와 rollback은
[Velero local PV backup·restore runbook](runbook/velero-local-pv-backup-restore.md)이
소유한다. 직접 후속 `BKP-05`는 `BKP-01`·`BKP-03`이 남아 `BLOCKED`를 유지하므로 새로
`READY`로 여는 작업은 없다.

2026-07-31 `BKP-04`에서 로컬 SeaweedFS S3의 AWS S3 오프사이트 경로를 만들고 검증했다.
착지점은 `infra/aws/tofu` 별도 state root가 소유하며 12개 리소스를 0 change·0 destroy로
적용했고 재-plan은 무변경이다. bucket은 public access 4종 차단, `BucketOwnerEnforced`,
SSE-S3 `AES256`, versioning `Enabled`, 구버전 30일·미완료 multipart 7일 lifecycle,
평문 HTTP 거부와 `prevent_destroy`를 갖는다. 전송은 `object-01`에서 밖으로 미는 방식이라
8333용 신규 규칙 없이 outbound 443만 쓴다. rclone 1.74.4는 release·license SHA-256으로
강제했고 그 digest가 담긴 `SHA256SUMS`의 PGP 서명을 유지자 키로 검증했다.

실제 전송으로 객체 3개 25,165,896 bytes를 옮겨 AWS 측 `AES256`·prefix 보존·version 2개를
확인했고, 원본 host도 AWS도 아닌 별도 위치에서 전송 전용 최소권한 자격증명만으로 복원해
이전 version을 포함한 4개 SHA-256이 모두 일치했다. 변경 없는 재실행은 재업로드 0이었고
24 MiB multipart 업로드도 SSE를 유지한 채 성공했다. 삭제·타 bucket·`ListAllMyBuckets`·
versioning 중단·lifecycle 삭제·타 topic·타 namespace·평문 HTTP·잘못된 secret은 모두
거부됐고 같은 시점의 허용 경로는 성공해 양성 통제를 두었다. 존재하지 않는 원본 bucket을
주입해 job 실패 → systemd `OnFailure` → SNS `Publish` 성공까지 실증했고 정상 설정 복구
후 재성공을 확인했다. Ansible은 check/diff 뒤 적용했고 2회차 `changed=0`이다. 검증
bucket·객체 version·identity·임시 파일은 모두 제거했으며 최종 `s3.json`은 disabled
sentinel 하나뿐이다.

merge 뒤 구독이 확인되어 경보 메일 수신까지 마저 검증했다. 실패를 다시 주입해 job이
`ExecMainStatus=78`로 끝나고 `OnFailure=`가 경보 unit을 새 `InvocationID`로 실행했으며,
SNS `NumberOfNotificationsDelivered`가 2·`NumberOfNotificationsFailed`가 0이었다. 임시
drop-in은 제거했고 job은 다시 성공한다.

남은 한계는 명시한다. 30일 보존 만료는 시간이 지나야 관측된다. `object-01`은 다른 작업자가
함께 쓸 수 있어 재부팅은 수행하지 않았고 timer 자동 시작은 `enabled`와 `Persistent=true`
선언으로만 확인했다. 현재 `offsite_source_buckets`는 비어 있어 사본 대상 데이터가 0이며,
이 작업이 만든 것은 검증된 경로이지 백업 자산이 아니다. 그 상태에서도 timer는 매일
heartbeat object를 써서 AWS 자격증명·네트워크·쓰기 권한을 실제로 사용하고, 부재 시
CloudWatch alarm이 울린다. 상세 증거와 rollback은
[오프사이트 백업 runbook](runbook/seaweedfs-s3-offsite-backup.md), 착지점 운영은
[AWS OpenTofu README](../infra/aws/tofu/README.md)가 소유한다. 직접 후속 `BKP-05`는
`BKP-01`·`BKP-02`·`BKP-03`이 남아 `BLOCKED`를 유지하므로 새로 `READY`로 여는 작업은 없다.

2026-08-01 `BKP-01`에서 실행 중인 k3s SQLite를 Online Backup API로 복사하고 source·사본의
`quick_check=ok`를 확인한 뒤 server token과 API proof를 GPG 암호화 archive로 묶었다. 전용
versioning bucket `bkp-01-k3s-datastore`와 그 bucket의 `Read/List/Write`만 가진 identity를
사용해 PUT·HEAD·GET hash·LIST를 검증했고, 같은 identity의 기존 `bkp-02-velero` bucket 접근은
HTTP 403이었다. 기존 BKP-02 identity는 보존하고 일회성 Admin bootstrap identity는 제거했다.
실측 volume slot이 5/5라 사용자 승인 후 기존 volume 삭제 없이 최소 한도를 6으로 늘렸고,
SeaweedFS와 backup role 최종 재적용은 각각 `changed=0`이었다.

OpenTofu state 밖의 2 vCPU·2 GiB·10 GiB 임시 VM에서 blank k3s를 만든 뒤 외부 통신과 라이브
cluster 경로를 nftables로 차단했다. token 없이 동일 DB를 복원하면 bootstrap 복호화 실패로
API가 준비되지 않았고, DB와 원본 token을 함께 복원하면 `/readyz=ok`와 SQLite
`quick_check=ok`가 됐다. 원래 `velero` Namespace, CoreDNS ConfigMap, Velero CRD,
`platform-root` Application, Velero Deployment UID가 모두 돌아왔고 Velero Restore CR은 0개였다.
node-agent가 datastore/token path를 보호하지 않는 것도 확인해 두 보호 계층을 대조했다.
양성 복원 재실행에서 UID가 불변이었으며 Ansible 선언들도 최종 `changed=0`이었다.

임시 VM·disk·주소·restore state와 object helper를 전량 제거했고 Proxmox에는 기존 5개 VM과
template만 남았다. OpenTofu 1.12.5 plan은 `No changes`, state와 network hash는 불변이었다.
라이브 k3s boot ID·PID·restart count·active timestamp가 backup 전후 같고 Node Ready, 모든 Argo
Application `Synced/Healthy`, Velero BSL `Available`, 기존 PVC/PV Bound를 재확인했다. Git 현재
파일과 전체 history의 credential·server token·private key 원문은 0건이다. 상세 증거와
rollback은 [BKP-01 runbook](runbook/k3s-sqlite-datastore-backup-restore.md)이 소유한다.
직접 후속 `BKP-05`는 `BKP-03`이 아직 `READY`라 `BLOCKED`를 유지하며 새로 여는 작업은 없다.

2026-08-01 `BKP-03`에서 PostgreSQL physical base backup과 Vault Raft snapshot을 각각 전용
SeaweedFS bucket·최소권한 identity로 매일 실행하고 최신 7세대를 보존하도록 선언했다. 두 producer는
자기 bucket의 `Read/List/Write`만 가지며 상대 bucket List/Write는 거부됐다. 오프사이트 reader는
두 bucket의 `Read/List`만 가진다. volume slot은 기존 ID를 삭제·재사용하지 않고 승인된 max 10으로
늘렸고, systemd 의존성에 따른 volume → filer → S3 연쇄 재시작 뒤 네 SeaweedFS 서비스가 active다.

PostgreSQL은 `pg_basebackup`·`pg_verifybackup`·S3 round-trip 뒤 별도 PGDATA와 Unix socket에서
복원했다. live·복원 marker SHA-256
`a16e36c7442722e6f9ec585b20e2b11525d4115ca11522d595b90f1e9009ada9`이 일치했고,
복원본 `keycloak_user` 1개·TCP listener 0개, live Keycloak DB·role 구조 불변을 확인했다. Vault는
live `vault-0`에 restore하지 않고 Service·ServiceAccount token·egress가 없는 별도 namespace의
loopback Vault에만 snapshot-force했다. 복원본 KV marker
`fd9035cd80cda74b8c6e70dfa79a8b8d575dcc8832212a9116f8b47c0fb2f85a`, Kubernetes auth role,
`keycloak` policy hash가 live와 일치했다.

두 제품 모두 8번째 생성을 통해 7세대 prune을 실증했고, freshness 실패는 새 systemd failure
InvocationID로 탐지한 뒤 정상 main/health 성공으로 복구했다. BKP-04 전송은 두 source와 AWS 사본의
본문 byte 차이 0건이었다. 최종 Ansible 재실행은 네 host 모두 `changed=0`, `failed=0`이며 임시 PG
cluster·marker와 Vault namespace·port-forward·restore input·bootstrap identity는 모두 제거됐다.
Node Ready, Argo 7/7 `Synced/Healthy`, `platform-root: main`, live Vault unsealed leader를 재확인했다.

검증 중 과거 root token이 orchestration 출력에 한 번 노출되어 사용자 승인으로 새 root token을
발급·원자 교체하고 구 accessor와 중복 snapshot token을 revoke했다. 현재 snapshot policy token은
1개다. 최종 secret scan 명령 오류로 당시 PostgreSQL S3 secret key도 출력에 한 번 노출되어 사용자
승인으로 producer credential pair를 교체했다. 구 pair는 자기 bucket에서 거부되고 새 pair는 자기
bucket 성공·Vault bucket 거부를 확인했으며 격리 파일도 제거했다. Git·대상 host journal/state log의
현재 유효한 token·secret key·unseal key 원문은 0건이다.
SeaweedFS journal에는 비밀이 아닌 access-key 식별자만 음성 시험 증거로 남고 secret key는 0건이다.
상세 절차·증거·rollback은
[PostgreSQL·Vault native backup 런북](runbook/postgres-vault-native-backup.md)이 소유한다.

직접 후속 `BKP-05`의 선행 `BKP-01`·`BKP-02`·`BKP-03`·`BKP-04`가 모두 `DONE`이고 현재
`K3S-BOOTSTRAP` 잠금 소유 작업도 없으므로 `BKP-05`만 `READY`로 연다.

2026-08-02 `BKP-05`는 Git revision `13382b46cbe2f82e8807d28b792beaa284601e53`과 AWS S3로
통합 drill을 한 번 수행했다. 시작·종료 시 Node `Ready`, Vault unsealed,
`platform-root`와 7개 child Application `Synced/Healthy`는 불변이었다. PostgreSQL
`postgres-base-20260801T171906Z.tar.gz`는 격리 Unix socket cluster에서 11초 만에
`keycloak_user` 1개·Keycloak public table 100개, TCP listener 0개로 복원됐다. 반면 AWS의
`bkp-01-k3s-datastore`와 `bkp-02-velero` prefix는 각각 0 object라 k3s datastore와 PVC
복구를 시작할 수 없었고, Vault snapshot은 있었지만 controller에 Shamir threshold key 입력이
없어 unseal·KV read 전 중단했다. 전체 RPO/RTO는 따라서 무한대이며 ADR-0005 재검토 조건에
해당한다. PostgreSQL 임시 archive·PGDATA, Vault restore namespace·port, VMID 9901의 부재를
확인했고 기존 데이터는 변경하지 않았다. 상세 RPO/RTO, 저장소 밖 입력·수동 단계·중단 지점은
[통합 재해복구 drill runbook](runbook/integrated-disaster-recovery-drill.md)이 소유한다.

## 6. 공급망과 정책

`BKP-05` 이후 실제 데이터를 가진 서비스를 늘린다. 서로 다른 앱 디렉터리는 병렬 작업할 수 있다.

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `CAP-02 DONE` | 핵심 서비스 후 남은 CPU·RAM·disk 재예산 | `BKP-05`, `HEADLAMP-02` | 없음 | 아래 전체 | Proxmox·VM·Pod 실측과 stop/go 기준 |
| `SCM-01 DONE` | Gitea | `CAP-02`, `PG-01`, `VAULT-02`, `POM-01` | 없음 | CI·Renovate | push/restore, SSO·RBAC, webhook 최소권한 |
| `REG-01 READY` | Harbor | `CAP-02`, `PG-01`, `VAULT-02`, `POM-01` | 없음 | CI·Trivy·Cosign | push/pull, robot account, retention, restore |
| `CI-01 BLOCKED` | Jenkins agent 격리와 pipeline 기준선 | `SCM-01`, `REG-01`, `VAULT-02` | 없음 | 공급망 E2E | 비밀 마스킹, 비특권 agent, 이미지 build/push |
| `QUALITY-01 READY` | SonarQube | `CAP-02`, `PG-01`, `VAULT-02`, `POM-01` | 없음 | CI quality gate | 분석·quality gate·restore·SSO |
| `AWX-01 READY` | AWX | `CAP-02`, `PG-01`, `VAULT-02`, `POM-01` | 없음 | VM 구성 자동화 | inventory·credential 격리, check/apply 승인 경계 |
| `UPDATE-01 READY` | Renovate | `SCM-01`, `VAULT-02` | 없음 | 의존성 변경 | 제한된 repo 권한, PR 생성, 자동 merge 금지 기준 |
| `SCAN-01 BLOCKED` | Trivy image/config/SBOM 검사 | `CI-01`, `REG-01` | 없음 | 서명·배포 gate | 취약점 기준·SBOM 저장·실패 pipeline |
| `SIGN-01 BLOCKED` | Cosign 서명·검증 방식 확정과 구현 | `REG-01`, `SCAN-01`, `VAULT-02` | 없음 | Kyverno | 키 소유·회전·복구, 서명·검증·거부 테스트 |
| `POL-01 DONE` | Kyverno Audit + namespace NetworkPolicy 기준선 | `GITOPS-01`, `POM-01` | 없음 | 모든 workload | 위반 report, DNS·ingress·필수 egress 회귀 없음 |
| `E2E-01 BLOCKED` | Gitea→Jenkins→Sonar→Harbor→Trivy→Cosign→Argo E2E | `CI-01`, `QUALITY-01`, `SIGN-01`, `POL-01` | 없음 | 정책 Enforce | 정상 artifact 배포와 변조·미서명 artifact 차단 |
| `POL-02 BLOCKED` | 검증된 Kyverno 정책만 Enforce | `E2E-01` | 없음 | 모든 배포 | 예외 만료, rollback, 정상 릴리스 회귀 없음 |
| `FALCO-01 BLOCKED` | Falco runtime rule·출력 기준선 | `E2E-01`, `POL-01` | 없음 | Wazuh·Shuffle | 전용 테스트 이벤트 탐지, noise 기준, 대응 runbook 초안 |

2026-08-02 `CAP-02`에서 핵심 서비스와 백업 배포가 끝난 현재값을 읽기 전용으로 재측정했다.
Proxmox는 available RAM 41.30 GiB·swap 0, thin data/metadata 3.00%/0.33%, `/` 5%,
15분 load 0.30이고 VM 5대 배정은 18 vCPU·RAM 회계 41.00 GiB·disk 572 GiB다.
각 게스트는 RAM·root 여유가 정상이며, k3s 실행 Pod 22개 합계는 67m·2,068 MiB,
Node는 173m·4,426 MiB, PVC 요청은 5.125 GiB다. 모든 stop 기준에 여유가 있어
`SCM-01`·`REG-01`·`QUALITY-01`·`AWX-01` 진입은 `GO`로 판정한다. 추가 Pod에서 먼저
접근할 가능성이 큰 경계는 `k3s-01` RAM이며 12 GiB 경고까지 7.58 GiB가 남았다.
CAP-02의 모든 직접 후속은 다른 선행도 `DONE`이므로 네 작업만 `READY`로 연다.

2026-08-02 `SCM-01`에서 Gitea `v1.27.1` 공식 rootless image index digest와 Vault Agent를
고정해 전용 AppProject·child Application·namespace에 배포했다. 관계형 데이터는
`postgres-01`의 전용 `gitea` DB와 최소권한 `gitea_user`가 소유하고
`sslmode=verify-full`로 연결한다. Kubernetes Secret 없이 projected
`audience=vault` ServiceAccount token과 memory `emptyDir`을 쓰는 명시적 Vault Agent init만
사용하며, 승인된 외부 mode `0600` 입력에서 잘못된 JWT secret 한 필드만 교체했다. UI는
Pomerium `claim/groups=/platform-users` Route와 Gitea Keycloak required claim을 모두 통과해야
하고, HTTP Git은 끈 채 Git data를 내부 DNS `git.imcherry5778.xyz`의 SSH NodePort 30022로
분리했다. Pomerium에서 Gitea server TCP 3000으로 향하는 egress만 NetworkPolicy로 추가했으며
공개 DNS·NAT·방화벽·Traefik 설정은 바꾸지 않았다.

실제 `scm-recovery/platform-smoke` repo에 SSH push한 commit
`fb854e4b004540ae3352c7d9331243a29b33883d`를 앱 수준 DB dump와 repository data로 별도
`gitea_scm01_restore` DB·`scm01-restore` PVC·Ingress 없는 Pod에 복원해 같은 SHA를 조회했고
임시 key·DB·PVC·Pod를 제거했다. 같은 실행에서 `imcherry` OIDC Dashboard 성공과
`imcherry-admin` Pomerium 403을 대조했으며, Gitea admin-only 목록의 `scm-recovery`는 Keycloak
platform realm 비활성 중 로컬 Dashboard session 로그인에 성공했다. repo 범위 hook은 올바른
HMAC 전달 204와 별도 wrong-secret hook의 receiver 403을 확인한 뒤 두 hook·receiver를 제거했다.
최종 배포 직후 Node는 `136m`·`5962Mi`, metrics Pod 25개 합계는 `92m`·`2943Mi`, k3s guest
`available`은 `17,801MiB`, PVC 요청 합계는 4개 `15.125GiB`였다. RAM 12/8GiB와 PVC
96/120GiB 경고/정지 기준에 들어가지 않아 다음 배포는 **GO**다. 검증 설정 SHA
`cad5f1c0fe332bf16488e796f2318837e341a33b`와 root pointer
`72b35d4ae49914ae3a68fa9cd8b81df518ae768d`에서 세 Application이 `Synced/Healthy`였고,
시작 main `35614f401bcb4bcc2847fa1b5623e7335047a7e3`로 rollback해 root·Pomerium의
`Synced/Healthy`와 Gitea workload/PVC orphan 보전을 확인했다. 최종 child 선언은 `main`이다.
직접 후속은 `SCM-01`·`VAULT-02`가 모두 끝난 `UPDATE-01`만 `READY`로 열고,
`CI-01`은 `REG-01`이 남아 `BLOCKED`를 유지한다.

2026-08-02 `POL-01`에서 Kyverno `v1.18.2` admission·reports controller와 Pod-level
`runAsNonRoot` 누락 Audit 규칙 한 건을 배포했고, 기존 워크로드 위반이 PolicyReport의 `fail`로
남는 것을 확인했다. k3s Flannel과 내장 kube-router가 `KUBE-NWPLCY`·`KUBE-POD-FW` 체인을
설치해 NetworkPolicy를 실제 강제하므로 통신표가 명확한 `pomerium` namespace에만 default-deny와
DNS·Traefik·Dashy·Vault·Headlamp·기존 HTTPS 허용 기준선을 적용했다. 선택 대상 검증 Pod에서
클러스터 DNS와 Vault·Headlamp·SSO HTTPS egress가 모두 성공했고, 기존 보호 route는 Pomerium
sign-in으로 `302` 응답했다. 검증 SHA의 `platform-root`와 두 child는 모두 `Synced/Healthy`였다.
Git에 선언한 Secret은 0건이며 admission webhook이 자체 관리하는 TLS CA·leaf Secret 두 개만
라이브에 존재한다. 시작 main `930fc672e81e1b376402d8ca2edbb84c21b30db3`로 순서 있게 rollback해
정책·NetworkPolicy·controller·CRD·동적 webhook을 제거하고 root를 `main`의 `Synced/Healthy`로
복구했다. `E2E-01`은 `CI-01`·`QUALITY-01`·`SIGN-01`이 남고 `FALCO-01`은 `E2E-01`이 남으므로
둘 다 `BLOCKED`를 유지하며 새로 여는 직접 후속은 없다.

## 7. 최소권한과 공개 경로

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `NET-04 BLOCKED` | 실제 통신표로 VLAN 규칙 최소화·hardened 검증 | `NB-02`, `WG-02`, `POM-01`, `BKP-05`, `E2E-01` | `OPNSENSE-LIVE` | 외부 공개·운영 통신 | 임시 rule 제거, `vlan-verify hardened`, drift 없음 |
| `EDGE-01 BLOCKED` | Cloudflare WAF·origin 제한·공개 DNS/NAT | `CROWDSEC-FIX-01`, `POM-01`, `NB-02`, `NIDS-01`, `NET-04` | `PUBLIC-DNS`, `OPNSENSE-LIVE` | 외부 사용자 | 허용 hostname만 공개, origin 직접 우회 차단, IDS 경보·복구 경로 독립 |
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
| `AUDIT-01 BLOCKED` | Suricata·CrowdSec AppSec(Coraza/CRS)·Falco·Kubernetes·Vault·Keycloak·Pomerium·접근 서비스 이벤트 분류 | `EDGE-01`, `POL-02`, `FALCO-01` | 없음 | Loki·Wazuh | 보안/운영 경계, 시각·사용자·요청 ID, 마스킹, 보존 기준 |
| `LOKI-01 BLOCKED` | Alloy·Loki와 제한된 운영 로그 수집 | `AUDIT-01` | `K3S-HEAVY` | Grafana | 보안 이벤트의 Wazuh 중복 저장 없음, label cardinality·retention·disk 상한 |
| `OBS-01 BLOCKED` | kube-prometheus-stack·Alertmanager·Grafana | `LOKI-01` | `K3S-HEAVY` | 운영 경보·Wazuh·Shuffle | node/PVC/backup/cert·OPNsense·수집 파이프라인 지표, 실제 경보 전달, disk 상한 |
| `WAZUH-01 BLOCKED` | Wazuh 배치·보안 소스 직접 수집·규칙 PoC | `AUDIT-01`, `OBS-01`, `FALCO-01`, `NIDS-01` | `K3S-HEAVY` | Shuffle | Suricata 등 대표 이벤트의 직접 탐지·검색·retention, Loki relay 없음, active response 비활성, 오탐·용량 gate |

## 10. 마지막 단계: Shuffle

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `SOAR-01 BLOCKED` | Shuffle read-only·사람 승인형 SOAR PoC | `OBS-01`, `WAZUH-01`, `FALCO-01` | `K3S-HEAVY` | 사고대응 | 경보 수신→정보 보강→통지→승인 흐름, 최소권한 credential |
| `SOAR-02 DEFERRED` | 되돌릴 수 있는 대응 한 가지 자동화 | `SOAR-01`, 검증된 incident runbook | 없음 | 접근 정책 | 반복 시험, 승인·감사·rollback; 방화벽·계정 무인 파괴 금지 |

Shuffle은 Jenkins·Argo CD·AWX의 배포 자동화를 대체하지 않는다. 보안 사건에 반응하는 흐름만 소유한다.
