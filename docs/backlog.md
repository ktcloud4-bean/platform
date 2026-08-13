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
| `VAULT-CONFIG` | Vault 내부 구성(secrets engine·auth role·policy·PKI role)의 변경 |
| `PUBLIC-DNS` | Cloudflare DNS·공개 origin 변경 |
| `K3S-HEAVY` | Wazuh·관측·SOAR처럼 큰 워크로드의 최초 적용 |
| `IDENTITY-LIVE` | Keycloak 사용자·그룹·client role과 서비스 OIDC 사용자·조직·role의 전환 |
| `NETBIRD-LIVE` | NetBird account·peer·group·policy·route·DNS와 setup key의 변경 |

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
EDGE-01 + KC-01 + NB-02 + IAM-01 → EDGE-DESIGN-02 → EDGE-02
→ NB-ENROLL-01 → IAM-ENROLL-01 → IAM-MIG-01

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
| `AWS-STATE-RECOVERY-01 DONE` | 유실된 AWS 오프사이트·VPN legacy root state를 실물 import로 복구하고 S3 backend로 이전 | `AWS-NET-01`, `BKP-04` | `TOFU-STATE` | AWS 오프사이트 백업·사설 연동의 후속 변경 안전성 | 오프사이트 12개·VPN 10개 import, provider import 불가 static VPN route 한 개만 승인 아래 재생성, 두 root 무변경 plan, 상태 S3 두 key의 version 확인, 복구 사본 mode 0600, 비밀 원문·PSK·access key 미출력 |

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

2026-08-10 `AWS-STATE-RECOVERY-01`은 유실된 local state와 비어 있는 state S3 key를 확인한
뒤, 오프사이트 root 12개와 VPN root 10개의 실물 소유권을 별도 mode `0600` 복구 state에
import했다. AWS provider가 static VPN route import를 지원하지 않아 승인 아래 기존 route 하나를
삭제하고 같은 OpenTofu 선언으로 즉시 재생성했다. 이외 AWS 리소스의 create·update·destroy는
없었다. 두 root는 서로 다른 S3 state key로 이전됐고 각 key는 version 1개, DynamoDB에는
state checksum 2개와 active lock 0개가 남았다. remote backend `validate`와 normal plan은 두 root
모두 무변경이며, raw state·PSK·access key·plan 원문은 Git과 Jenkins log에 남기지 않았다. 상태
경계와 대안은 [ADR-0020](adr/0020-aws-opentofu-state-recovery-backend.md)이 소유한다.

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
| `CERTMGR-01 DONE` | cert-manager 도입과 Vault PKI를 CA로 쓰는 Issuer 연결 (`gitops/apps/cert-manager/`) | `VAULT-02`, `WAZUH-01` | `VAULT-CONFIG` | `PKI-01`, 내부 인증서 자동화 | 고정 version·image digest·CRD 선언과 Argo child `Synced/Healthy`, cert-manager 전용 Kubernetes auth role·policy가 자기 PKI role로만 발급하고 타 경로는 403, 시험 Certificate 한 장의 발급·Secret 생성·chain 검증과 즉시 제거, 단축 `renewBefore`로 자동 갱신 실증, Vault sealed 상태에서 기존 인증서 유효·신규 발급만 실패, 배포 전후 available RAM·PVC 정지선 통과, Argo revert rollback 뒤 기존 워크로드 회귀 없음 |
| `PKI-01 DONE` | Vault PKI를 첫 실제 consumer인 CrowdSec agent↔LAPI mTLS lifecycle에 연결 | `VAULT-02`, `CERTMGR-01` | `VAULT-CONFIG` | 내부 서비스 인증·인가 | CrowdSec 전용 최소권한 PKI role과 허용 밖 이름·OU 거부, agent↔LAPI mTLS 실제 연결 성공과 잘못된 CA·OU 거부, LAPI의 OU 기반 agent/bouncer 구분 보존, 자동 갱신·reload, revoke 뒤 CRL 등재와 해당 인증서 거부, Vault sealed 중 기존 인증서 유지·신규 발급만 실패, Git·로그의 private key 0건, `tls.enabled=false` rollback 뒤 `CROWDSEC-FIX-01` 기능(정상 200·공격 403·exact 예외) 회귀 없음 |
| `KC-01 DONE` | Keycloak 배포·realm·그룹/client role·일상/특권 ID | `PG-01`, `VAULT-02`, `INGRESS-01` | 없음 | Pomerium·Headlamp·NetBird·Warpgate·AWS | MFA, claim, 최소 role, 로컬 admin 복구, issuer 고정 |
| `KC-01-FIX-01 DONE` | bootstrap 메모리 시크릿 정리를 fail-closed로 보정 | `KC-01` 배포 선언 | 없음 | Keycloak bootstrap | Agent/bootstrap 동일 UID, 렌더링 파일 정리 실패 시 Job 실패, v1 prune·v2 성공 |
| `IAM-01 DONE` | GitHub username 기준 팀 Keycloak 계정과 Shuffle OIDC·조직·RBAC, Pomerium Route 최소권한 전환 | `KC-01`, `POM-01`, `SOAR-DASH-01` | `IDENTITY-LIVE` | `NB-ENROLL-01` | 팀 일상 ID 5개와 분리 특권 ID 1개 생성·MFA required action, 보호 입력으로만 받은 검증 email과 Git·로그 추가 원문 0건, 그룹→Shuffle client role 정확 매핑과 대표 세션 한 role, 단일 조직의 reader 쓰기·실행 거부와 admin 허용, role 없는 OIDC 거부, Pomerium 그룹 allow/deny, MFA를 갖춘 `soar-dash-01-admin`의 IdP 독립 복구와 API key 0개, 임시 자동 프로비저닝 종료, 관련 Argo child `Synced/Healthy` |
| `IAM-01-FIX-01 DONE` | `provision.py`의 "특권 ID는 email 없음·duplicateEmailsAllowed=false" 가정이 라이브 realm과 어긋나 특권 ID 로그인이 Update Account Information에 막히던 결함을 보정 | `IAM-01` | `IDENTITY-LIVE` | `IAM-ENROLL-01` | 라이브 realm 조회로 `duplicateEmailsAllowed=true` 확인, 특권 ID의 email 필드를 비웠더니 실제 브라우저 로그인이 필수 프로필 입력 화면에 막히는 것을 재현, `ensure_users`에서 특권 ID의 email 값 자체를 검증하지 않도록 완화(daily ID 5개의 email 일치·verified 요구는 불변), 라이브 데이터 변경 없이 `provision.py check` 재통과(`KeycloakIAM=PASS users=6/6`) 확인 |
| `IAM-ENROLL-01 DONE` | 팀 일상 ID 5개와 분리 특권 ID 1개의 사용자 직접 초기 비밀번호 변경·MFA·Shuffle 최초 OIDC 등록 | `IAM-01`, `NB-ENROLL-01` | `IDENTITY-LIVE` | `IAM-MIG-01`, `SOAR-01` | `registration-open`으로 통제된 등록 창을 열어 여섯 사용자 전원이 NetBird 경유 Keycloak 로그인으로 임시 비밀번호 변경·TOTP 등록을 직접 완료하고 Shuffle SSO 최초 로그인으로 자기 계정을 생성한 뒤 `registration-close`로 검증·마감; `provision.py registration-close` 라이브 재통과로 `KeycloakIAM=PASS users=6/6 mfa_active=6/6`과 `ShuffleIAM=PASS oidc=configured auto_provision=off` 확인, 여섯 계정 `requiredActions` 개별 조회로 required action 0건 확인, `registration-close`의 role 대조 통과로 일상 `org-reader` 5개·특권 `admin` 1개 정확히 한 role 확인, 등록 창 마감 직후 `auto_provision=off` 복귀 확인, 검증 출력·본 세션에 계정 credential·TOTP seed 원문 미노출(Git 변경분은 문서 상태 갱신만) |
| `IAM-MIG-01 DONE` | 기존 `imcherry`·`imcherry-admin`의 서비스별 OIDC 연결·소유권을 새 ID로 이전하고 legacy ID를 단계적으로 비활성화 | `IAM-ENROLL-01` | `IDENTITY-LIVE` | legacy identity 정리 | Keycloak client 11개(참여 client·group·role-mapping 전수 조회)와 각 서비스의 group-gated·persistent-ownership 분류표, NetBird Owner를 `imcherry5778-admin`으로 실이전(legacy `imcherry`는 자동 `admin`으로 강등), Warpgate·AWX 선언형 legacy username을 새 ID로 교체하고 라이브 재적용, legacy `imcherry`(세션 6개)·`imcherry-admin`(세션 2개) session revoke와 `enabled:false` 전환 뒤 동일 자격증명 재로그인 시도가 "Account is disabled"로 즉시 거부됨을 Warpgate·NetBird 양쪽에서 실측, Keycloak DR bootstrap ConfigMap의 legacy `enabled` 값도 `false`로 맞춰 재해복구 시 되살아남 방지, hard delete 0건과 rollback 절차(계정 재활성화 API 호출만으로 원복) |
| `IAM-MIG-01-FIX-01 DONE` | `IAM-MIG-01`이 범위 밖으로 남긴 Gitea legacy 로컬 계정 `imcherry`를 정리해 `imcherry5778` Keycloak SSO 로그인 500 오류를 해소 | `IAM-MIG-01` | `IDENTITY-LIVE` | Gitea SSO 로그인 | `postgres-01`의 Gitea DB에서 `imcherry`(uid 2)의 `repository`·`collaboration`·`org_user`·`access` 레코드가 전부 0건임을 직접 질의로 확인, `kubectl exec`로 Gitea Pod 안에서 `gitea admin user delete --id 2 --purge` 실행 뒤 `gitea admin user list`로 계정 소멸 확인, `imcherry-admin`은 애초에 Gitea 로컬 계정이 없어 대상 아님, Gitea 라이브 로그에 오류 없음(healthz 정상) |
| `IAM-MIG-01-FIX-02 DONE` | `ktcloud4-bean` 조직에 팀 daily 계정 read-only 접근을 부여하고, `BOARD-DEMO-02`가 지우지 못했던 `board-app` 저장소를 제거 | `IAM-MIG-01-FIX-01`, `BOARD-DEMO-02` | `IDENTITY-LIVE` | 팀 저장소 열람 | `ktcloud4-bean` 조직 멤버가 `scm-recovery`(Owners) 한 명뿐이라 팀 daily 계정이 `hr-system`을 못 보던 것을 라이브로 확인; `gitea admin user generate-access-token`으로 발급한 범위 한정(`write:organization,write:user`) 임시 토큰으로 read-only `Members` 팀(`repo.code`·`issues`·`pulls`·`releases`·`wiki` 전부 read, `can_create_org_repo:false`, `Owners` 권한 없음)을 신설해 `foxgeun`·`jaeeyun`·`cerberos2022`·`imcherry5778` 4명을 추가하고 라이브 `team_user` 조회로 확인; 같은 방식(`write:repository` 범위 토큰)으로 `ktcloud4-bean/board-app`을 삭제(삭제 전 200 → 삭제 후 404, 최종 저장소는 `hr-system`과 `scm-recovery`의 스모크테스트 2개뿐임을 확인), 두 임시 토큰 모두 사용 직후 DB에서 삭제해 잔존 0건; `imcherry5778-admin`·`snsd-hybirdinfra`는 Gitea 로그인 이력이 없어 팀 추가 대상에서 제외 |
| `WAF-DESIGN-01 DONE` | 실패한 direct Coraza connector를 폐기하고 CrowdSec AppSec 전환 경계 결정 | `INGRESS-01` | 없음 | `CORAZA-01`, `CROWDSEC-01`, `CROWDSEC-PERF-01`, `CROWDSEC-FIX-01`, `EDGE-01`, `AUDIT-01` | 새 ADR·목표 아키텍처·의존성 정합성, 실패 재현 자산의 비활성 evidence 격리, 라이브 변경 0 |
| `CORAZA-01 DEFERRED` | Traefik HTTP-WASM Coraza + CRS 직접 PoC; 호환 실패로 폐기하고 `CROWDSEC-01`이 대체 | `INGRESS-01` | 없음 | 없음 | 재실행하지 않음; [ADR-0012](adr/0012-crowdsec-appsec-origin-waf.md)의 재검토 조건이 생기면 새 결정·새 작업으로만 검토 |
| `CROWDSEC-01 DEFERRED` | CrowdSec AppSec(Coraza + OWASP CRS) route-scoped PoC 최초 시도; CRS ConfigMap 바이트 훼손과 AppProject prune 순서 결함으로 revert | `INGRESS-01`, `WAF-DESIGN-01` | 없음 | `CROWDSEC-FIX-01` | 공개 main enablement와 rollback 이력을 재작성하지 않음; [실패 증거](evidence/crowdsec-fix-01/README.md)를 기준으로 FIX에서만 보정 |
| `CROWDSEC-PERF-01 DONE` | rollback 상태에서 CrowdSec 성능 실패의 client/DNS/TCP/TLS 측정 경로를 분리하고 warm-up 계약 보정 | `INGRESS-01`, `WAF-DESIGN-01` | 없음 | `CROWDSEC-FIX-01` | read-only 1,000건 cold 대조, concurrency 10 지속 HTTP/2 1,000건×3회, 신규 연결·실패 0, 라이브 Argo/HCC/Traefik 불변, ADR 기준값 미완화 |
| `CROWDSEC-FIX-01 DONE` | byte-preserving CRS snapshot·offline AppSec startup·API round-trip·영구 AppProject로 CrowdSec AppSec route-scoped PoC 보정 | `INGRESS-01`, `WAF-DESIGN-01`, `CROWDSEC-PERF-01` | `TRAEFIK-LIVE` | 공개 HTTP·`EDGE-01` | immutable 공급망·49개 byte hash·3.7.4 격리 호환, route 200/403·exact 예외·control·decision 0, WAF 증분 1~3ms와 Tailscale 외생 지연 분리, working set 잔류 10Mi·verifier RSS 보정, fail-closed·rollback·단일 재기동·기존 ingress 회귀 없음 |
| `POM-01 DONE` | Pomerium Core·선언형 Route·Dashy Portal | `KC-01`, `INGRESS-01`, `VAULT-02` | 없음(단, 내부 DNS 적용은 실제 `OPNSENSE-LIVE` 승인 필요) | 내부 웹 접근 | groups claim 허용/차단, Portal 표시, Keycloak 장애 시 독립 복구 경로 |
| `POM-01-FIX-01 DONE` | Jenkins·Argo CD·Grafana·Prometheus·Alertmanager·Wazuh·Shuffle이 이후 각자 배포되며 Dashy에 타일이 추가되지 않아 팀원이 포털에서 발견할 수 없던 gap을 보정 | `POM-01` | 없음 | 팀원 포털 발견성 | 7개 타일을 각 서비스의 실제 Pomerium Route `claim/groups` allow 조건과 정확히 같은 `showForGroups`로 추가(Wazuh·Shuffle은 `/platform-users` 제외), Vault는 설계상 Pomerium·Dashy를 거치지 않는 독립 복구 경로라 제외, YAML 유효성 확인, Argo `platform-root` 자동 동기화 뒤 실제 포털에서 새 타일 노출 확인 |
| `POM-01-FIX-02 DONE` | 실사용자 포털에 노출될 이유가 없던 헬스체크 타일 제거와, Dashy 기본 Font Awesome kit이 지원하지 않는 아이콘(Harbor·SonarQube·Shuffle, 일부는 `POM-01-FIX-01` 이전부터 존재)을 지원 아이콘으로 교체 | `POM-01-FIX-01` | 없음 | 포털 UX | `POM-01 보호 Route` 타일 제거(Pomerium route 자체는 유지, health-check 용도로 계속 사용 가능), `fa-boxes-stacked`→`fa-box`, `fa-magnifying-glass-chart`→`fa-search`, `fa-shuffle`→`fa-random`로 교체(Dashy 기본 kit이 FA6 신규 아이콘 일부를 지원하지 않는 것이 원인), YAML 유효성 확인 |
| `POM-01-FIX-03 DONE` | 범용 Font Awesome 아이콘 대신 실제 공식 브랜드 로고·색상을 쓰도록 Gitea·Harbor·SonarQube·Jenkins·Argo CD·Grafana·Prometheus 7개 타일을 Dashy `si-`(simple-icons, npm 번들·오프라인)와 항목별 `color`로 교체 | `POM-01-FIX-02` | 없음 | 포털 UX | simple-icons 데이터셋 조회로 실제 slug·공식 hex 확인 후 `si-gitea`·`si-harbor`·`si-sonarqubeserver`·`si-jenkins`·`si-argo`·`si-grafana`·`si-prometheus` + 해당 공식 hex `color` 적용, AWX·Alertmanager·Wazuh·Shuffle·Headlamp는 simple-icons에 공식 로고가 없음을 확인해 기존 범용 아이콘 유지, YAML 유효성 확인 |
| `POM-01-FIX-04 DONE` | simple-icons 유무와 무관하게 모든 타일을 각 서비스 자신이 제공하는 실제 favicon(`favicon-local`)으로 통일 | `POM-01-FIX-03` | 없음 | 포털 UX | 12개 타일 전부 `icon: favicon-local`로 교체하고 `si-`·`color`·범용 Font Awesome 값 제거, YAML 유효성 확인; 실기기 확인 결과 Headlamp·Gitea·AWX·Harbor·SonarQube·Jenkins·Alertmanager·Shuffle 8개는 정상 렌더링, Argo CD·Grafana·Prometheus 3개는 자체 앱 로그인이 `/favicon.ico`까지 가로채 깨짐(`POM-01-FIX-05`가 보정) |
| `POM-01-FIX-05 DONE` | Argo CD·Grafana·Prometheus는 자체 앱 로그인이 `/favicon.ico`를 가로채 `favicon-local`이 깨지는 것을 실기기로 확인해, 이 3개만 `POM-01-FIX-03`의 simple-icons(`si-argo`·`si-grafana`·`si-prometheus`)로 되돌림 | `POM-01-FIX-04` | 없음 | 포털 UX | 나머지 9개(Wazuh 포함)는 `favicon-local` 유지, YAML 유효성 확인; Wazuh는 특권 계정에서 아직 직접 확인 안 됨(같은 자체 로그인 인터셉트 가능성 있음) |
| `POM-01-FIX-06 DONE` | Dashy 포털을 Minimal 뷰로 고정(`startingView`)하고 텍스트 색을 흰색으로 통일(`customCss`) | `POM-01-FIX-05` | 없음 | 포털 UX | `appConfig.startingView: minimal`로 `/`가 바로 minimal 레이아웃, `customCss`로 body·heading·tile 제목/설명/URL·input만 `#fff`로 강제(아이콘 `color`·`fill: currentColor`는 건드리지 않도록 아이콘 클래스 제외), YAML 유효성 확인, 실기기에서 minimal 고정·흰색 텍스트 확인 |
| `POM-01-FIX-07 DONE` | Gitea·SonarQube·Jenkins도 자체 로그인 세션 상태에 따라 `favicon-local`이 간헐적으로 깨지는 것을 실기기로 재확인해, 세션과 무관하게 안정적인 simple-icons로 되돌림 | `POM-01-FIX-06` | 없음 | 포털 UX 안정성 | `si-gitea`·`si-sonarqubeserver`·`si-jenkins` + 공식 hex로 교체, YAML 유효성 확인; `favicon-local`은 Headlamp·AWX·Harbor·Alertmanager·Shuffle 5개만 유지(반복 확인에서 안정적으로 렌더링됨), Wazuh는 여전히 미확인 |
| `POM-01-FIX-08 DONE` | `POM-01-FIX-05`/`07`에서 미확인으로 남은 Wazuh `favicon-local` 위험이 특권 계정 실사용에서 실제로 깨진 것을 확인하고, Argo CD·Grafana·Prometheus·Gitea·SonarQube·Jenkins와 같은 원인(자체 로그인이 `/favicon.ico` 가로챔)으로 판정해 보정 | `POM-01-FIX-07` | `ARGO-ROOT` | 포털 UX 안정성 | Wazuh는 simple-icons에 공식 로고가 없음(`POM-01-FIX-03`에서 이미 확인, 재검증 생략)을 근거로 `POM-01-FIX-04` 이전 값 `fas fa-binoculars`로 복귀, YAML·kustomize build 유효성 확인, `ARGO-ROOT` 잠금 아래 `platform-root`·`pomerium`을 커밋 SHA `7db26cf4`로 전환해 `pomerium` Synced/Healthy와 라이브 ConfigMap의 Wazuh `icon: fas fa-binoculars` 반영, 새 ConfigMap hash로 Dashy Pod 재기동 확인; 검증 뒤 두 Application을 `main`·selfHeal 원상복구, 아이콘 클래스 자체는 `POM-01-FIX-01`~`FIX-04` 구간에서 이미 렌더링 검증된 값이라 브라우저 재확인은 생략(같은 경계 중복 검증 금지) |
| `HEADLAMP-02 DONE` | Headlamp Keycloak OIDC·Kubernetes RBAC·Pomerium Route | `HEADLAMP-01`, `POM-01` | `K3S-BOOTSTRAP` | k3s 일상 관리·`CAP-02` | 공유 cluster-admin SA 없음, 사용자별 조회·로그·exec·변경 allow/deny, bootstrap token 폐기, GitOps drift 없음, IdP 장애 시 break-glass kubeconfig |
| `HEADLAMP-02-FIX-05 DONE` | Headlamp v0.44.0의 `/clusters/main` HttpOnly cookie 경계에 맞게 browser verifier를 보정하고 HEADLAMP-02 전체 경계를 재도입 | `HEADLAMP-01`, `POM-01` | `K3S-BOOTSTRAP` | k3s 일상 관리·`CAP-02` | cookie path 회귀 테스트, 사용자 OIDC·RBAC 전체 live·rollback·break-glass 재검증 |
| `NB-02 DONE` | NetBird 일반 인증을 Keycloak OIDC로 전환 | `NB-01`, `KC-01` | 없음 | 원격 사용자 | 신규 OIDC 로그인·그룹 정책과 로컬 Owner 복구 모두 성공 |
| `NB-02-FIX-01 DONE` | NetBird dashboard `AUTH_REDIRECT_URI`·`AUTH_SILENT_REDIRECT_URI`가 절대 URL로 선언되어 dashboard origin과 중복 결합(`Invalid parameter: redirect_uri`)되던 결함을 경로 전용 값으로 보정 | `NB-02` | 없음 | NetBird 로그인 화면 진입 | `EDGE-02` 외부 검증 중 실제 재현·원인 특정(`netbird-01`의 dashboard가 자기 origin과 env 값을 이어붙임); 템플릿 소스만 경로(`/nb-auth`, `/nb-silent-auth`)로 수정, 라이브 `netbird-01` 컨테이너 재적용은 다음 `netbird_server` role 적용 때 반영 |
| `NB-02-FIX-02 DONE` | NetBird dashboard가 `netbird-client`에 없는 `groups` scope를 `AUTH_SUPPORTED_SCOPES`에 요청해 Keycloak이 `invalid_scope`로 거부하던 결함을 보정 | `NB-02-FIX-01` | 없음 | NetBird 로그인 화면 진입 | Keycloak Admin API로 `netbird-client`가 `groups`를 default/optional scope 어디에도 갖지 않고 dedicated `oidc-group-membership-mapper`로 scope 요청과 무관하게 groups claim을 이미 전달함을 확인; `AUTH_SUPPORTED_SCOPES`에서 `groups` 제거해 템플릿·라이브 `netbird-01` 컨테이너 모두 반영, 재로그인으로 통과 확인 |
| `NB-02-FIX-03 DONE` | NetBird management의 Device Authorization·PKCE flow 설정에도 같은 존재하지 않는 `groups` scope가 남아 있어 실제 `netbird` CLI client 로그인이 `invalid_scope`로 실패하던 결함을 보정 | `NB-02-FIX-02` | 없음 | NetBird CLI/device 로그인 | `management.json.j2`의 `DeviceAuthorizationFlow`·`PKCEAuthorizationFlow` 두 `Scope` 값에서 `groups` 제거, 템플릿과 라이브 `netbird-01`의 `management.json`·`netbird-management` 컨테이너 모두 반영 |
| `NB-02-FIX-04 DONE` | `netbird-client`의 `post.logout.redirect.uris`가 Keycloak 와일드카드가 아닌 리터럴 `+` 문자로 등록되어 정상 로그아웃 redirect가 전부 `Invalid redirect uri`로 거부되던 결함을 보정 | `NB-02-FIX-03` | 없음 | NetBird 로그아웃 흐름 | Keycloak Admin API로 값을 `{dashboard_url}/+`(리터럴 일치만 허용)에서 `{dashboard_url}/*`(정상 wildcard)로 교체, slash 유무 두 형태 재현 테스트로 400→302 전환 확인, 소스 스크립트 `keycloak_netbird_clients.py`도 동일하게 반영 |
| `NB-ENROLL-01 DONE` | 기존 Keycloak 일상 ID의 외부 NetBird interactive onboarding과 일반 사용자 device group·split DNS·exact ingress route·offboarding | `EDGE-02`, `IAM-01`, `NB-02`, `NET-04`, `POM-01` | `NETBIRD-LIVE` | `IAM-ENROLL-01` | 랩 밖 신규 client가 `/platform-users` ID·MFA로 사용자 소유 peer를 만들고 내부 DNS와 ingress HTTPS exact route로 `access`에 도달, 미소속·특권 전용 ID와 허용 밖 목적지·port 거부, 사람용 setup key 0건, session revoke·사용자 차단·peer 삭제 뒤 재접근 거부와 임시 자원 0건 |
| `NB-ENROLL-01-FIX-01 DONE` | `/platform-users` NetBird DNS Nameserver Group의 domain 범위를 `access.imcherry5778.xyz` 단일 이름에서 `imcherry5778.xyz` 전체 zone으로 확장해, Pomerium `authenticate_service_url`(`k3s-01.imcherry5778.xyz`)이 NetBird 전용 client에서 해석되지 않아 모든 서비스 로그인 리다이렉트가 실패하던 결함을 보정 | `NB-ENROLL-01` | `NETBIRD-LIVE` | `IAM-ENROLL-01` | NetBird Nameserver Group `NB-ENROLL-01 access split DNS`의 domain을 `imcherry5778.xyz`로 교체, `netbird-01` dnsmasq relay가 이미 zone 전체를 서빙함을 직접 질의로 확인, Tailscale 없이 NetBird 단독 경로에서 `k3s-01`·`sso`·`shuffle`·`access` 등 대표 이름이 모두 해석되고 `curl access.imcherry5778.xyz` HTTP 302 유지, 새 exact route·정책·group 추가 없음(기존 Resource·정책 재사용) |
| `WG-02 DONE` | Warpgate SSO·역할·세션 정책 연동 | `WG-01`, `KC-01` | `OPNSENSE-LIVE`, `PUBLIC-DNS` | 관리자 접근 | 일반/특권 분리, 허용 대상만 접속, IdP 장애 복구 검증 |
| `WG-03 DONE` | Warpgate의 실제 운영 SSH 대상(k3s·PostgreSQL·object·NetBird) 등록과 특권 역할 전용 접근 | `WG-02`, `NET-04`, `IAM-MIG-01` | 없음 | 특권 운영 SSH | 인증된 host key만 등록(TOFU 없음), Warpgate client key를 각 대상 `rocky` 계정에 source·forwarding 제한으로 배치, 네 target은 `platform-privileged`만 허용, 연결·권한·recording metadata와 2차 Ansible 무변경 확인 |
| `WG-04 DONE` | Warpgate native PostgreSQL TLS session과 최소권한 운영 role ([ADR-0024](adr/0024-warpgate-native-postgresql-sessions.md), [runbook](runbook/warpgate-postgres-sessions.md)) | `WG-03`, `PG-01`, `NET-04` | `OPNSENSE-LIVE` | 기록되는 PostgreSQL 운영 세션 | `platform-privileged`만 target 허용, Keycloak SSO/MFA 뒤 browser approval, `warpgate-01`→`postgres-01:5432` hostssl exact rule·HBA 한 줄, upstream `pg_monitor` 전용 role, TLS verify·허용/거부·recording metadata·2차 Ansible 무변경, `/warpgate-auditors`의 읽기 전용 Sessions·Recordings 조회를 새 SSO 로그인으로 확인 |
| `AWS-ID-01 DONE` | Keycloak `AssumeRoleWithSAML`·AWS role 매핑 | `KC-01` | 없음 | AWS 콘솔 권한 | 그룹별 임시 role, 세션 만료, 과권한·지속키 없음 |
| `AWS-ID-02 DONE` | 단일 AWS 계정의 Keycloak SAML 읽기 role을 inventory·observability·security group으로 분리하고 Dashy AWS Console 타일을 등록 | `AWS-ID-01`, `POM-01`, `IAM-01` | `TOFU-STATE`, `IDENTITY-LIVE`, `ARGO-ROOT` | 팀 5명 AWS 조회 | 기존 일상·특권 SAML membership을 새 전용 group으로 무중단 이관, SAML provider trust·900초 요청·사람용 IAM user/access key 0건 유지, 세 reader role은 쓰기·`PassRole`·`AssumeRole`·S3 backup 접근 없이 허용 목록만 조회, Dashy 타일은 AWS group만 표시, immutable Pomerium 및 최신 main `Synced/Healthy` |
| `VAULT-03 DONE` | Vault UI를 Pomerium 우회 표준 Ingress와 Vault OIDC auth method로 노출 (`gitops/apps/vault/`) | `VAULT-02`, `KC-01`, `INGRESS-01`, `KMS-01` | `VAULT-CONFIG`, `OPNSENSE-LIVE` | Vault 일상 운영·복구 독립성 | Vault OIDC auth method와 전용 Keycloak client 연결로 UI 사용자가 자기 policy 경로만 읽고 타 경로·`sys/mounts`는 403, Pomerium을 경유하지 않는 표준 Ingress와 자체서명 backend TLS 신뢰 설정, Pomerium Pod 정지 중 Vault UI 로그인 성공으로 복구 독립성 실증, root token·port-forward break-glass 보존 확인, audit device에 UI 로그인 event 기록과 token 원문 0건, `vault` alias 내부 A 1건·내부 AAAA·공개 A/AAAA 0건과 `ip-plan.md` 노출 정의 갱신, Traefik 정적 설정·Pod UID·restart 불변, Argo child `Synced/Healthy`, rollback 뒤 기존 Vault Agent 소비자 회귀 없음 |
| `GITOPS-02 DONE` | Argo CD UI Pomerium Route와 최소권한 RBAC 연결 | `GITOPS-01`, `POM-01` | `OPNSENSE-LIVE` | GitOps 일상 조회 | Pomerium 통과만으로 Argo 권한이 생기지 않음을 Argo 자체 OIDC·RBAC의 allow/deny로 실증, 조회 계정의 `platform-root`·child `Synced/Healthy` 조회 성공과 수동 sync·삭제·repo credential 조회 거부, `pomerium`→`argocd` NetworkPolicy egress 명시, `argo` alias 내부 A 1건·내부 AAAA·공개 A/AAAA 0건, 표준 Ingress만 사용해 HelmChartConfig·Traefik Pod UID·restart 불변, Argo child `Synced/Healthy`, rollback 뒤 기존 Route와 root Application 회귀 없음 |
| `S3-02 READY` | SeaweedFS filer 웹 UI(`filer.imcherry5778.xyz`)를 Pomerium Route로 노출해 `/platform-privileged`(`imcherry5778-admin`)만 접근하도록 제한 | `S3-01`, `POM-01` | `OPNSENSE-LIVE`, `ARGO-ROOT` | `object-01` 운영 가시성 | filer 바인딩을 `127.0.0.1`에서 DATA 주소로 확장하되 신규 PF rule로 k3s-01(`10.10.20.10/32`) 단일 source만 허용(기존 8333 rule과 동일 패턴)하고 master(9333)·volume(8080) 관리 포트는 loopback 유지, Unbound alias `filer.imcherry5778.xyz` → `k3s-01`(`10.10.20.10`) 등록과 `ip-plan.md` 노출 정의 갱신, Pomerium Route는 `/platform-privileged`만 allow(`/platform-users`·미인증 요청 403/redirect 실측), `pomerium`→`object-01` NetworkPolicy egress 명시, `imcherry5778-admin`의 실제 로그인과 filer tree 조회 성공, filer는 자체 bucket 단위 ACL이 없어 이 Route가 전체 filer 네임스페이스에 대한 all-or-nothing 접근권이며 `S3-01`의 bucket-scoped credential 최소권한 모델과 별개 경계라는 사실을 runbook에 명시, 기존 S3 API 8333 경로·PF rule·credential 모델 회귀 없음, `ARGO-ROOT` 잠금 아래 `platform-root`·`pomerium` 커밋 SHA 검증 후 main·Synced/Healthy 복귀, rollback은 Pomerium Route·PF rule 제거와 filer 바인딩 loopback 원복 |

2026-08-14 세션 논의로 `S3-02`를 신설한다. SeaweedFS는 MinIO 콘솔과 달리 컴포넌트별
UI가 분산돼 있고 그중 filer(8888)만 브라우저에서 버킷 내용을 탐색할 수 있는데, `S3-01`
이후 `object-01`의 관리 포트는 전부 loopback bind·PF 단일 source 허용·비 Pomerium
분류·SSH forwarding 금지로 의도적으로 격리돼 있어 filer UI에 닿는 경로가 없었다. 검토
결과 노출 자체는 이 스택의 다른 관리 UI(Wazuh·Shuffle·Vault)와 동일한
`/platform-privileged` + Pomerium 패턴으로 커버되는 정상 경로로 판단했고, 유일한
실질 트레이드오프는 filer가 bucket 단위 ACL 없이 all-or-nothing이라 `S3-01`이 만든
bucket-scoped credential 최소권한 모델을 이 UI 세션 하나가 우회한다는 점이다. break-glass
계정(Warpgate 로컬 `admin` 등)은 IdP 장애 전용으로 전 ADR에 걸쳐 일관되게 못박혀 있어
이 용도로 쓰지 않고, 기존 정상 특권 SSO 계정 `imcherry5778-admin`(`/platform-privileged`)을
그대로 재사용한다. 선행 `S3-01`·`POM-01`이 모두 `DONE`이므로 곧바로 `READY`로 연다.

2026-08-04 팀 인터뷰 결과를 [ADR-0017](adr/0017-team-identity-and-shuffle-rbac.md)로 확정하고
`IAM-01`과 `IAM-MIG-01`을 신설한다. GitHub는 인증 공급자로 추가하지 않고 username의 단일
명명 원본으로만 쓴다. 일상 ID는 `imcherry5778`, `foxgeun`, `cerberos2022`, `Jaeeyun`,
`snsd-hybirdinfra`이며 직무 표시는 권한 부여 근거로 사용하지 않는다. 다섯 계정 모두
`/platform-users`와 `/soar-readers`에서 시작한다. 실제 email은 실행 시 검증된 값을 보호된
`$KTC_SECRET_ROOT` 입력으로만 받아 Git·채팅·로그에 남기지 않는다. 총괄 운영자의 특권 작업은
별도 `imcherry5778-admin`만 사용하고 일상 계정에 admin role을 겹쳐 주지 않는다.

Shuffle은 `Platform Security` 단일 조직을 사용하고 하위 조직은 만들지 않는다.
`/soar-readers`→`shuffle-org-reader`, `/soar-operators`→`shuffle-user`,
`/platform-privileged`→`shuffle-admin`을 전용 OIDC client role로 매핑하며 한 계정에는 이 세
role 중 하나만 발급한다. `IAM-01`에서는 팀 일상 계정 다섯 개를 모두 reader로 시작하고,
`SOAR-01`에서만 `imcherry5778`을 reader에서 제거한 뒤 operator로 이동한다. Pomerium은 세
Shuffle 그룹만 Route에 허용하고 일반 `/platform-users`만 가진 계정은 통과시키지 않는다.
이는 Route 진입과 Shuffle 내부 인가를 서로 독립해서 판정하려는 경계다.

Shuffle OIDC는 public Authorization Code + PKCE client로 두고 role claim이 없는 로그인을
거부한다. 팀원 동시 등록 창에서만 자동 프로비저닝을 켜 각 사용자가 직접 MFA 로그인을 끝낸
뒤 username을 위 canonical 값과 대조하고 곧바로 자동 프로비저닝을 끈다. SSO 전용 강제는
하지 않는다. 현재 local `soar-dash-01-admin`은 이름을 바꾸거나 팀과 공유하지 않고 MFA를
추가한 break-glass 계정으로 남기며 API key는 발급하지 않는다. 기존 기본 계정명과 배포 입력이
다른 상태에서 rename하면 재시작 때 중복 bootstrap 계정이 생길 수 있으므로, 이 계정의 rename은
`IAM-01` 범위가 아니다.

기존 Keycloak `imcherry`·`imcherry-admin`도 `IAM-01`에서 rename·disable·delete하지 않는다.
OIDC subject와 서비스 내부 사용자·소유권이 username보다 오래 남을 수 있으므로
`IAM-MIG-01`이 Keycloak client와 실제 서비스별 연결을 전수 조사하고 새 ID의 positive proof를
확보한 뒤 기존 session revoke와 disable을 수행한다. 유일 Owner는 새 특권 ID에 먼저 넘긴다.
비활성 계정은 최소 90일 감사 보존 동안 삭제하지 않으며, 참조와 rollback 필요가 없다는 별도
판정 전에는 hard delete하지 않는다. 이번 백로그·ADR 변경은 계정이나 라이브 설정을 변경하지
않는다.

2026-08-04 실행에서는 사람이 직접 소유해야 하는 초기 비밀번호 변경·MFA 등록·최초 Shuffle
OIDC 로그인을 `IAM-ENROLL-01`로 분리했다. `IAM-01`은 server-side 계정·MFA 강제·client와
role mapping·Route·복구 계정·대표 정책 경계까지 완료한다. 목표 보안 상태는 바뀌지 않으며
`IAM-MIG-01`과 `SOAR-01`은 실제 대상 ID 등록 `6/6` 전까지 열지 않는다.

`EDGE-DESIGN-02`에서 외부 팀 등록은 사람용 setup key 대신 공개 Keycloak 사용자 프런트엔드와
기존 일상 ID의 NetBird OIDC 로그인을 쓰기로 결정했다. `IAM-ENROLL-01`은 실제 팀원이 외부에서
등록할 수 있는 `NB-ENROLL-01` 경로가 완료될 때까지 `BLOCKED`다. 일상 ID 다섯 개만 자기
NetBird peer를 소유하고, `/platform-privileged`만 가진 특권 ID는 이미 연결된 승인 장치에서
필요한 서비스에 별도로 로그인한다. 이 의존성 변경은 대상 계정의 credential·required action과
Shuffle 자동 프로비저닝 상태를 바꾸지 않는다.

| 경계 | 현재 `SOAR-DASH-01` 기준선 | `IAM-01`·`IAM-ENROLL-01` 목표 | 후속 |
|---|---|---|---|
| Keycloak 사람 ID | `imcherry`, `imcherry-admin` | GitHub username 일상 ID 5개와 `imcherry5778-admin`; 모두 MFA | `IAM-MIG-01`에서 기존 ID disable·보존 |
| 팀원용 local ID | 없음 | 만들지 않음 | 없음 |
| Shuffle local recovery | `soar-dash-01-admin` 한 개 | 같은 ID 유지, MFA 추가, 공유·rename·API key 발급 금지 | 정기 복구 검증 |
| Shuffle 조직 | `default` | `Platform Security` 단일 조직, 하위 조직 없음 | 다중 팀이 생길 때 재검토 |
| Shuffle OIDC | 없음 | Keycloak public Authorization Code + PKCE, role claim 필수, 통제된 최초 등록 뒤 자동 프로비저닝 off | 없음 |
| Shuffle 일상 권한 | 팀 OIDC user 없음 | 다섯 일상 ID 모두 `shuffle-org-reader` 하나 | `SOAR-01`에서 `imcherry5778`만 `shuffle-user`로 교체 |
| Shuffle 특권 권한 | local bootstrap admin | `imcherry5778-admin`에 `shuffle-admin` 하나, local admin은 recovery 전용 | 없음 |
| Pomerium Route | `/platform-privileged`만 허용 | `/soar-readers`, `/soar-operators`, `/platform-privileged`만 허용 | 일반 `/platform-users`만 가진 계정은 계속 거부 |

2026-08-05 `IAM-MIG-01`에서 Keycloak platform realm의 client 11개(`argocd`, `awx`,
`dashy-portal`, `gitea`, `grafana`, `headlamp`, `https://signin.aws.amazon.com/saml`,
`netbird-backend`, `netbird-client`, `pomerium`, `shuffle`, `sonarqube`, `vault`,
`warpgate`)와 group·role-mapping을 전수 조회했다. Jenkins·Harbor는 Keycloak client가
없어 대상에서 제외했다. 모든 client가 `groups` claim을 보내지만 실제 서비스 안의 상태를
직접 확인한 결과 두 부류로 갈렸다.

group-gated only(legacy 계정에 묶인 영속 상태 없음, group·session 정리만으로 충분):
Argo CD·Headlamp·Pomerium/Dashy·Vault(OIDC external group alias, `imcherry-admin` entity의
직접 policy 0건 확인)·AWS SAML(임시 role 세션, 영속 IAM 사용자 없음)·Shuffle(`IAM-ENROLL-01`의
`registration-close`가 이미 role 대조 `6/6` 정확 일치를 확인해 legacy 잔존 멤버십 없음을
증명).

persistent per-user ownership(실제 이전 필요):
- **NetBird**: 유일 Account Owner가 legacy `imcherry`. Owner API로 `imcherry5778-admin`에
  이전하고(`is_blocked:false`, `role:owner`) legacy `imcherry`는 자동으로 `admin`으로
  강등됨을 라이브로 확인. peer 소유권 자체는 `NB-ENROLL-01`에서 이미 새 ID로 넘어가 있어
  추가 이전 대상이 없었다. `infra/ansible/roles/netbird_server/defaults/main.yml`의
  `netbird_keycloak_account_owner_username`도 `imcherry5778-admin`으로 갱신.
- **Warpgate**: `infra/ansible/roles/warpgate_baseline/defaults/main.yml`의
  `warpgate_users`에 `imcherry5778`·`imcherry5778-admin`을 추가하고, legacy 두 계정의
  `sso_credentials`는 빈 배열로 선언해 email 기준 SSO 매칭 충돌(legacy와 신규 계정이 같은
  Keycloak email을 공유)을 제거했다. `ansible-playbook infra/ansible/playbooks/
  warpgate-baseline.yml`을 라이브로 실행해 `changed=5`(신규 user 2개 생성, 신규 SSO
  credential 2개 생성, legacy SSO credential 2개 제거)를 확인했고 Warpgate user 객체
  자체(세션 기록)는 삭제하지 않았다.
- **AWX**: `gitops/apps/awx/provision-script.yaml`의 `SOCIAL_AUTH_ORGANIZATION_MAP`·
  `SOCIAL_AUTH_TEAM_MAP`이 group claim이 아니라 고정 username 목록으로 Organization·Team
  멤버십을 결정한다는 것을 코드로 확인했다. legacy username을 새 ID로 교체했지만, 이 맵은
  로그인 시점에만 적용되므로 기존 legacy 멤버십은 남아 있었다. legacy가 이미 disable돼
  다시 로그인할 수 없으므로 AWX Admin API로 `imcherry`·`imcherry-admin`을 Organization
  `Platform`과 각 Team(`AWX Operators`/`AWX Approvers`)에서 직접 제거했다(라이브 확인,
  최종 멤버십 0). 신규 ID는 실제 첫 SSO 로그인 시점에 교정된 맵으로 자동 편입된다.
- **Keycloak `keycloak-readers` 그룹**: legacy `imcherry-admin`만 이 그룹(client role
  `realm-management:view-users`)에 있고 신규 `imcherry5778-admin`은 없던 것을 발견해
  동일 그룹에 편입시켰다.
- **email 충돌**: `imcherry5778-admin`의 Keycloak email이 `IAM-01-FIX-01`의 완화 이후
  `imcherry5778`(일상 계정)과 동일한 값이었다. Warpgate·SonarQube SAML처럼 email로 계정을
  매칭하는 서비스에서 두 계정이 충돌하므로, legacy `imcherry-admin`이 쓰던 것과 같은 패턴
  (`imcherry5778+admin@gmail.com`)으로 고유 email을 부여해 해소했다.

`Gitea`(`ENABLE_AUTO_REGISTRATION=true`, `DISABLE_REGISTRATION=true`)와 `SonarQube`는 첫
SSO 로그인 시 로컬 계정을 자동 생성하는 구조라 사전 등록 게이트가 없다. legacy `imcherry`
Gitea 계정(표시 이름 `Imcherry Daily`)이 실재함은 라이브로 확인했으나, 이 계정이 소유한
저장소 전수(있다면)는 이번 세션에서 확정하지 못했다(Gitea API 세션 인증 방식 불일치로
자동화 실패, 재현 비용 대비 낮은 가치로 판단해 중단). Keycloak 계정을 disable해도 Gitea
쪽 로컬 레코드와 소유권은 삭제되지 않고 향후 SSO 재로그인만 막히므로 즉시 위험은 없지만,
90일 보존 기간 안에 `imcherry5778`으로 직접 로그인해 `imcherry` 소유 저장소가 있는지
확인하고 필요하면 Gitea 자체 저장소 이전 기능으로 옮기는 것을 권장한다.

같은 시점 대조: legacy `imcherry`(활성 세션 6개)·`imcherry-admin`(세션 2개)의 세션을
Keycloak Admin API로 revoke하고 `enabled:false`로 전환한 직후, 동일한 저장된 자격증명
(daily-password/daily-totp, privileged-password/privileged-totp)으로 Warpgate·NetBird
SSO 로그인을 재시도해 두 계정 모두 Keycloak 로그인 폼 단계에서 "Account is disabled,
contact your administrator"로 즉시 거부됨을 실측했다. 이 realm의 모든 client가 동일한
Keycloak 로그인을 거치므로 이 판정은 client 11개 전체에 동일하게 적용된다. 신규 ID(사람이
직접 비밀번호를 바꿔 세션 자격증명을 보유하지 않음)는 `IAM-ENROLL-01`이 이미 라이브로 증명한
`requiredActions=0`·`mfa_active=6/6`·`ShuffleIAM=PASS` 결과와 이번 세션에서 확인한 그룹·
email·Warpgate/AWX 쪽 서버측 구성 정합성으로 allow를 판정했다(실제 인터랙티브 로그인은
계정 소유자만 재현 가능).

Keycloak platform realm bootstrap import(`gitops/apps/keycloak/vault-agent-config.yaml`,
`keycloak-bootstrap-v2` Job)는 realm이 이미 존재하면 건너뛰는 것이 Keycloak
`--import-realm`의 기본 동작이라 평상시 재시작·GitOps 재동기화로는 재적용되지 않지만,
실제 재해복구로 realm이 처음부터 재생성되는 경우에는 legacy 두 계정이 `enabled:true`로
선언돼 있어 되살아날 수 있었다. 이 JSON의 `imcherry`·`imcherry-admin`도 `enabled:false`로
맞췄다(master realm의 `imcherry-kc-recovery`는 이 작업 범위가 아니라 그대로 둠).

라이브 검증은 `ARGO-ROOT` 잠금 절차를 따랐다. 검증 시작 전 `platform-root` main SHA
(`d4e7d2a`)를 기록하고, `gitops/root/awx-application.yaml`·`keycloak-application.yaml`의
`targetRevision`을 작업 브랜치 검증 SHA로 임시 전환해 `platform-root`·`awx`·`keycloak`
Application을 함께 그 SHA로 옮겼다. `awx-provision` Sync hook 재실행과
`keycloak-vault-agent` ConfigMap 라이브 조회로 두 변경이 실제 반영됐음을 확인한 뒤, 세
Application의 `targetRevision`을 모두 `main`으로 되돌리고 `Synced/Healthy` 복귀를
확인했다. 검증 도중 별도 `obs-03` worktree/세션이 같은 `ARGO-ROOT`·`IDENTITY-LIVE`
잠금을 먼저 점유하고 있어 그 세션이 `OBS-03`을 완료해 `platform-root`를 `main`으로
되돌릴 때까지 대기한 뒤 이어서 진행했다.

hard delete는 0건이다. legacy `imcherry`·`imcherry-admin`은 rename·delete 없이
`enabled:false`로만 남아 있고, NetBird·Warpgate의 user 객체도 삭제하지 않고 접근 경로만
끊었다. rollback은 Keycloak Admin API로 두 계정의 `enabled`를 `true`로 되돌리는 것만으로
충분하다(세션은 다시 로그인해야 생성되므로 별도 절차 불필요). NetBird Owner를 legacy로
되돌리려면 같은 Owner API로 역방향 이전을 한 번 더 호출해야 하며, Warpgate SSO
credential도 `warpgate_users` 선언을 되돌려 재적용하면 복구된다. 최소 90일 감사 보존
동안 이 상태를 유지하고, 참조가 없다는 별도 판정과 삭제 승인이 있을 때만 hard delete를
검토한다.

남은 후속 사항(새 작업 ID를 열지 않고 기록만 남김): (1) `verify-*.sh`/`verify-*.py` 등
`awx-01`·`headlamp-02`·`obs-02`·`iam-01`·`kc-01`·`quality-01`·`pom-01`·`scm-01`·
`vault-03`·`wazuh-02`의 회귀 검증 스크립트가 legacy `imcherry`/`imcherry-admin`
자격증명을 하드코딩하고 있어, 각 서비스를 다시 건드릴 때 새 ID로 교체해야 재실행 가능하다.
(2) Gitea legacy 저장소 소유권 확인은 위에 기록한 대로 별도 수동 점검이 필요하다. 이
작업이 선행인 별도 직접 후속 작업 ID는 백로그에 없으므로 새로 여는 `READY`는 없다.

2026-08-03 `VAULT-03`과 `GITOPS-02`를 신설한다. 두 작업은 [`ip-plan.md`](ip-plan.md)가 이미
목표 노출 방식을 적어 두었지만 이를 소유한 작업 ID가 없어 구현되지 않은 항목을 닫는다.
`argo.imcherry5778.xyz`의 노출은 `Pomerium`으로, `vault.imcherry5778.xyz`는 `내부 관리
경로만`으로 기록돼 있고 둘 다 내부 DNS는 `미등록`이다.

`GITOPS-01`이 UI·Ingress를 만들지 않은 것은 bootstrap 시점 제약이었다. 당시에는 `POM-01`이
없었으므로 보호 경로를 만들 수단 자체가 없었다. `POM-01` 완료 뒤 route를 추가하는 후속이
만들어지지 않아 현재까지 SSH와 localhost port-forward가 유일한 조회 경로다. 일상 조회는
[ADR-0004](adr/0004-zero-trust-identity-and-management-access.md)대로 Headlamp가 담당하므로
`GITOPS-02`는 필수 경로가 아니라 조회 편의이며 우선순위가 가장 낮다. Pomerium 통과가 Argo
권한이 되지 않게 하는 경계는 `HEADLAMP-02`가 Kubernetes RBAC로 판정한 것과 같은 이유로
Argo 자체 RBAC가 소유한다.

`VAULT-03`은 Vault UI를 노출하되 Pomerium 뒤에 두지 않는다.
[`architecture.md`](architecture.md)의 요구는 "Vault 복구는 Pomerium이나 Dashy를 유일한
경로로 삼지 않는다"이지 노출 금지가 아니므로, break-glass를 보존하는 한 노출은 결정 변경이
아니다. 다만 Pomerium을 고치기 위해 봐야 하는 것이 Vault인데 그 Vault를 Pomerium 뒤에 두면
복구 순환이 생긴다. `KMS-01`의 auto-unseal은 Vault가 sealed여서 Pomerium이 client secret을
읽지 못하는 축을 줄였지만, Pomerium이 Vault KV에 의존하는 축과 이 복구 순환 축은 줄이지
않았다. auto-unseal은 오히려 공인 AWS KMS endpoint 의존을 더했고 `KMS-01`의 IAM 회수 시험이
`AccessDenied`로 Vault를 NotReady로 만든 것을 이미 확인했으므로 sealed 확률은 0이 아니다.
Vault는 OIDC auth method와 policy로 UI 사용자 권한을 스스로 판정하므로 Pomerium을 끼우면
인증만 두 겹이 된다. 기존 Pomerium Route 여덟 건은 모두 평문 HTTP upstream인데 Vault
listener는 자체서명 TLS이므로, Pomerium 계층을 빼면 신뢰 설정도 한 곳으로 줄어든다.

2026-08-04 `GITOPS-02`에서 Argo CD UI를 Pomerium Route(`claim/groups=/platform-users`,
`tls_skip_verify`)로 노출하고 Argo CD 자체 OIDC(Keycloak `argocd` public PKCE client,
`enablePKCEAuthentication`)·RBAC(`role:gitops-viewer`)로 실제 권한을 판정했다. Argo CD
본체는 `gitops/bootstrap/argocd/`가 계속 소유하므로 vendored `install.yaml`은 손대지 않고
`argocd-cm`·`argocd-rbac-cm`을 JSON merge patch로만 확장해 기존 `resource.customizations.*`
키와 SHA-256 무결성을 보존했다. `role:gitops-viewer`는 내장 `role:readonly`보다 좁아
`applications get`·`projects get`만 허용하고 `policy.default`는 빈 문자열로 고정해
`/platform-users` 밖의 로그인은 role이 전혀 없다.

라이브 검증에서 `imcherry`(`/platform-users`)의 Pomerium 로그인은 `argo.imcherry5778.xyz`를
통과(200)했지만 같은 세션에서 Argo Bearer 없이 REST API를 호출하면 Argo CD 자신이 401을
반환해 Pomerium 통과가 Argo 인증을 대신하지 않음을 실증했다. Keycloak `argocd` client로
직접 발급한 id_token 하나로 `GET /api/v1/applications` 200(`platform-root`·`pomerium`
Synced/Healthy 포함)과 같은 세션의 `POST .../sync` 403, `DELETE .../<app>` 403을 확인했다.
Argo CD의 `ListRepositories`는 RBAC 여부와 무관하게 항상 200을 반환하고 결과만 필터링하므로
`GET /api/v1/repositories`는 200이지만 `items` 0건으로 repo credential 조회 거부를 판정했다
(초기 시도에서 이 엔드포인트가 403을 반환하지 않는 것을 실제로 확인하고 완료 증거의 판정
방식을 항목 개수 기준으로 보정했다). `pomerium`→`argocd-server` NetworkPolicy egress(TCP
8080, containerPort 기준), `argo` 내부 A 1건·내부 AAAA·공개 A/AAAA 0건, `HelmChartConfig/
traefik` resourceVersion과 Traefik Pod UID·restart count는 세션 시작 기준값과 끝까지
동일했다. rollback 뒤 `argo` Ingress host·NetworkPolicy는 정확히 제거되고 기존 8개 Route와
NetworkPolicy는 회귀 없이 유지됐다.

merge 전 `ARGO-ROOT` 잠금 확보 과정에서 병렬 `PKI-01` 세션이 같은 시간대에 `platform-root`
targetRevision을 반복 전환하는 것을 발견해 충돌 여부를 사용자에게 확인받은 뒤, `PKI-01`
merge(`origin/main` → `01eaaf2`) 완료를 기다려 브랜치를 재rebase하고 진행했다. 검증 뒤
`platform-root`는 기록해 둔 main SHA로 정확히 복귀했다.

2026-08-04 `VAULT-03`에서 Vault UI를 Pomerium 뒤에 두지 않는 표준 Ingress로 노출하고
`auth/oidc`·전용 policy·identity group-alias로 권한을 Vault 자신이 판정하게 했다. 자체서명
backend TLS 신뢰는 `ServersTransport`(`vault-backend-tls`, `serverName=vault.vault.svc.
cluster.local`)와 그 인증서만 담은 `Secret`(`vault-ingress-ca`)으로 구성했다. 라이브에서
Traefik의 `service.serversscheme`·`service.serverstransport` annotation은 Ingress가 아니라
backend Service에 있어야 적용된다는 것을 500 Internal Server Error로 실제 확인해
`service.yaml`로 옮겼다. Ingress에 두면 Traefik이 두 annotation을 조용히 무시하고 평문
HTTP로 backend에 붙어 Vault가 즉시 거부했다.

Keycloak confidential client(`vault`) 생성 스크립트의 secret 생성 파이프(`cut -c1-48`이
자체 개행을 하나 더 붙이고 그 위에 `printf '\n'`이 개행 하나를 더 붙여 파일 끝에 개행 두
개가 남음)와 검증부(`jq rtrimstr("\n")`, 개행 하나만 제거)가 Vault 쪽 주입(`tr -d '\n'`,
전체 제거)과 불일치해 Keycloak엔 개행이 포함된 값이, Vault엔 개행 없는 값이 각각 등록되는
`unauthorized_client` 실패를 라이브에서 재현했다. 생성은 `head -c 48`로, 두 소비측 비교는
`gsub("\n"; "")`로 통일해 재현·수정했다.

`auth/oidc/role/ui-viewer`는 `bound_audiences=vault`로 aud claim을 제한하고
`allowed_redirect_uris`를 Vault UI의 실제 callback 경로 하나로 좁혔으며 `token_policies`를
비워 내장 `default` policy만 자동 부여되게 했다. `vault-ui-operator` policy(`kv/data/*`,
`kv/metadata/*` read/list만)는 identity group(`vault-ui-platform-privileged`, external)의
group-alias로 Keycloak `groups` claim의 `/platform-privileged`에만 연결했다.

라이브 검증은 Pomerium Deployment를 0 replica로 내린 한 창에서 `imcherry-admin`
(`/platform-privileged`)의 Vault UI OIDC 로그인 성공(복구 독립성), 발급된 token의
`policies=[default, vault-ui-operator]`, `kv/data/keycloak/runtime` 200과 `sys/mounts`·
`auth/token/create` 403, audit device(`stdout`)에 `auth/oidc` 이벤트 기록과 token 원문
0건을 모두 확인했다. root token `token lookup`은 `policies=[root]`를 유지했고
`kubectl port-forward svc/vault 8200`도 그대로 열렸다. Pomerium을 원래 replica 수로
복구한 뒤 Keycloak·Pomerium Pod가 모두 회귀 없이 `Running`을 유지함을 확인했다.
`HelmChartConfig/traefik` resourceVersion과 Traefik Pod UID·restart count는 검증 시작
기준값과 끝까지 동일했고 `vault-0`의 restart count도 0을 유지했다(StatefulSet 무변경).

`vault` 내부 alias(`vault.imcherry5778.xyz` → `10.10.20.10`)를 Unbound에 추가하고
`check-drift.sh --update`로 스냅샷을 갱신했다. `ip-plan.md`의 노출 정의를 "내부 관리
경로만"에서 "Pomerium 미경유 표준 Ingress; 실제 권한은 Vault 자체 OIDC·policy가 판정"으로
갱신했다. `VAULT-03`을 선행으로 가진 작업은 없으므로 새로 여는 후속은 없다.

2026-08-03 `PKI-01`의 첫 mTLS consumer를 CrowdSec agent↔LAPI로 정하고 인증서 발급·갱신
경로를 cert-manager + Vault Issuer로 결정했다. 따라서 `PKI-01`은 `DEFERRED`를 벗고 새 선행
`CERTMGR-01`이 남은 `BLOCKED`가 되며, 공유 잠금 표에 정의가 없던 `VAULT-CONFIG`도 함께
채웠다.

CrowdSec chart는 TLS 자료를 자체 self-signed CA로 만들 수 있지만 그 경로는 내부 CA를 하나
더 만들고 CRL을 제공하지 않는다. `VAULT-02`가 이미 발급·체인 검증·CRL 폐기를 실증한
`pki/`를 CA로 두면 신뢰 도메인이 하나로 유지된다. 어느 쪽이든 chart의 인증서 갱신은
cert-manager를 전제하므로, `OBS-01`이 "새 CA controller를 설치하는 대신"으로 미뤄 둔
cert-manager 도입 판단을 `CERTMGR-01`에서 다시 한다. 그 결과가 기존 인증서 소유 경계를
바꾸면 ADR을 함께 남긴다.

현재 `pki/roles/internal-workload`로는 CrowdSec 인증서를 발급할 수 없다. agent Certificate는
SAN 없이 `CN=CrowdSec Agent`를 쓰는데 role이 `enforce_hostnames=true`이고, LAPI Certificate의
실제 Helm release 단일 원본에 따른 `crowdsec-service.crowdsec-01.svc.cluster.local`과 `localhost`는
`allowed_domains=svc.cluster.local,cluster.local`·`allow_bare_domains=false` 밖이다. 게다가
LAPI는 `agent-ou` 같은 OU 값으로 agent와 bouncer를 구분하므로 role이 OU를 보존해야 인가가
성립한다. `PKI-01`은 role을 넓히는 대신 chart Certificate를 쓰지 않고 CN·SAN을 hostname
규격으로 직접 선언하는 선택지를 함께 판정하고, 최소권한 경계를 완료 증거로 남긴다.

`KMS-01`은 선행으로 걸지 않는다. cert-manager는 발급 결과를 Secret에 캐시하고 `renewBefore`
시점에만 Vault를 호출하므로, role `max_ttl`인 720h와 `renewBefore` 240h를 쓰면 Vault가 열흘
넘게 sealed일 때만 갱신이 멈춘다. 다만 이 성질을 가정으로 두지 않고 `CERTMGR-01`과 `PKI-01`
양쪽에서 sealed 상태의 기존 인증서 유효성을 완료 증거로 확인한다. auto-unseal은 이 의존을
더 줄이지만 `VAULT-INIT` 단독 창을 요구하므로 순서를 강제하지 않는다.

`CERTMGR-01`이 `WAZUH-01`을 선행으로 갖는 것은 논리 의존이 아니라 용량 순서다. cert-manager는
controller·webhook·cainjector Pod를 더하므로 `WAZUH-01`의 capacity gate가 먼저 판정돼야 했다.
`WAZUH-01` 배포 후 `k3s-01` available은 14,584,446,976 bytes로 12 GiB 경고선 위이고 PVC 합계
91.125 GiB도 96 GiB 경고선 안이므로, 선행이 모두 `DONE`인 `CERTMGR-01`을 `READY`로 연다. 이
값은 판정 근거일 뿐이므로 배포 직전에 같은 기준으로 다시 측정한다. `PKI-01`은 `CERTMGR-01`이
남아 `BLOCKED`를 유지한다.

2026-08-03 `CERTMGR-01`에서 cert-manager `v1.21.1`과 CRD 6개, image index digest 4개를
고정하고 Vault 전용 PKI role·policy·Kubernetes auth role을 연결했다. 시험 Certificate 한 장으로
발급·Secret·chain, 단축 갱신 한 사이클, sealed 상태의 기존 인증서 유효와 신규 발급 실패를
확인했으며 AWS KMS auto-unseal 직후 시험 자원을 제거했다. 배포 전후 capacity 정지선과 Argo
revert 뒤 기존 Application 21개의 무회귀도 통과했으므로 `CERTMGR-01`을 `DONE`으로 닫고, 모든
선행이 끝난 직접 후속 `PKI-01`만 `READY`로 연다. 실제 CrowdSec consumer 연결은 하지 않았다.

2026-08-03 `PKI-01`에서 chart Certificate를 쓰지 않고 실제 Helm release 이름의
`crowdsec-service.crowdsec-01.svc.cluster.local`을 LAPI CN·SAN으로 고정했다. agent·LAPI를
각각 exact name·EKU·OU에 닫힌 Vault role·policy·Issuer로 나눠 공용 role을 넓히지 않았고,
허용 밖 이름은 발급 거부, 외부 OU는 leaf에 미발급, 타 signing path는 403임을 확인했다.

최신 main `62271a2cb196c9d2045f8d0d8c201b2d20ea3519`에 rebase한 불변 구성
`5a9b0b86cd50103688eb1a07705152baacb8f7fb`에서 실제 agent mTLS·wrong CA 거부와 agent/bouncer OU
상호 거부(403/401), revoke→CRL 등재→TLS 거부를 통과했다. 단축 TTL에서 agent
revision `13→14`, LAPI `14→15`, leaf 지문 변경과 같은 Pod UID의 container reload를 확인했다.
Vault seal 중 기존 mTLS·Secret은 유지되고 신규 발급만 실패했으며 AWS KMS auto-unseal 복구,
Git·관련 로그 private key PEM 0건을 통과했다. 시작 main으로 rollback한 뒤
`tls.enabled=false`와 정상 200·공격 403·exact 예외 200이 복구됐다. `PKI-01`을 `DONE`으로
닫으며 이 작업을 선행으로 가진 직접 후속 ID는 없다.

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
| `CAP-03 DONE` | `k3s-01` RAM을 24 GiB에서 28 GiB로 증설해 Wazuh 재진입 용량 확보 | `CAP-02` | `PVE-LIVE`, `TOFU-STATE`, `K3S-BOOTSTRAP` | `WAZUH-01` | OpenTofu가 VMID 120 memory `24576→28672`만 `0 add, 1 change, 0 destroy`로 계획, state 사본·rollback 확보, 정상 재부팅 뒤 boot ID 변경·guest RAM 증가·swap 0·Node Ready·Argo 전체 `Synced/Healthy`, host/guest/PVC 정지선 통과와 Wazuh 재진입 available 11 GiB 이상, 최종 plan 무변경 |
| `CAP-04 DONE` | Shuffle 진입 용량 판정과 필요할 때만 `k3s-01` RAM 증설 | `CAP-03`, `WAZUH-01` | `PVE-LIVE`, `TOFU-STATE`, `K3S-BOOTSTRAP` | `SOAR-01` | Shuffle 공식 최소 요구량과 자체 OpenSearch 분리 배포를 전제로 계산한 진입선과 현재 실측 대조, 미달일 때만 OpenTofu가 VMID 120 memory `28672→32768`만 `0 add, 1 change, 0 destroy`로 계획하고 state 사본·rollback 확보, 재부팅 뒤 boot ID 변경·guest RAM 증가·swap 0·Node Ready·Vault 재unseal·Argo 전체 `Synced/Healthy`, 배정 합계 52 GiB 경고선 미만 유지, PVC 선언 합계를 96 GiB 경고와 120 GiB 정지로 구분해 재판정하고 Shuffle 몫 배정, 증설이 불필요하면 근거와 `SOAR-01` 진입선만 기록하고 라이브 변경 0, 최종 plan 무변경 |
| `CAP-05 DONE` | `WAZUH-02` 배포 후 미달로 확인된 `SOAR-01` 진입선을 충족하도록 `k3s-01` RAM을 28 GiB에서 32 GiB로 증설 | `CAP-04`, `WAZUH-02` | `PVE-LIVE`, `TOFU-STATE`, `K3S-BOOTSTRAP` | `SOAR-01` | OpenTofu가 VMID 120 memory `28672→32768`만 `0 add, 1 change, 0 destroy`로 계획, state 사본·rollback 확보, 정상 재부팅 뒤 boot ID 변경·guest RAM 증가·swap 0·Node Ready·Vault 재unseal·Argo 전체 `Synced/Healthy`, VM RAM 배정 합계 52 GiB 경고선 미만 유지, PVC 선언·정지선 불변, 재부팅 뒤 `k3s-01` available이 `SOAR-01` 진입선 12 GiB 이상임을 재측정하고 충족 시에만 `SOAR-01`을 `READY`로 전환, 최종 plan 무변경 |
| `SCM-01 DONE` | Gitea | `CAP-02`, `PG-01`, `VAULT-02`, `POM-01` | 없음 | CI·Renovate | push/restore, SSO·RBAC, webhook 최소권한 |
| `SCM-02 DONE` | `platform` repo 자체를 GitHub에서 Gitea로 읽기 전용 pull-mirror(`gitops/tools/scm-02/`)해 내부 가시성 확보; GitHub SSOT·Argo `repoURL`은 불변 | `SCM-01` | 없음 | 내부 가시성(라이브 경로 영향 없음) | `ktcloud4-bean/platform` private mirror 생성, `mirror_interval=30m`, `original_url` 선언 일치, GitHub `main` HEAD SHA와 Gitea mirror branch SHA 정확히 일치 확인; Argo Application `repoURL`은 여전히 `ssh://git@ssh.github.com` 전부(변경 0건)이므로 Gitea 장애가 GitOps reconcile을 막지 않음(순환 의존 없음); 임시 admin token은 사용 직후 DB에서 삭제(Gitea가 token 인증의 self-delete API를 401로 거부해 수동 삭제로 대체, 스크립트에 근거 기록) |
| `REG-01 DONE` | Harbor | `CAP-02`, `PG-01`, `VAULT-02`, `POM-01` | 없음 | CI·Trivy·Cosign | push/pull, robot account, retention, restore |
| `CI-01 DONE` | Jenkins agent 격리와 pipeline 기준선 | `SCM-01`, `REG-01`, `VAULT-02` | 없음 | 공급망 E2E | 비밀 마스킹, 비특권 agent, 이미지 build/push |
| `AWS-CI-FIX-01 DONE` | main에 들어간 `infra/aws` Jenkins pipeline을 GitHub source·plan 전용 agent·원격 state app root 경계로 보정하고, state가 없는 최초 실행은 admin bootstrap 절차로 분리; app network의 EKS egress는 ECR·S3·STS endpoint와 RDS로 한정 | `CI-01`, `SCAN-01` | `ARGO-ROOT`, `TOFU-STATE` | AWS OpenTofu plan | 단일 정적 검증에서 JCasC·Pod 보안·root allowlist·계정 guard·실패 Trivy gate·partial backend·OpenTofu init/validate 통과, immutable SHA의 `platform-root`·`jenkins` `Synced/Healthy`, `tofu-app-network`·`tofu-app-ecr` build 각각 `SUCCESS`와 plan-only·민감값 0건, main rollback 뒤 `Synced/Healthy` |
| `BOARD-DEMO-01 DONE` | GitHub `ktcloud4-bean/board-app`를 Gitea `ktcloud4-bean/board-app` pull-mirror로 고정하고, 전용 PostgreSQL TLS·Vault·Jenkins·Harbor·서명 digest·내부 Pomerium 경계로 데모 게시판을 배포 | `SCM-01`, `REG-01`, `CI-01`, `SCAN-01`, `SIGN-01`, `POL-02`, `POM-01`, `PG-01`, `VAULT-02` | `VAULT-CONFIG`, `ARGO-ROOT`, `OPNSENSE-LIVE` | 내부 `board` 사용자 | GitHub/Gitea `main` SHA 일치·private pull-mirror, 전용 DB TLS와 Vault secret 분리, Jenkins signed digest·Trivy/SBOM, `board-demo`의 signed Pod Ready·unsigned admission 거부, `/platform-users` 내부 Pomerium 경로·공개 DNS/NAT 0건 |
| `BOARD-DEMO-02 DONE` | 더 이상 쓰지 않는 `BOARD-DEMO-01` 리소스를 Gitea 저장소를 제외하고 전부 제거(decommission) | `BOARD-DEMO-01` | `ARGO-ROOT`, `VAULT-CONFIG`, `OPNSENSE-LIVE` | 없음 | GitOps 선언(`gitops/apps/board-demo`, root Application/Project, Pomerium route/egress/ingress, Jenkins job·credential·Vault Agent 템플릿, `gitops/tools/board-demo`, 관련 Ansible role·Vault policy 선언, `docs/ip-plan.md` alias) 제거; 라이브에서 Postgres `board_demo` DB·role DROP, Vault KV 3개·policy 3개·auth role 2개 삭제(공유 `jenkins` auth role은 `board-demo-jenkins` policy만 제거하고 `aws-hr-jenkins` 등 나머지 보존), Harbor `board-demo` project·robot·이미지 삭제, OPNsense/Unbound `board` alias rollback, JCasC 재적용으로 남은 Jenkins job·credential 직접 삭제; `ARGO-ROOT` 잠금 아래 `platform-root`(`Prune=false` AppProject는 명시적 삭제)·`pomerium`·`jenkins`가 이 커밋에서 Synced/Healthy, `board-demo` namespace·Application·AppProject 소멸 확인; Gitea private mirror 저장소는 저장된 `scm-recovery` 복구 자격증명이 라이브와 불일치해 제거하지 못함(사용자가 직접 처리) |
| `AWS-HR-01 DONE` | `aws/ktcloud4-bean`의 미적용 HR EKS 선언을 `infra/aws` root 경계로 이관·보정하고, 기존 AWS shared VPC에 HR subnet을 분리해 `aws/hr-system`을 Jenkins→ECR immutable digest→기존 Argo CD의 EKS GitOps destination으로 배포 | `AWS-CI-FIX-01`, `SCM-01`, `CI-01`, `SCAN-01`, `SIGN-01`, `POM-01`, `AWS-NET-01` | `TOFU-STATE`, `OPNSENSE-LIVE`, `ARGO-ROOT` | 내부 HR 사용자 | legacy state 소유권 보존, 잘못 배치된 별도 VPC/EKS/Aurora의 snapshot 후 재생성, shared VPC HR subnet·remote state, Pomerium을 통한 `www`·`admin` 내부 route와 기존 VGW의 새 S2S 최소 경로, Secrets Manager/IRSA의 app DB credential 분리, 세 이미지 signed immutable digest·SBOM·scan, Argo EKS child `Synced/Healthy`, 직원/HR 권한·migration·rollback 및 공개 DNS/NAT 0건 |
| `AWS-HR-01-FIX-01 DONE` | ClusterFirst Pomerium Pod가 HR private ALB alias를 해석하도록 packaged CoreDNS의 two-zone conditional forward와 전용 Argo child를 추가 | `AWS-HR-01` | `ARGO-ROOT` | 내부 HR 사용자 | Route 53 alias가 재생성 전 ALB를 가리킨 drift를 OpenTofu in-place update로 보정하고, `coredns-custom`은 `aws.imcherry5778.xyz`와 EKS private API zone만 `k3s-01:1053`으로 전달; Pomerium selector Pod DNS와 internal ALB TCP 80 성공, root·coredns·pomerium literal `main` `Synced/Healthy`, 임시 Pod 제거 |
| `AWS-HR-01-FIX-02 DONE` | EKS worker node security group에 같은 SG 내 VPC CNI Pod data-plane egress를 선언해 cross-node frontend→API 요청의 30초 upstream timeout을 복구 | `AWS-HR-01-FIX-01` | `TOFU-STATE` | 내부 HR 사용자 | `tofu-app-network` plan이 node SG self egress 1개 추가 외 변화·파괴 0건, apply 뒤 frontend→employee-service의 `/api/employee/me`가 30초 대기 없이 Aurora 조회 결과를 반환, Pomerium `www`·Argo root/HR child Healthy, 최종 plan 무변경 |
| `AWS-HR-01-FIX-03 DONE` | Pomerium이 HR upstream에 signed assertion만 전달해 `X-Pomerium-Claim-Email`이 누락되던 결함을 OIDC email claim header mapping으로 보정 | `AWS-HR-01-FIX-02` | `ARGO-ROOT` | 내부 HR 사용자 | mapping은 `pass_identity_headers`를 켠 HR 두 Route에만 upstream 전달, immutable SHA에서 root·Pomerium·HR child `Synced/Healthy`, 새 ConfigMap mount를 위한 Pomerium Pod 재생성·정상 기동, 복구한 literal `main`의 세 Application `Synced/Healthy` |
| `AWS-HR-01-BOOTSTRAP-01 DONE` | 선택된 일상 Keycloak ID `imcherry5778`를 초기 HR 관리자로 bootstrap | `AWS-HR-01-FIX-03` | `TOFU-STATE`, `ARGO-ROOT`, `IDENTITY-LIVE` | 내부 HR 관리자 | Terraform 관리 bootstrap identity와 enabled Keycloak user email exact match, `tofu-app-db` bootstrap Secret version 1건 in-place 갱신·final plan 무변경, `/hr-admins` membership 단일 부여·재확인, immutable HR child PreSync migration `Succeeded`, 최신 main root·Pomerium·HR child `Synced/Healthy` |
| `AWS-HR-01-FIX-04 DONE` | 마지막 migration 뒤 갱신된 Terraform bootstrap Secret identity를 반영하도록 HR PreSync hook을 재실행 | `AWS-HR-01-BOOTSTRAP-01` | `ARGO-ROOT`, `IDENTITY-LIVE` | 내부 HR 관리자 | Secret 갱신이 이전 hook 뒤였음을 확인, enabled Keycloak user와 current bootstrap Secret exact match, immutable SHA의 현재 PreSync hook `Succeeded`, 최신 main root·Pomerium·HR child `Synced/Healthy` |
| `AWS-HR-01-FIX-05 DONE` | hook annotation만으로 새 sync가 시작되지 않던 결함을 허용된 `hr-service` Pod template migration trigger로 보정하고 현재 bootstrap identity를 DB에 반영 | `AWS-HR-01-FIX-04` | `ARGO-ROOT`, `IDENTITY-LIVE` | 내부 HR 관리자 | AppProject 거부 ConfigMap을 제거하고 허용된 Pod template trigger로 새 operation을 시작, current bootstrap identity의 HR service Pod read-only exact 조회에서 record 존재·`is_hr=true`, 최신 main root·Pomerium·HR child `Synced/Healthy` |
| `AWS-HR-01-FIX-06 DONE` | `AWS-HR-01` 병합 시 되돌리지 못한 `jenkins` Application의 검증용 immutable SHA `targetRevision`을 literal `main`으로 복구 | `AWS-HR-01-FIX-05` | `ARGO-ROOT` | Jenkins GitOps 반영 전체 | `ARGO-ROOT` 잠금 아래 `platform-root`를 이 커밋으로 전환해 `jenkins-application.yaml`의 `targetRevision: main` 반영과 `jenkins` Application의 `main` HEAD Synced/Healthy 확인, 검증 뒤 `platform-root` `main`·selfHeal 원상복구 |
| `AWS-HR-02 DONE` | Dashy에서 Board Demo 타일을 HR 직원·관리자 포털로 교체하고, Keycloak HR group으로 Dashy 표시와 Pomerium route admission을 일치 | `AWS-HR-01-FIX-05` | `ARGO-ROOT`, `IDENTITY-LIVE` | 내부 HR 사용자 | `/hr-users`·`/hr-admins` top-level group exact 존재, Dashy `www`는 두 group·`admin`은 관리자 group만 표시, Pomerium `www`는 같은 두 group·`admin`은 관리자 group만 허용, Board Demo 타일 0건, 최신 main Pomerium child `Synced/Healthy` |
| `AWS-HR-03 DONE` | 팀 일상 Keycloak ID 네 명에게 HR 직원 포털 admission group을 최소권한으로 부여 | `AWS-HR-02`, `IAM-ENROLL-01` | `IDENTITY-LIVE` | 내부 HR 사용자 | enabled daily ID `foxgeun`·`cerberos2022`·`jaeeyun`·`snsd-hybirdinfra` 각 1건을 exact-match로 확인하고 `/hr-users` membership만 1건으로 수렴, 네 ID의 `/hr-admins` membership 0건·사용자 생성/비활성화/삭제 0건·Pomerium/Dashy/AWS/HR DB 변경 0건; apply 뒤 check `users=4/4 add_needed=0 admin_membership=0` |
| `AWS-HR-03-FIX-01 DONE` | live UI에서 추가된 `foxgeun`·`jaeeyun`의 `/hr-admins` membership을 HR 포털 권한 선언 원본으로 수렴 | `AWS-HR-03` | `IDENTITY-LIVE` | 내부 HR 관리자 | `portal-group-members.json`의 `/hr-users` 4명·`/hr-admins` 3명 exact set과 enabled Keycloak user 각 1건, 허용하지 않은 두 일상 ID의 `/hr-admins` 0건, check `employee_users=4/4 admin_users=3/3 employee_add_needed=0 admin_add_needed=0`, UI 변경을 Git 선언·검증으로 흡수하고 사용자 생성/삭제·Pomerium/Dashy/AWS/HR DB 변경 0건 |
| `QUALITY-01 DONE` | SonarQube | `CAP-02`, `PG-01`, `VAULT-02`, `POM-01` | 없음 | CI quality gate | 분석·quality gate·restore·SSO·배포 직후 capacity stop/go |
| `AWX-01 DONE` | AWX | `CAP-02`, `PG-01`, `VAULT-02`, `POM-01` | 없음 | VM 구성 자동화 | inventory·credential 격리, check/apply 승인 경계 |
| `AWX-BACKLOG-01 DONE` | 설치 상태에 머문 AWX를 운영 자동화에 도입하는 보수적 직렬 백로그를 확정 ([ADR-0001](adr/0001-proxmox-bootstrap-reproducibility.md), [ADR-0004](adr/0004-zero-trust-identity-and-management-access.md)) | `AWX-01`, `SCM-02`, `NET-04`, `OBS-11`, `IAM-MIG-01` | 없음 | `AWX-02` | 저장소 선언과 완료 증거를 대조해 현재 AWX가 내부 HTTP verifier만 실행하고 운영 VM SSH·SCM project·운영 EE 증거는 없음을 명시, `imcherry5778` 실행 요청과 `imcherry5778-admin` 승인만 허용하는 RBAC·정확한 대상·가역 canary·용량 정지선을 `AWX-02`~`AWX-07`의 직렬 gate로 분리, 기존 OpenTofu·Argo CD·Prometheus 소유권과 공개 경계는 바꾸지 않음 |
| `AWX-02 DONE` | 만료 예정 AWX `runAsNonRoot` PolicyException 제거와 신규 ID 기준 최소권한 수렴 (`gitops/apps/awx/`, `policies/`) | `AWX-BACKLOG-01`, `POL-02`, `IAM-MIG-01` | `ARGO-ROOT`, `IDENTITY-LIVE` | `AWX-03` | 2026-09-03 00:00 KST 전 task·web Pod-level `runAsNonRoot` 선언과 migration Job의 별도 admission 경로를 검증한 뒤 AWX 예외 제거, operator reconciliation·migration·web/task Ready와 root·AWX·policy-baseline 최신 main `Synced/Healthy`; 첫 SSO 뒤 `imcherry5778`은 `Platform/AWX Operators`, `imcherry5778-admin`은 `Platform/AWX Approvers`만 exact membership이고 legacy 멤버십 0, 두 계정 모두 superuser·organization admin 아님, 일상 계정의 direct apply·approval과 특권 계정의 임의 execute·권한 관리 403; secret 원문 0건과 예외·CR rollback 절차 |
| `AWX-03 DONE` | AWX namespace 기본 deny와 현재 필수 흐름만 허용하는 NetworkPolicy (`gitops/apps/awx/`) | `AWX-02` | `ARGO-ROOT` | `AWX-04` | 적용 전 live socket·Service·로그로 operator, web, task, execution 구성요소의 실제 흐름을 한 번 산출하고 DNS, 구성요소 내부 통신, Pomerium→web, Kubernetes API가 필요한 주체, PostgreSQL 5432, Vault 8200, Keycloak 443만 exact 허용; 기존 OIDC 로그인과 내부 verifier workflow 성공, 허용 밖 RFC1918·TCP 22 음성 대조, OPNsense·공개 DNS/NAT 변경 0건, policy 제거 rollback과 최신 main root·AWX `Synced/Healthy` |
| `AWX-04 DONE` | Gitea read-only SCM Project와 공급망 검증된 전용 Execution Environment를 AWX 운영 원본으로 고정 (`gitops/apps/awx/`, `gitops/tools/awx-04/`) | `AWX-03`, `SCM-02`, `REG-01`, `CI-01`, `SCAN-01`, `SIGN-01` | `VAULT-CONFIG`, `ARGO-ROOT` | `AWX-05` | GitHub SSOT와 Gitea private pull-mirror의 main SHA가 같은 시점에 AWX project `scm_revision`과 일치하고 SSH deploy key는 read-only·인증된 host key·Vault external lookup만 사용; 저장소의 실제 collection·role 의존성을 포함한 EE를 Jenkins→Harbor로 build해 Trivy·SBOM·Cosign 통과 digest로 고정하고 모든 Ansible playbook syntax check 성공; `projects_persistence=false`, 신규 PVC 0, 운영 대상 job 0, `imcherry5778`은 project revision·허용 template read만 가능하고 project·EE·credential 수정과 branch override 불가, secret 원문 0건·rollback·최신 main root·AWX `Synced/Healthy` |
| `AWX-05 BLOCKED` | 같은 노드 `k3s-01` 한 대에 대한 무변경 SSH canary로 AWX machine credential·host key·실행 격리 검증 (`gitops/apps/awx/`, `infra/ansible/`) | `AWX-04` | `VAULT-CONFIG`, `ARGO-ROOT` | `AWX-06` | 전용 비인간 Linux 계정과 source 제한 authorized key, 인증된 host key, Vault external lookup Machine credential을 사용하고 sudo·become 없이 `k3s-01` exact inventory·limit, forks 1, simultaneous 금지, check 전용 template로 ping/facts 성공과 `changed=0`; AWX task→`k3s-01` TCP 22 NetworkPolicy 한 경로 외 다른 운영 host SSH와 허용 밖 port 실패, OPNsense 변경 0건, job·Pod 로그 secret 원문 0건, 실행 중 guest available 8 GiB 이상·swap 0·신규 PVC 0, 계정·key·Vault·AWX 객체 rollback과 최신 main root·AWX `Synced/Healthy` |
| `AWX-06 BLOCKED` | `netbird-01` 한 대의 가역 marker로 첫 cross-VLAN check→사람 승인→apply 경계와 rollback 검증 (`gitops/apps/awx/`, `infra/ansible/`, `infra/opnsense/`) | `AWX-05`, `NET-04` | `OPNSENSE-LIVE`, `VAULT-CONFIG`, `ARGO-ROOT` | `AWX-07` | 적용 전 OPNsense drift 없음과 인증된 host key를 확인하고 AWX task/k3s-01→`netbird-01` TCP 22만 NetworkPolicy·OPNsense exact 허용; sudo·become 없는 전용 계정 home의 marker 하나에 대해 check가 예상 변경 1건, `imcherry5778`이 workflow를 시작한 뒤 `imcherry5778-admin` 승인 전 변경 0, 승인 뒤 apply 성공·두 번째 check `changed=0`, 승인 범위에 포함된 cleanup 뒤 marker 부재; 일상 계정 direct apply·approval 403, 특권 계정은 승인·거절만 가능하고 execute·템플릿/credential 수정 403, actor·target·SCM revision·approver 감사 기록과 secret 원문 0건, 실패 시 방화벽·NetworkPolicy·계정/key rollback 및 drift 없음·최신 main root·AWX `Synced/Healthy` |
| `AWX-07 BLOCKED` | 기존 `node_exporter_baseline`을 `netbird-01` 한 대에서만 AWX의 첫 실제 운영 역할로 이관 (`gitops/apps/awx/`, `infra/ansible/`) | `AWX-06`, `OBS-11` | `VAULT-CONFIG`, `ARGO-ROOT` | VM 구성 자동화의 제한적 운영 시작 | digest 고정 EE·고정 SCM main revision·exact inventory/limit·forks 1·simultaneous/branch/extra-vars override 금지 아래 check template과 approval workflow만 노출; `imcherry5778` check·workflow 시작, `imcherry5778-admin` 승인·거절만 가능하고 양쪽의 금지 권한은 403; 승인 전 변경 0, 승인 apply 뒤 재실행 `changed=0`, `node_exporter.service` enabled·active와 Prometheus `up{job="node-exporter",instance="10.10.40.10:9100"}=1`; job에 actor·target·SCM revision·approver가 남고 secret 원문 0건, 실행 중 guest available 8 GiB 이상·swap 0·신규 PVC 0; rollback은 AWX privileged credential·sudo/key·template 권한만 회수하고 기존 node_exporter와 `OBS-11` 관측 경로는 보존, 최신 main root·AWX `Synced/Healthy` |
| `UPDATE-01 DONE` | Renovate | `SCM-01`, `VAULT-02` | 없음 | 의존성 변경 | 제한된 repo 권한, PR 생성, 자동 merge 금지 기준 |
| `SCAN-01 DONE` | Trivy image/config/SBOM 검사 | `CI-01`, `REG-01` | 없음 | 서명·배포 gate | 취약점 기준·SBOM 저장·실패 pipeline |

2026-08-10 `BOARD-DEMO-01`에서 GitHub와 Gitea private pull-mirror의 `main`을
`9880920ce7daf9a6a5e8bdc40f4c95985abe0334`로 일치시켰고, Jenkins build #6가
Trivy·SBOM·Cosign을 통과한 signed digest
`sha256:d0ca66a3fcb49145b62beeba0b28ecedd99289ecd162fba89b12ef9a37510cd1`를
Harbor에 게시했다. 전용 PostgreSQL TLS role/database와 Vault runtime/bootstrap
경계를 재적용해 `changed=0`을 확인했다. immutable root
`a3ffc1976fd5deadf1ec9a94bf0b339b732b3f54`와 child
`35fc305751e29f97ecf3b9f687a48f647a0a258c`에서 Argo root·board-demo·Pomerium이
`Synced/Healthy`였고, signed Pod Ready 및 unsigned digest의 admission 거부를
확인했다. 마이그레이션된 `imcherry5778` `/platform-users` 계정은 Pomerium을 거쳐
board health의 정확한 PostgreSQL ready 응답을 받았다. Unbound `board` alias는
내부 A `10.10.20.10` 한 건만 등록했고 내부 AAAA·공개 A/AAAA·NAT은 0건이며,
마스킹 스냅샷 갱신 뒤 OPNsense drift는 없다. 검증 뒤 root·Pomerium은 literal
`main`의 `Synced/Healthy`로 복구했다.

2026-08-11 `BOARD-DEMO-02`는 라이브 검증 중 `gitops/root/jenkins-application.yaml`의
`targetRevision`이 이미 병합된 `AWS-HR-01`(커밋 `1ee04f0`)의 검증용 immutable SHA로
남아 `main`을 추적하지 못하는 결함을 발견해 별도 `AWS-HR-01-FIX-06`으로 분리했다.
그 결함 상태에서 `platform-root` selfHeal이 `jenkins` Application을 그 고정 SHA로
계속 되돌리는 바람에, 이미 삭제한 `kv/board-demo/jenkins` Vault path를 여전히 참조하는
구 설정으로 Jenkins Pod가 반복 재기동되며 몇 분간 기동 실패를 겪었다. `platform-root`의
automated sync를 완전히 끄고 안전한 커밋의 렌더된 manifest를 직접 `kubectl apply`해
즉시 복구했고, 재생성된 `board-demo-image-build` job과 두 credential을 다시 삭제해
확인했다. `AWS-HR-01-FIX-06`이 main에 병합되기 전까지는 `platform-root`의 automated
sync를 의도적으로 끈 상태로 남겨뒀다 — 다시 켜면 `jenkins`가 같은 고정 SHA로 재발한다.
| `SIGN-01 DONE` | Cosign 서명·검증 방식 확정과 구현 | `REG-01`, `SCAN-01`, `VAULT-02` | 없음 | Kyverno | 키 소유·회전·복구, 서명·검증·거부 테스트 |
| `POL-01 DONE` | Kyverno Audit + namespace NetworkPolicy 기준선 | `GITOPS-01`, `POM-01` | 없음 | 모든 workload | 위반 report, DNS·ingress·필수 egress 회귀 없음 |
| `POL-01-FIX-01 DONE` | `pomerium` default-deny에서 누락된 Dashy → Keycloak egress 보정 | `POL-01` | 없음 | Dashy Portal 로그인 | Dashy Keycloak discovery 도달 양성과 `token verification failed` 신규 0건, Vault 8200·Gitea 3000 음성 유지, headless 브라우저 보호 route 200·그룹 타일 표시, Pomerium error 로그 0건, 목적지 축소 3형태(svclb `podSelector`·노드 IP `ipBlock`·단독 port 규칙) 차단 실측, main rollback 뒤 `Synced/Healthy` |
| `E2E-01 DONE` | Gitea→Jenkins→Sonar→Harbor→Trivy→Cosign→Argo E2E | `CI-01`, `QUALITY-01`, `SIGN-01`, `POL-01` | 없음 | 정책 Enforce | 정상 artifact 배포와 변조·미서명 artifact 차단 |
| `POL-02 DONE` | 검증된 Kyverno 정책만 Enforce | `E2E-01` | 없음 | 모든 배포 | 예외 만료, rollback, 정상 릴리스 회귀 없음 |
| `FALCO-01 DONE` | Falco runtime rule·출력 기준선 | `E2E-01`, `POL-01` | 없음 | Wazuh·Shuffle | 전용 테스트 이벤트 탐지, noise 기준, 대응 runbook 초안 |

2026-08-10 `AWS-CI-FIX-01`에서 state 없는 app root는 새 `v1` key namespace의 404를
정상 최초 상태로 판정했다. GitHub read-only deploy key, exact state/lock policy와 실제
`DescribeAvailabilityZones` 응답으로 확인한 read policy를 분리했고, Jenkins build 10(network)·
11(ECR)이 각각 plan-only `SUCCESS`와 민감값 0건을 통과했다. public IP 자동 할당·전체 egress·
mutable ECR tag를 제거하고, provider 압축 해제는 Pod 수명 scratch `emptyDir`에서만 수행한다.
검증 뒤 root·Jenkins는 `main`의 `Synced/Healthy`로 복구했다. AWS 리소스와 state 객체는 만들지
않았으며 첫 apply는 별도 administrator bootstrap 승인으로 남긴다.

2026-08-02 `CAP-02`에서 핵심 서비스와 백업 배포가 끝난 현재값을 읽기 전용으로 재측정했다.
Proxmox는 available RAM 41.30 GiB·swap 0, thin data/metadata 3.00%/0.33%, `/` 5%,
15분 load 0.30이고 VM 5대 배정은 18 vCPU·RAM 회계 41.00 GiB·disk 572 GiB다.
각 게스트는 RAM·root 여유가 정상이며, k3s 실행 Pod 22개 합계는 67m·2,068 MiB,
Node는 173m·4,426 MiB, PVC 요청은 5.125 GiB다. 모든 stop 기준에 여유가 있어
`SCM-01`·`REG-01`·`QUALITY-01`·`AWX-01` 진입은 `GO`로 판정한다. 추가 Pod에서 먼저
접근할 가능성이 큰 경계는 `k3s-01` RAM이며 12 GiB 경고까지 7.58 GiB가 남았다.
CAP-02의 모든 직접 후속은 다른 선행도 `DONE`이므로 네 작업만 `READY`로 연다.

2026-08-03 `CAP-03` 승인 전 준비에서 strict SSH 읽기 전용 실측과 현재 OpenTofu state의
무변경 baseline plan을 완료했다. Proxmox host available은 29,864,136,704 bytes
(27.813 GiB), swap 사용 0, thin data/metadata 5.76%/0.43%, `/` 사용률 5%, 15분 load
0.52다. 현재 VM RAM 회계는 41 GiB이고 증설 후 45 GiB로 52 GiB 경고선보다 7 GiB
낮다. `k3s-01`은 VMID 120, running, `memory=24576`, `balloon=0`이며 guest available은
9,857,167,360 bytes(9.180 GiB), swap 0, root 여유 84%, PVC 요청 75.125 GiB다.
4 GiB를 더하면 guest available 단순 예상은 13.180 GiB로 Wazuh 재진입선 11 GiB보다
2.180 GiB 높다. baseline plan은 5개 state resource 모두 `no-op`, 비통과 check 0건이다.
실제 OpenTofu apply와 `k3s-01` 정상 재부팅은 승인 전이라 수행하지 않았으며
[CAP-03 runbook](runbook/k3s-ram-expansion.md)의 검증된 `0 add, 1 change, 0 destroy` binary
plan과 rollback 절차로만 진행한다.

2026-08-03 `CAP-03`에서 승인 plan SHA
`f8d311c0a424abfaa66d54c0140165c9906774bd63f284eb8fb826dd0cf0e3d0`을 실제 state에 적용해
VMID 120의 memory만 `24576→28672`, balloon 0으로 바꿨다. OS 재부팅은 QEMU pending memory를
활성화하지 않아 승인된 cold start 한 번으로 boot ID
`4e745572-8cf3-4bd2-91c2-a572ad45a382`, guest `MemTotal=29,154,533,376 bytes`를 확인했다.
Vault는 저장소 밖 unseal key threshold `3/3`으로 `sealed=false` 복구했고, CrowdSec은 재부팅
뒤 비멱등 `emptyDir` init의 정확한 Pod만 교체했다.

Falco는 root UID inotify instance `127/128` 고갈을 `256` 영구 선언으로 보정하고, 재생성 때
드러난 POL-02 누락은 만료 없는 exact Pod·DaemonSet 예외와 전용 보상 Enforce 정책으로
해결했다. immutable root `8c299322a49a0bcf55edc39309f69ed305e762cc`, 설정
`bc8da181eecc00392585311628a2a7f3bbdb73de`에서 권한 상승 음성 표본이 거부되고 실제 Falco
Pod UID가 `0a0451fd-739a-439b-8918-95ec8ee6a330→697979bc-7471-4f85-bb3a-33478ef4b1d9`로
바뀌어 Ready·restart 0, 신규 admission 거부 0건이었다. 검증 뒤 시작 main으로 rollback해
root·policy-baseline·Falco가 `Synced/Healthy`, child 선언이 literal `main`임을 확인했다.

최종 Proxmox available은 35,921,670,144 bytes·swap 0, `k3s-01` available은
16,839,221,248 bytes(15.683 GiB)·swap 0, root 사용률 16%, PVC는 75.125 GiB다. Wazuh 3 GiB
반영 후에도 12.683 GiB로 8 GiB 정지선 위이며 Wazuh 포함 PVC 91.125 GiB는 96 GiB 경고선
미만이다. 최종 OpenTofu plan은 resource 5개 모두 `no-op`, 변경·비통과 check 0건이고 state
SHA는 불변이었다. 따라서 `CAP-03`을 `DONE`으로 닫고 모든 선행이 끝난 직접 후속
`WAZUH-01`을 `READY`로 연다.

2026-08-03 `SOAR-01` 진입 판정을 `CAP-04`로 분리한다. `WAZUH-01` 배포 후 `k3s-01` available은
14,584,446,976 bytes(13.583 GiB)로 12 GiB 경고선 위이고 PVC 선언 합계는 91.125 GiB로 96 GiB
경고선 안이다. 지금 상태는 어느 정지 기준도 넘지 않는다.

문제는 Shuffle이 Wazuh indexer와 별도로 자체 OpenSearch를 요구한다는 점이다. 둘을 한
클러스터로 합치면 Wazuh가 고정한 indexer 버전과 Shuffle의 지원 버전이 묶이고, ISM과 디스크
watermark가 섞여 한쪽 압박이 보안 이벤트 수집을 멈출 수 있다. SOAR가 SIEM의 가용성을 잡는
구조는 사고 대응 중에 가장 나쁜 시점으로 나타나므로 분리 배포를 전제로 용량을 잡는다.

`CAP-04`는 증설을 전제하지 않는다. 먼저 Shuffle 공식 최소 요구량으로 진입선(8 GiB 정지선 +
Shuffle 최소)을 계산해 실측과 대조하고, 미달일 때만 `k3s-01`을 28 GiB에서 32 GiB로 올린다.
32 GiB는 배정 회계를 45 GiB에서 49 GiB로 만들어 52 GiB 경고선 안에 남지만 36 GiB는 53 GiB가
되어 경고선을 넘으므로 이 lane의 상한은 32 GiB다. PVC는 Shuffle 몫을 더하면 96 GiB 경고선을
넘을 수 있으나 120 GiB 정지선과는 구분해 판정한다. 경고는 배포 금지가 아니라 재예산 신호다.

`SOAR-01`의 완료 증거에는 용량 gate가 없었다. `WAZUH-01`이 gate에서 STOP한 뒤 `CAP-03`을
신설한 순서를 반복하지 않도록 `CAP-04`를 선행으로 걸고 배포 직전 gate와 OpenSearch 분리를
완료 증거에 넣는다. 따라서 `SOAR-01`은 `READY`에서 `BLOCKED`로 되돌린다.

2026-08-03 `CAP-04`에서 [Shuffle 공식 self-hosted 설치 최소](https://github.com/Shuffle/Shuffle/blob/main/.github/install-guide.md)인
available RAM 4 GB를 4 GiB로 보수 적용해 `SOAR-01` 진입선을 12 GiB(8 GiB 정지선 + 4 GiB)로
고정했다. 현재 `k3s-01` available은 14,481,977,344 bytes(13.487 GiB), swap 0, root 여유
82%로 진입선보다 1.487 GiB 높다. Proxmox available은 27,532,869,632 bytes(25.642 GiB),
swap 0, thin data/metadata 6.23%/0.44%, `/` 사용률 5%, load15 0.70이고 VM RAM 회계는 45 GiB로
52 GiB 경고선보다 7 GiB 낮다.

PVC 선언 합계 91.125 GiB에 Wazuh indexer와 분리한 Shuffle 전용 OpenSearch 16 GiB와 file data
4 GiB를 배정하면 111.125 GiB다. 이는 96 GiB 경고선을 15.125 GiB 넘지만 120 GiB 정지선보다
8.875 GiB 낮으므로 **경고·GO**다. `SOAR-01`은 이 20 GiB 상한과 배포 직전 120 GiB 미만 gate를
지키며, Wazuh 원본 event를 자기 OpenSearch에 중복 보존하지 않는다.

증설 조건이 성립하지 않아 OpenTofu 선언·state, VM 전원, Kubernetes와 Vault를 바꾸지 않았고
live 변경은 0이다. 최종 plan SHA
`31a59bdd3c3e5363b0e2d0ced701afbc3a47b35dd84d86e6022db2aa4f28a59b`은 resource 5개 모두
`no-op`, 변경·비통과 check 0건이며 plan 전후 state SHA
`b6275be5d8ea2ffcdc5cb327c2a31857ea219f445581d0eaffb9828f2cbf68ea`가 불변이다. 따라서
`CAP-04`를 `DONE`으로 닫고 모든 선행이 충족된 직접 후속 `SOAR-01`만 `READY`로 연다.

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

2026-08-02 `AWX-01`에서 AWX Operator `2.19.1`과 AWX `24.6.1`을 외부
`postgres-01` 전용 DB·최소권한 role, Vault KV v2와 명시적 Vault Agent init,
digest 고정 이미지로 배포했다. Pomerium은 정확한 `claim/groups` 두 개만 허용하고 AWX
Keycloak OIDC 뒤에서 `AWX Operators`와 `AWX Approvers` object role을 분리한다. 정적 운영
inventory는 `docs/ip-plan.md`의 canonical VM 5대와 동적 source 0건으로 일치했고, 모든 실제
job은 선택지 (b)의 cluster 내부 verifier 한 host로만 제한했다. 따라서 이 완료 증거는 실제
운영 대상의 cross-VLAN SSH 접근 증거가 아니며, 해당 방화벽·통신표는 `NET-04`가 소유한다.

같은 시점에 허용 credential job `9` 성공과 미할당 template·credential 403을 대조했고
Git·AWX Pod 로그·job stdout의 비밀 원문은 0건이었다. operator의 apply 직접 실행과 approval은
403이었고 privileged approver가 승인한 workflow `10`만 성공했다. 배포 직후 `k3s-01` guest
available은 `15,598MiB`, swap 0으로 12/8GiB 경고·정지 기준 밖이어서 **GO**다. 검증 설정 SHA
`b9c94e63af4ea4dbfd0961304576d74dd3ad765f`와 root pointer
`dabfd737fae340b3259e22a689512d5a0ea04814`에서 root·AWX·Pomerium이 `Synced/Healthy`였고,
시작 main `ee5c0280df4e9f29dc5f3dbdd1db9891ab8f2322`로 rollback해 root의
`Synced/Healthy`와 AWX 리소스 정리를 확인했다. 최종 child 선언은 `main`이다. 현재 백로그에서
당시 `AWX-01`을 선행으로 갖는 작업은 없어 새로 `READY`로 연 직접 후속은 없었다.

2026-08-13 `AWX-BACKLOG-01`에서 이 내부 verifier 완료 증거를 운영 SSH 성공으로 확대 해석하지
않고, `AWX-02`부터 `AWX-07`까지 한 단계가 다음 단계의 권한·네트워크 전제가 되는 직렬 lane으로
분리했다. 첫 실행 대상은 데이터·접근 중계 VM이 아닌 기존 관측 canary `netbird-01` 한 대이며,
`AWX-06`은 sudo 없는 marker로 실제 변경·승인·cleanup을 먼저 증명하고 `AWX-07`에서만 기존
`node_exporter_baseline`의 privileged 실행을 허용한다. `imcherry5778`은 check와 workflow 시작,
`imcherry5778-admin`은 승인·거절만 담당하며 어느 계정에도 AWX 관리자 권한을 주지 않는다.

`AWX-07` 완료만으로 fleet 확대·schedule·job slicing·동시 실행·ad hoc command·Proxmox·OPNsense·
OpenTofu·k3s server 재시작 자동화를 열지 않는다. 같은 고정 대상의 수동 실행이 서로 다른 날에
3회 연속 성공하고 각 실행의 두 번째 check가 `changed=0`, Prometheus 정상, capacity 정지선 미진입,
권한 우회 0건일 때만 별도 백로그로 재검토한다. AWX는 Git의 desired state, Argo CD의 Kubernetes
application 소유권, Prometheus의 지속 상태 판정을 대체하지 않는다.

2026-08-02 `UPDATE-01`에서 Renovate `44.6.0` 공식 image를 digest로 고정하고 전용
AppProject·child Application·namespace·ServiceAccount와 매주 단발 `CronJob`으로 배포했다.
Gitea HTTP Git은 계속 끈 채 API는 내부 `gitea-http:3000`, Git data는 `gitUrl=ssh`와 정확한
`insteadOf` 치환으로 `gitea-ssh:2222`를 사용한다. Renovate가 process environment의 unsafe
Git config를 child process에 전달하지 않는 44.6.0 동작에 맞춰 전역 `customEnvVariables`만
사용한다. `renovate` non-admin bot은 `scm-recovery/platform-smoke` 한 곳의 write collaborator며
PAT scope는 `write:repository`·`read:user`·`write:issue`·`read:organization`으로 제한했다.
PAT·SSH private key·pinned host key는 `kv/renovate/runtime`에서 전용 Kubernetes auth role과
Vault Agent init이 memory `emptyDir`로 렌더링하고, 상시 container에는 ServiceAccount token을
마운트하지 않는다. 자동 merge와 platform automerge는 top-level·npm rule에서 모두 false다.

같은 bot PAT로 대상 repo branch write `201`과 admin API `403`을 대조했다. smoke repo에
`update01-lodash-smoke` npm alias의 낡은 `lodash 4.17.20` 한 건을 임시 commit하고 Job을 한 번
실행해 Renovate PR `#2` 정확히 한 건이 `open`, `merged=false`로 남은 것을 확인했다. 배포 직후
Node는 `214m`·`7817Mi`, metrics Pod 29개 합계는 `64m`·`4724Mi`, Renovate Pod 표본은
`264m`·`9Mi`, k3s guest available은 `15,961MiB`, root 사용은 `9%`, PVC 요청 합계는 4개
`15,488MiB`였다. RAM 12/8GiB, root 여유 25/20%, PVC 96/120GiB 경고·정지 기준 밖이어서
**GO**다. 검증 설정 SHA `5c33ff5903098b26474f29793070bd1b9807f57c`와 root pointer
`4a325059acaab91df2e3dbed682646175b293438`에서 root·Renovate가 `Synced/Healthy`였다.
PR·Renovate/permission branch·seed·Job·로컬 key 사본을 정리하고 시작 main
`1d9825af9997238904026b346ec4a975cb6482aa`로 rollback해 root `Synced/Healthy`와 child·namespace·
AppProject 부재를 확인했다. 운영 bot/PAT/key와 Vault role·policy·KV는 정기 실행을 위해 유지하며
최종 child 선언은 `main`이다. `UPDATE-01`을 직접 선행으로 갖는 작업은 없어 새로 `READY`로 여는
직접 후속은 없다.

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
복구했다. `E2E-01`은 `CI-01`·`SIGN-01`이 남고 `FALCO-01`은 `E2E-01`이 남으므로
둘 다 `BLOCKED`를 유지하며 새로 여는 직접 후속은 없다.

2026-08-02 `QUALITY-01`에서 SonarQube Community Build `26.7.0.124771-community`를
digest로 고정해 전용 AppProject·child Application·namespace에 배포했다. 관계형 원본은
`postgres-01`의 전용 `sonarqube` DB와 최소권한 `sonarqube_user`가 소유하며 JDBC는
`sslmode=verify-full`이다. DB 암호와 scanner project token은 Kubernetes Secret 없이
전용 ServiceAccount의 명시적 Vault Agent init이 KV v2에서 memory `emptyDir`로만
렌더링한다. 내장 Elasticsearch 요구값 `vm.max_map_count=524288`은 privileged init 대신
`k3s_baseline` role의 노드 sysctl로 선언했고 k3s·Traefik은 재기동하지 않았다.

작은 JavaScript 두 project의 최신 분석은 `2026-08-02T08:50:21Z`와
`2026-08-02T08:50:35Z`에 기록됐고 같은 `coverage < 80%` gate에서 `OK`와 `ERROR`로
대조됐다. DB dump를 별도 DB·Pod·PVC에 복원해 같은 project·분석 시각을 조회한 뒤
복원 DB·role·Pod·PVC·Vault 임시 자원과 dump를 제거했다. 같은 시점 실제 browser에서
`imcherry`의 Pomerium 허용·Keycloak SAML session 성공과 허용 group이 없는
`imcherry-admin`의 Pomerium `403`을 대조했고, 내부 SSH port-forward의 local admin
복구 login도 성공했다.

배포 전 `k3s-01` guest available은 19.58 GiB였다. 배포 직후에는 12,895 MiB,
SonarQube Pod 2,669.42 MiB, guest swap 0, PVC 요청 합계 45.125 GiB였고 Proxmox
available 28,947 MiB·swap 0, thin data/metadata 4.77%/0.39%로 모든 정지 기준 밖이어서
**GO**다. 승인된 `OPNSENSE-LIVE` 변경으로
`sonar.imcherry5778.xyz → k3s-01 (10.10.20.10)` Unbound alias를 추가하고 sanitized
snapshot을 같은 커밋에 갱신했다. UI는 Pomerium의 정확한 `claim/groups`와 제품 내장
Keycloak SAML을 연속 통과하며, scanner API는 외부 bypass 없이 ClusterIP와
project-scoped token으로 분리했다. 검증 설정 SHA
`2a25b12c05c0a29989df6336f80e49ca0b779536`와 root pointer
`319c6aae82677f66860877bdc41e5e0b4bc935cc`에서 root·Pomerium·SonarQube가
`Synced/Healthy`였다. 시작 main
`430ee4af8435f3df8329deeea030ca80e6e4a012`로 복귀하고 최종 child 선언은 `main`이다.
직접 후속 `E2E-01`은 `CI-01`과 `SIGN-01`이 남아 `BLOCKED`를 유지하며 새로 여는
직접 후속은 없다.

2026-08-02 `REG-01`에서 Harbor `2.15.1`·chart `1.19.1`과 모든 image digest를 고정해
전용 AppProject·child Application·namespace에 배포했다. registry layer·manifest는
`object-01`의 SeaweedFS S3 `harbor-registry` bucket과 bucket-scoped
`reg-01-harbor` identity만 사용하고, 관계형 상태는 `postgres-01`의 전용 `harbor` DB와
최소권한 `harbor_user`가 `sslmode=verify-full`로 소유한다. core·jobservice·registry는
Kubernetes Secret 없이 각 Pod의 명시적 Vault Agent init이 KV v2 값을 memory `emptyDir`에
렌더링한다. Redis는 in-cluster 단일 replica이며 내장 Trivy는 껐다.

UI는 Pomerium의 정확한 `claim/groups` 뒤에 두고 `/v2/`와 `/service/`는 Pomerium을 우회해
Harbor local·robot 인증이 직접 판정하도록 분리했다. 승인된 `OPNSENSE-LIVE` 변경으로
`harbor.imcherry5778.xyz → k3s-01 (10.10.20.10)` Unbound alias를 추가하고 sanitized
snapshot을 같은 변경에 갱신했다. SeaweedFS의 기존 volume slot 10개가 모두 배정된 실제
실패를 확인한 뒤 별도 승인으로 max를 15로 올렸으며 volume → filer → S3만 재시작하고
기존 ID `1`, `10`~`18`과 master를 유지했다.

최종 완료 증거 실행에서 project-scoped robot이 `reg01-evidence`에 BusyBox manifest를
push하고 다른 Podman client가 같은 digest
`sha256:7a3ebe5bfd1a4a19797d20b0c0bb39d44393e9a03fd852c0865b0f540d868df0`를 pull했다.
같은 robot의 지정 project push/pull 성공과 `reg01-denied` push 거부를 대조했고, retention
execution `10`은 `remove` tag를 실제 삭제하면서 `keep`을 보존했다. 같은 시점 DB dump와 S3
bucket inventory로 격리 `harbor-restore`를 올려 같은 digest를 pull한 뒤 namespace·DB·dump·
임시 Vault binding과 검증 project·robot·policy를 제거했다. Harbor PVC는 0, 전체 PVC 요청은
45.125 GiB, DiskPressure는 `False`여서 capacity stop/go는 **GO**다.

검증 설정 SHA `5f45a066285b525ed8d4689b1049788f67125584`와 root pointer
`7df845023a6152dbc6ec9a18836e82f1ed505f68`에서 root·Harbor·Pomerium·policy-baseline이
`Synced/Healthy`였다. 시작 main `f031b24c9e3b7215656cf36ecea809c42d9cf5a4`로 rollback해
root `Synced/Healthy`와 Harbor Application·namespace 부재를 확인했고 최종 child 선언은
`main`이다. 직접 후속 `CI-01`은 `SCM-01`·`REG-01`·`VAULT-02`가 모두 끝나 `READY`로 연다.
`SCAN-01`은 `CI-01`, `SIGN-01`은 `SCAN-01`이 남아 `BLOCKED`를 유지한다.

2026-08-02 `CI-01`에서 Jenkins `2.568.1-lts-jdk21`을 digest로 고정해 전용 AppProject·child
Application·namespace에 배포했다. 플러그인은 최상위 11개와 전이 의존성을 합친 58개 전부를
`stable` update center의 core 2.568.1 기준선에서 정확한 버전으로 고정하고 init container의
`jenkins-plugin-cli --latest=false`가 그 목록만 설치한다. controller 설정, Kubernetes cloud,
agent Pod template, credential과 pipeline job은 모두 JCasC와 Job DSL이 소유하며 UI 수동
설정은 없다. controller는 `numExecutors: 0`이라 build를 직접 실행하지 않고 `podRetention:
never`인 동적 agent Pod만 쓴다.

빌드 도구는 Kaniko가 2025-06-03 upstream archive로 유지보수를 멈춰 rootless Buildah `1.43.1`을
택했다. 비특권 Pod에는 `newuidmap` 권한이 없어 단일 UID 매핑으로 떨어지므로 vfs storage와
`ignore_chown_errors`, `--isolation chroot`, `SYS_CHROOT` 하나만 조합했다. 라이브에서 같은
UID·capability의 두 container를 붙여 `RuntimeDefault` seccomp가 `CAP_SYS_ADMIN` 없는
`unshare(CLONE_NEWUSER)`를 거부하고 `Unconfined`는 통과함을 확인했다. 남은 대안이
`CAP_SYS_ADMIN` 부여뿐이라 더 작은 완화인 seccomp를 `buildah` container 하나에만 적용했고
`jnlp`는 `RuntimeDefault`를 유지한다. 근거와 재검토 조건은
[`gitops/apps/jenkins/README.md`](../gitops/apps/jenkins/README.md)가 소유한다.

비밀은 Kubernetes Secret 없이 Pod-local Vault Agent init이 `kv/jenkins/runtime`의 다섯 값을
memory `emptyDir`에 mode `0400`으로 렌더링하고 JCasC가 `SECRETS` 디렉터리로 읽는다(ADR-0013).
사람 입력은 `$KTC_SECRET_ROOT/jenkins/env` mode `0600`의 `JENKINS_ADMIN_PASSWORD` 하나뿐이고
저장소 안 `.env`는 없다. Gitea는 `SCM-01` 경계를 되돌리지 않고 repo 하나에만 붙은 read-only
deploy key로 `gitea-ssh:2222`만 쓰며 host key는 Gitea가 이미 소유한 공개키를 JCasC
`manuallyProvidedKeyVerificationStrategy`로 고정했다. Harbor push는 `ci01-evidence` 전용
project-scoped robot만 쓰고 `REG-01`이 만든 `/v2/` 직접 인증 경로를 그대로 쓴다. controller의
Kubernetes API token은 kubelet 자동 마운트가 아니라 별도 projected volume이며 RBAC는 자기
namespace의 Pod·pods/exec·pods/log·events뿐이다.

`ci01-image-build` build `6` 한 번의 실행에서 완료 증거 세 가지를 함께 얻었다. pipeline이
robot secret을 일부러 stdout으로 흘렸고 콘솔에는 `****`만 남았으며, 콘솔·controller·agent 두
container 로그를 포함한 6개 파일 전체에서 robot secret·local admin 암호·deploy key 본문의 평문은
0건이었다. 실행 중 agent Pod `ci01-buildah-g772m`을 한 번 조회해 `runAsNonRoot=true`,
`runAsUser=1000`, 두 container 모두 `allowPrivilegeEscalation=false`·`privileged=false`·
`capabilities.drop=[ALL]`이고 volume은 configMap 1개와 emptyDir 2개뿐이며 hostPath·Docker
socket·ServiceAccount token이 없음을 확인했다. build 셸의 실제 uid도 `1000`이었다. Gitea SSH
clone 뒤 rootless buildah가 만든 이미지를 `ci01-evidence`에 push해 Harbor artifact digest
`sha256:85c4777e135cc1015e12c4bdda37771d752f8b31df4dad276da3dfe0b7e67dc0`가 pipeline 출력과
일치했고, 같은 robot의 `ci01-denied` push는 `authentication required`로 거부돼 그 project의
repository는 0건이었다.

배포 직후 capacity는 `k3s-01` available `11,603MiB`·swap 0·root `13%`, PVC 요청 합계
`65.125GiB`(JENKINS_HOME 20 GiB 포함), Proxmox available `28,845MiB`·swap 0, thin
data/metadata `5.10%/0.40%`, DiskPressure `False`로 모든 정지 기준 밖이어서 **GO**다. 다만
`k3s-01` RAM은 12 GiB 경고선 아래로 들어왔으므로 `SCAN-01` 이후 배포는 이 값을 먼저 본다.
승인된 `OPNSENSE-LIVE` 변경으로 `jenkins.imcherry5778.xyz → k3s-01 (10.10.20.10)` Unbound
alias(uuid `30919061-974b-4287-b7ba-1545017a72fa`) 한 건을 추가하고 sanitized snapshot을 같은
커밋에 갱신했다. UI는 Pomerium `claim/groups=/platform-users` Route 뒤에서 sign-in `302`를
반환하고 Jenkins local realm이 다시 판정하며, agent의 inbound JNLP는 cluster 내부
`Service/jenkins-agent:50000`만 쓴다. 공개 DNS·NAT·방화벽 규칙은 바꾸지 않았다.

검증 도중 두 번의 실패를 이 브랜치 안에서 원인 특정 후 고쳤다. `checkout scm`은 `scm` 전역
변수를 제공하는 `workflow-multibranch`를 요구해 최소 플러그인 집합을 지키려 명시적 GitSCM
checkout으로 바꿨고, JCasC의 `DefaultCrumbIssuer.excludeClientIPFromCrumb`은 2.568.1에 없는
속성이라 제거했다. 검증기 자체 결함도 두 건 고쳤다. `jq`의 `//`가 `false`도 대체 대상으로
보아 `.building // true`가 build 완료를 영원히 감지하지 못했고, 종료된 log follower에 대한
`kill` 실패가 `set -e`로 판정 직전에 중단시켰다. 같은 local port를 잡은 다른 실행의 tunnel을
조용히 재사용하지 않도록 port 선점 가드도 넣었다.

검증 설정 SHA `f58b0b30a7c2bbcf7ac3412ad83dbe340ffc6107`와 root pointer
`4e47edb00e5d160b7afaaebe62344046c2a90112`에서 root·Jenkins·Pomerium이 `Synced/Healthy`였다.
시작 main은 `58459932387eb9b72470f55904b1aeeded19015b`이며 최종 child 선언은 `main`이다.
직접 후속 중 `SCAN-01`은 선행 `CI-01`·`REG-01`이 모두 충족돼 `READY`로 열고, `E2E-01`은
`SIGN-01`이 남아 `BLOCKED`를 유지한다.

2026-08-02 `SCAN-01`에서 Trivy `0.72.0`과 ORAS `1.3.3` image를 digest로 고정해 기존
Jenkins 동적 agent에 별도 container로 추가했다. 선언형 bootstrap Job과 6시간 CronJob만
공식 DB/checks OCI repository에 나가며 1 GiB PVC를 갱신한다. build는 read-only cache와
24시간 freshness marker만 사용한다. source config는 `HIGH,CRITICAL`, image는 fix 가능한
`HIGH,CRITICAL`에서 실패하고, 예외에는 경로/PURL·사유·만료일을 모두 강제한다. 통과 image의
CycloneDX JSON은 Jenkins archive 대신 immutable Harbor image digest의 OCI accessory로 저장해
`SIGN-01`이 같은 subject를 이어받는다.

완료 증거는 pipeline build `2`·`3`으로 얻었다. build `2`의 취약점 기준 통과와 image digest
`sha256:50ac62320ee4ebce0da8cb6c05bac072da3c07cb31559487a1f3fb1028a63fe3`, 연결된 CycloneDX
artifact digest `sha256:ced6c83cd50d2324bef40f8a4b625fc266bed96c128cf5e01b2bc22c9a0eeb5e` 및
`application/vnd.cyclonedx+json` type을 Harbor API로 확인했다. build `3`은 고정 Alpine
3.18.0의 fix 가능한 `HIGH,CRITICAL`에서 `FAILURE`가 됐고 tag·push·release handoff는 모두
없었다. 최초 build `1`은 image gate 전에 잘못 적용된 local archive auth 경로로 실패해 원인을
같은 Buildah image로 재현·수정한 뒤, 승인받은 두 build만 추가했다.

배포 직전/직후 `k3s-01` available은 `11,781/11,585MiB`, pass agent 실행 중은
`11,283MiB`, swap은 0이었다. PVC 요청 합계는 `66.125GiB`로 Trivy cache 1 GiB만 늘어
stop/go는 **GO**지만 12 GiB 경고 구간이다. 검증 시 root
`ac14432edbf21c546351b04e8307cce057475665`와 Jenkins 설정
`b1c332df4f52e0f18eda2615a80708b3a3f09b85`는 `Synced/Healthy`였다. 시작 main
`a3870b2858db269ee28ad3e1c5502ae4820a8979`로 rollback한 뒤 root·Jenkins를 mutable `main`의
`Synced/Healthy`로 복구했고 최종 child 선언은 `main`이다. 직접 후속 `SIGN-01`은
`REG-01`·`SCAN-01`·`VAULT-02`가 모두 `DONE`이므로 `READY`로 연다.

2026-08-02 `SIGN-01`에서 라이브에 없는 Vault transit은 새 token 전달 경계를 요구하므로,
기존 Vault Agent memory `emptyDir` 소비 경계를 유지하는 KV v2 키쌍을 채택했다. 최초 생성
version 2/generation 1, 회전 version 3/generation 2, version 2에서 새 current로 복구한
version 4/generation 3을 실증했고, 최종 key ID는
`sha256:d8fd0bd410281f1827770b82518ee9738d0a17be6d64021800ceab049c1b1be2`다.

완료 증거 pipeline build `6`은 SCAN-01 image digest
`sha256:50ac62320ee4ebce0da8cb6c05bac072da3c07cb31559487a1f3fb1028a63fe3`와 CycloneDX
accessory digest `sha256:ced6c83cd50d2324bef40f8a4b625fc266bed96c128cf5e01b2bc22c9a0eeb5e`의
current-key signature를 검증하고 release handoff를 냈다. build `7`은 고정된 다른 공개키에서
Cosign signature threshold mismatch로 `FAILURE`가 됐고 서명 추가·scan stage·release
handoff는 없었다.

최종 적용 직전 `k3s-01` available RAM은 `11,472MiB`, swap은 0으로 12 GiB 경고 구간이지만
8 GiB 정지선 위의 **GO**였다. 검증 시 Jenkins 설정
`d2e61fd62767b7d01722fb2600dbf936d719cee4`와 root pointer
`06c194aec60afe9fa6eb40a39bb2c94fcb1e90fc`는 `Synced/Healthy`였다. 시작 main
`c05892d1306eb18785525022fa80cea119863b2d`로 rollback한 뒤에도 root·Jenkins를
`Synced/Healthy`로 복구했고 최종 child 선언은 `main`이다. 직접 후속 `E2E-01`만 모든
선행이 충족돼 `READY`로 열었고 `POL-02`·`FALCO-01`은 `E2E-01`이 남아 `BLOCKED`를 유지한다.

2026-08-02 `E2E-01`에서 `gitops/apps/e2e-01/`의 전용 namespace·Vault one-shot bootstrap·
공개키 이름 한정 RBAC·namespaced Kyverno `verifyImages` Enforce와 root child를 추가하고,
기존 Jenkins 선언·Gitea seed·`gitops/tools/e2e-01/` 검증기를 동적 digest handoff에 맞췄다.
새 상시 Deployment·Service·PVC 없이 시작 직전 `k3s-01` available RAM `11,611MiB`·swap 0으로
12 GiB 경고 구간이지만 8 GiB 정지선 위의 **GO**를 판정했다. pipeline build `9` 한 번이
Gitea checkout과 Sonar quality gate, Trivy gate, Harbor push, CycloneDX accessory, Cosign
서명·검증을 통과해 signed digest
`sha256:63adb1c8496736c1e9af53e7a4154a8044b184f5b0de41104b9cb483957a0996`와 같은 repository의
미서명 digest `sha256:48b802b4862f301af740acc6d0589ca1677289637a7ffd95bc46ea202495244e`를 넘겼다.
검증 설정 SHA `05d5f397a3f64fe38b44c0036fe8823e01948944`와 root pointer
`737d7c71f8a4315447a361779b838e0619703bc8`에서 Argo CD가 signed digest Pod
`e2e-01-release`를 `Running/Ready`로 만들었고, 같은 경로의 미서명 digest는
`e2e-01-verify-release-image` admission에서 거부돼 Pod가 0건이었다. cleanup 설정
`e98d00f3c0a5636effdf0a8c201306c97d199ae9`와 pointer
`843a613b73eeb9c05fb8f720ea342835c81f97bf`에서 증거 Pod 부재와 root·Jenkins·E2E child의
`Synced/Healthy`를 확인한 뒤 시작 main `1ed4b9e09717e7d5ee9f5a69315b86c6ab8e4c8f`로
rollback해 E2E Application·namespace·AppProject를 제거하고 root·Jenkins를
`Synced/Healthy`로 복구했으며 Gitea seed도 시작 main으로 되돌렸다. 최종 child 선언은
`main`이고, 모든 선행이 충족된 직접 후속 `POL-02`·`FALCO-01`·`NET-04`를 `READY`로 연다.

2026-08-03 `NET-04`에서 VLAN 20~50의 임시 bootstrap 경계를 현재 배포 host와 실제 서비스
통신표로 최소화했다. 신규 최종 rule 20개를 disabled로 stage·의미값 대조한 뒤 활성화했고,
기존 경계가 함께 동작함을 확인한 다음 `NET-03` 16개, PostgreSQL·Warpgate·NetBird exact
임시 rule 3개, DATA→AWS VPC 전체 프로토콜 임시 rule 1개와 만료 alias 3개를 제거했다.
기존 S3 exact rule은 보존했다. 저장 의미값과 PF runtime은 최종 rule `20/20`, 만료 rule
`0/20`으로 일치했다. 실제 source별 `vlan-verify hardened`는 k3s `13/13`, Warpgate
`21/21`, NetBird `10/10`, PostgreSQL `9/9`, object `9/9`가 모두 PASS했고 각 plan의 BLOCK은
900초 안의 동일 destination·protocol·port MGMT ALLOW control을 사용했다. 임시 verifier를
제거하고 의도한 rule·alias diff만 승인한 직후 일반 drift 없음도 확인했다. OPNsense는
재부팅하지 않았다. 따라서 `NET-04`를 `DONE`으로 닫고 모든 선행이 끝난 직접 후속
`EDGE-01`만 `READY`로 연다. 조건부 `NIPS-01`은 `DEFERRED`를 유지한다.

2026-08-03 `FALCO-01`에서 Falco `0.44.1`·chart `9.1.0`과 container plugin `0.7.1`을
digest로 고정하고 Rocky Linux 9.8 kernel `5.14.0-687.10.1.el9_8.0.1.x86_64`의 BTF를 쓰는
modern eBPF 기준선을 배포했다. Kubernetes API RBAC·ServiceAccount token 없이 k3s CRI socket
하나와 read-only `/proc`·`/sys/kernel`, capability `BPF`·`PERFMON`·`SYS_RESOURCE`·
`SYS_PTRACE`만 허용했다. `container_t`의 host proc/BPF EACCES가 확인돼 본 Falco container만
`spc_t`를 적용하고 init container는 기존 type을 유지했다.

설정 SHA `5edc2425615fde3a8776b8e165dca6cfe468ad97`와 root pointer
`02b033a22bfccaf7282ad622461e7559748c69ea`에서 root·Falco child가 `Synced/Healthy`, Falco가
`1/1 Ready`였다. 전용 namespace의 비특권 Pod가 `emptyDir`에 실제 marker 파일을 쓴
`FALCO-01 Test Runtime File Write` event를 단일 JSON stdout 경로에서 확인하고 즉시 제거했다.
이어진 60초 고정 창은 총 `0건`·`0건/시간`·상위 noisy rule 없음으로 `0–1건` 기준을 통과했다.
적용 전/후 available RAM은 `11,169/10,994MiB`, swap 0, Falco working set `134MiB`로 12GiB
경고 구간이지만 8GiB 정지선 위의 **GO**였다. 탐지 확인→workload·사용자·시각 식별→read-only
조사→사람 승인형 격리/복구 판단→rollback 대응 초안을 남겼고 자동 대응은 없다. 시작 main
`bd96f29097fbf5c6e0ae9f93a75f80d395932947`로 rollback해 Falco·테스트 자원이 없고 root가
`Synced/Healthy`임을 확인했으며 최종 child 선언은 `main`이다. 직접 후속 `AUDIT-01`은
`EDGE-01`·`POL-02`, `WAZUH-01`은 `AUDIT-01`·`OBS-01`, `SOAR-01`은 `OBS-01`·`WAZUH-01`이
남아 모두 `BLOCKED`를 유지하므로 새로 `READY`로 여는 작업은 없다.

2026-08-03 `POL-02`에서 POL-01의 Pod-level `runAsNonRoot` ClusterPolicy 한 건만
`Enforce`로 승격하고, 적용 전 PolicyReport의 기존 위반 네 workload를 kind·이름·rule까지
고정한 PolicyException으로 한정했다. 임시 예외는 `2026-08-02T15:27:28Z` 만료 전 정확한
이름만 허용하고 범위 밖 이름과 만료 뒤 같은 입력을 admission에서 거부했다. E2E-01 build 9의
기존 signed digest `sha256:63adb1c8496736c1e9af53e7a4154a8044b184f5b0de41104b9cb483957a0996`는
설정 SHA `106444b8ce399a4e119f6865f20f739718719eee`와 root pointer
`aa688fd80e39d1549ea3c80a4455b813292753c3`에서 `Running/Ready`였다. Cosign v3 bundle은
E2E namespace만 고르는 `ImageValidatingPolicy`의 current/previous static key로 검증하며,
기존 namespaced policy는 Argo가 prune했다. 시작 main
`ae2a802ebcc3dd4e2476f962b0f3b467a6cd304d`로 rollback했을 때 ClusterPolicy `Audit`, 관련
PolicyException 0건, root와 세 child `Synced/Healthy`를 확인하고 최종 child 선언과 라이브
root를 `main`으로 복귀했다. 직접 후속 `AUDIT-01`은 `EDGE-01`이 남아 `BLOCKED`를 유지하므로
새로 `READY`로 여는 작업은 없다.

2026-08-03 `POL-01-FIX-01`에서 `pomerium` namespace default-deny에 Dashy의 Keycloak egress
예외가 없어 Portal이 로그인 상태를 유지하지 못하던 결함을 보정했다. Pomerium은 예외를
받았지만 Dashy는 DNS 외 모든 egress가 막혀 서버측 토큰 검증이 `fetch failed`로 실패했고,
브라우저에는 `Your session has expired`로만 보였다. 이 경로의 목적지는 좁힐 수 없다.
svclb `podSelector`와 노드 IP `ipBlock`을 각각 적용해 실측한 결과 둘 다 차단됐고, 목적 port만
제한한 규칙도 단독으로는 동작하지 않아 Traefik TCP 8443 규칙과 함께 둔 뒤에야 통과했다.
같은 경로를 쓰는 Pomerium이 처음부터 동작한 것도 두 규칙을 함께 갖고 있었기 때문이므로,
Pomerium의 443 규칙을 좁히려던 시도는 철회하고 두 workload의 구성을 같게 유지했다. 검증
SHA에서 Dashy Keycloak 도달 양성, `token verification failed` 신규 0건, Vault 8200·Gitea 3000
음성 유지, headless 브라우저의 보호 route 200과 그룹 타일 표시, Pomerium error 로그 0건을
확인했다. 시작 main `30600f43632c`로 rollback해 root와 `policy-baseline`의 `Synced/Healthy`와
최종 child 선언 `main`을 확인했다. 새로 `READY`로 여는 작업은 없다.

## 7. 최소권한과 공개 경로

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `NET-04 DONE` | 실제 통신표로 VLAN 규칙 최소화·hardened 검증 ([runbook](runbook/opnsense-vlan-firewall-hardening.md)) | `NB-02`, `WG-02`, `POM-01`, `BKP-05`, `E2E-01` | `OPNSENSE-LIVE` | 외부 공개·운영 통신 | 임시 rule 제거, `vlan-verify hardened`, drift 없음 |
| `EDGE-01 DONE` | NetBird 단독 공개 DNS·NAT allowlist, 이전 프로젝트 공개 DNS 잔여 정리, Warpgate direct recovery peer와 최소 NetBird policy ([runbook](runbook/netbird-public-edge.md)) | `CROWDSEC-FIX-01`, `POM-01`, `NB-02`, `NIDS-01`, `NET-04` | `PUBLIC-DNS`, `OPNSENSE-LIVE` | 외부 사용자 | 공개 권위 DNS는 DNS-only `netbird` A 1건·그 밖의 record 0건, WAN NAT는 NetBird TCP 80/443·UDP 3478만 존재, IDS 관측과 Warpgate TCP 8888 direct-peer 복구 경로가 Cloudflare proxy와 독립 |
| `EDGE-DESIGN-02 DONE` | 외부 NetBird OIDC bootstrap 순환을 해소할 Keycloak 사용자 프런트엔드 공개 경계 결정 ([ADR](adr/0018-public-keycloak-frontchannel.md)) | `EDGE-01`, `KC-01`, `NB-02`, `IAM-01` | 없음 | `EDGE-02`, `NB-ENROLL-01`, `IAM-ENROLL-01` | `sso` 사용자 프런트엔드만 공개하고 관리면·Portal·리소스·self-registration은 비공개로 둔 ADR, Cloudflare origin port 분리·OPNsense source 제한·rollback·후속 device/data-plane 소유권을 아키텍처·주소·런북·백로그에 일치시킴, 라이브 변경 0 |
| `EDGE-02 DONE` | Keycloak `platform` realm 사용자 OIDC 프런트엔드의 Cloudflare proxy/WAF·origin port 분리·OPNsense source 제한 적용 ([runbook](runbook/keycloak-public-frontchannel.md)) | `EDGE-01`, `EDGE-DESIGN-02` | `PUBLIC-DNS`, `OPNSENSE-LIVE` | 외부 NetBird 로그인·`NB-ENROLL-01` | 공개 DNS·origin allowlist, 랩 밖 기존 `/platform-users` ID의 PKCE/device authorization·MFA, Admin·master·management와 origin 직접 우회 차단, NetBird/Warpgate 복구·내부 issuer 불변, `sso` 객체만 제거한 EDGE-01 rollback |
| `NIPS-01 DEFERRED` | 검증된 Suricata rule만 선택적 IPS로 승격 | `NIDS-01`, `NET-04` | `OPNSENSE-LIVE` | 전체 프로젝트 통신 | 정상 트래픽·오탐·부모 인터페이스·offloading·처리량·장애·즉시 rollback 검증; 공개의 필수 gate 아님 |
| `KMS-01 DONE` | Vault Shamir→AWS KMS auto-unseal migration ([증거](evidence/kms-01/README.md)) | `BKP-05` | `VAULT-INIT` | Vault 부팅·복구 | 사전 snapshot, KMS 장애 시험, seal rollback drill, [ADR-0006](adr/0006-vault-seal-and-bootstrap-boundary.md) 재검토 조건 2의 AWS IAM·KMS 최소권한과 비용·감사 기준 검증, migration 뒤 재부팅에서 사람 개입 없는 unseal과 Shamir 복귀 경로 보존; VPN은 선행 아님 |

2026-08-04 외부 신규 장치가 기존 팀 Keycloak ID로 NetBird에 로그인해야 한다는 실제 요구가
생겨 `EDGE-02`의 재검토 조건을 충족했다. [ADR-0018](adr/0018-public-keycloak-frontchannel.md)은
`sso`의 `platform` realm 사용자 프런트엔드만 공개하고 `access` Portal·애플리케이션·Keycloak
관리면과 self-registration은 비공개로 유지한다. 현재 NetBird가 소유한 WAN TCP 443은 바꾸지
않고 Cloudflare hostname Origin Rule의 destination port override와 OPNsense의
Cloudflare-source-only origin port를 사용한다. exact port와 DNS 노출 상태는
[`ip-plan.md`](ip-plan.md)가 단일 원본이다.

`EDGE-DESIGN-02`는 위 선택, 검토한 대안, 적용 전 stop condition, 완료 증거와 rollback을
문서에만 반영했으며 Cloudflare, 공개 DNS, OPNsense, Traefik, Keycloak과 NetBird live 변경은
0건이다. 선행이 모두 `DONE`이므로 `EDGE-02`만 `READY`로 연다. `NB-ENROLL-01`은
`EDGE-02`가 외부 인증면을 증명할 때까지, `IAM-ENROLL-01`은 `NB-ENROLL-01`이 device group·
split DNS·exact route·offboarding을 증명할 때까지 `BLOCKED`다. clientless Portal 공개는
이번 결정을 확장하지 않고 별도 재검토한다.

2026-08-04 `EDGE-02`에서 ADR-0018의 목표 경계를 라이브로 적용했다. preflight에서 발견한
`WAZUH-02`·`SOAR-DASH-01`의 OPNsense drift 스냅샷 누락은 live 변경 없이 스냅샷만 별도
커밋으로 보정했고, Cloudflare zone에 남아 있던 폐기 `ktcloud4-acer` 프로젝트의
`acer-waf-custom`·`acer-waf-ratelimit` ruleset은 사용자 확인 뒤 삭제해 Free plan의 WAF
Custom Rule·Rate Limit 슬롯을 확보했다. Cloudflare `sso` proxied record·hostname Origin
Rule(destination port 8443)·WAF·Rate Limit과 OPNsense alias 3개·NAT(REST API가 없어 GUI로
disabled 생성 후 readback 대조)를 stage했고, `keycloak` AppProject에 `traefik.io/Middleware`
whitelist가 없어 막힌 것을 crowdsec AppProject와 같은 패턴으로 고친 뒤 immutable SHA에서
`platform-root`·`keycloak` child Application을 라이브 검증했다.

완료 증거 5개를 모두 실행했다. 공개 DNS·origin allowlist는 `netbird` DNS-only·`sso`
proxied 2건과 OPNsense WAN NAT(NB-01 세 건 + EDGE-02 8443 source 제한 한 건)로 일치했다.
외부 사용자 프런트엔드는 Cloudflare edge IP로 강제한 실제 PKCE 요청이 로그인 폼까지
도달했고 기존 `/platform-users` ID로 비밀번호 변경·TOTP MFA 등록·콜백까지 완료했다.
관리면·우회는 `/admin/`·`/realms/master`·root·WAN 직접 접속이 같은 외부 시점에 모두
거부됐고 허용 discovery는 성공했다. NetBird API 401과 Warpgate TCP 8888 recovery는
불변이었고 `access`·애플리케이션 공개 record는 0건이었다. rollback은 Cloudflare 4개
객체와 GitOps 변경을 제거해 EDGE-01 기준선(단일 Ingress, Middleware 0개)으로 복귀함을
확인한 뒤 같은 값으로 재적용해 최종 상태를 검증했다.

부수적으로 `netbird.imcherry5778.xyz` 대시보드의 사전 존재 결함 두 건(`NB-02-FIX-01`:
절대 URL로 선언된 `AUTH_REDIRECT_URI`/`AUTH_SILENT_REDIRECT_URI`의 origin 중복 결합,
그리고 `netbird-client`에 없는 `groups` scope 요청)을 발견해 git 템플릿과 `netbird-01`
라이브 컨테이너에 함께 반영했다. 외부 접속 시 대시보드 최초 로드에서 나타나는
"Unauthenticated" 화면(내부 경로에서는 재현 안 됨)은 원인 미특정으로 남겨 `NB-ENROLL-01`
또는 후속 FIX가 조사한다. `platform-root`는 검증 뒤 `main`으로 복귀했고 `ARGO-ROOT` 잠금을
해제했다. 선행이 모두 충족된 `NB-ENROLL-01`만 `READY`로 열고 `IAM-ENROLL-01`은 `BLOCKED`를
유지한다.

2026-08-04 `NB-ENROLL-01`에서 `/platform-users` device group의 split DNS·exact ingress
route·offboarding을 라이브로 증명했다. Warpgate가 `EDGE-01`에서 쓴 "subnet route 대신
exact host peer" 원칙을 따르되, 목적지 호스트에는 아무것도 설치하지 않는 방식을 새로
채택했다. OPNsense 26.7에 공식 `os-netbird` 플러그인을 설치해 NetBird Network Router로
등록하고(신규 인터페이스 `opt6`/`wt0`), `k3s-01`(TCP 443)과 netbird-01의 신규 `dnsmasq`
split DNS relay(TCP/UDP 53) 두 exact host Resource만 열었다. k3s-01 자체는 변경하지
않았다.

검증 중 OPNsense가 routing peer이면서 동시에 목적지(자신의 Unbound)인 self-referencing
경로는 PF state는 생성되지만 패킷이 로컬 소켓까지 전달되지 않는 FreeBSD/userspace
WireGuard 한계를 재현했다(`pfctl` state `SINGLE:NO_TRAFFIC`, Unbound query 로그 0건,
masquerade on/off 모두 동일). 다른 호스트(k3s-01)로의 라우팅은 항상 정상이었으므로 DNS
목적지를 OPNsense 자신에서 netbird-01로 옮겨 우회했다. 이 결함은 고치지 않고 런북에
한계로 남긴다. 또 NetBird 이 버전의 `POST /api/policies`가 rule을 여러 개 보내도 첫
rule만 저장하는 것을 발견해(`EDGE-01`의 기존 policy들도 모두 rule 1개였던 것과 같은
제약) policy 1개당 rule 1개로 우회했다.

실제 검증은 호스트의 NetBird·Tailscale 인터페이스를 배제한 격리 Docker container에서
pinned `netbird` v0.73.0(서버와 동일)로 실행했다. `netbird up`/`login`은 headless
Linux에서 기본적으로 OAuth Device Authorization Grant를 쓰는데, 이 랩의 `netbird-client`가
PKCE를 필수로 요구해 device flow가 `400 Missing parameter: code_challenge_method`로
거부되는 사전 존재 결함도 발견했다. 실제 데스크톱 사용자는 PKCE flow를 쓰므로 영향받지
않으며(`XDG_CURRENT_DESKTOP` 설정으로 같은 경로 재현), 이번 완료 증거도 그 경로로
검증했다. 완전 headless 사람 장치 지원이 실제로 필요해지기 전까지는 고치지 않는다.

완료 증거 8개를 모두 실행했다. 격리 container가 `/platform-users` 일상 ID
`imcherry5778`의 실제 비밀번호·TOTP로 Cloudflare edge를 거쳐 PKCE 로그인해 진짜 peer를
등록했고, 등록 즉시 JWT groups propagation으로 `/platform-users`에 배정됐다. 그 peer에서
`access.imcherry5778.xyz`가 split DNS로 `10.10.20.10`을 반환했고 `HTTPS 302`(Pomerium의
정상 미인증 리다이렉트)로 도달했다. 그룹 없는 `headlamp-no-group`과 `/platform-privileged`만
가진 `imcherry-admin`은 Keycloak 로그인은 성공해도 NetBird API가 `401`로 거부했다. 같은
peer에서 허용 밖 목적지(`postgres-01`, `object-01`)는 라우팅 자체가 없어 즉시 실패했고,
같은 k3s-01의 허용 밖 port(`22`, `6443`)는 timeout했다. 사람용 setup key는 0건이며,
OPNsense routing peer 등록에 쓴 유일한 setup key는 headless one-off로 이미 소모됐다.
Keycloak session revoke(`204`) 뒤 NetBird 사용자를 차단하고 peer를 삭제하자, 저장된
peer 상태로 재연결은 `peer login has expired`로 거부됐고 차단 상태의 신규 등록 시도는
peer record가 생겨도 `connected: false`였다. `imcherry5778`은 실 운영자의 상시 계정이라
검증 뒤 차단 해제·소속 group·기존 peer(`fedora`) 연결까지 복원했고, 검증용 peer·container·
Unbound 디버그 설정은 모두 제거했다. OPNsense config.xml 정규화 스크립트가 NetBird
`setupKey` 필드를 마스킹하지 않던 것도 함께 고쳤다. `EDGE-01`의 recovery group·policy와
`EDGE-02`의 공개 인증면은 변경하지 않았다. `Unauthenticated` 화면 결함은 이번 검증
경로에서 재현되지 않아 원인 미특정으로 남긴다. 상세는
[NetBird 등록 runbook](runbook/netbird-enrollment.md)이 소유한다. 선행이 모두 충족된
`IAM-ENROLL-01`만 `READY`로 연다.

2026-08-05 `IAM-ENROLL-01`의 대상 계정 6개 중 3개(`imcherry5778`, `imcherry5778-admin`,
`snsd-hybirdinfra`)가 실제로 초기 비밀번호 변경과 TOTP 등록을 마쳤다(Keycloak
`requiredActions` 0건, `password`·`otp` credential 실존 확인). `foxgeun`, `cerberos2022`,
`Jaeeyun`은 아직 자기 계정으로 로그인한 적이 없어 `requiredActions`에 `CONFIGURE_TOTP`,
`UPDATE_PASSWORD`가 남아 있다. 6개 계정 모두의 Shuffle 최초 OIDC 로그인은 아직 하나도
확인하지 않았다. 완료 증거가 `6/6`을 명시하므로 이 부분 완료 상태로는 `DONE`으로
전환하지 않고 `READY`를 유지한다 — 특히 `IAM-MIG-01`은 legacy `imcherry`·`imcherry-admin`
비활성화를 다루므로, 새 ID 전체가 실사용 가능함을 확인하기 전에는 열지 않는다. 나머지
세 계정은 각 팀원이 직접 로그인·MFA·Shuffle 등록을 완료해야 하며, `6/6`이 채워지는
시점에 이어서 판정한다.

2026-08-03 `KMS-01`의 `DEFERRED`를 해제하고 `READY`로 연다.
[ADR-0006](adr/0006-vault-seal-and-bootstrap-boundary.md)의 재검토 조건 중 "Vault와 S3 복구
drill을 완료한다"는 `BKP-03`의 Raft snapshot restore와 `BKP-05`의 통합 재해복구 drill로
충족됐다. "수동 unseal이 허용 가능한 운영시간을 반복해서 초과한다"는 아직 한 번이지만,
`CAP-03`의 cold start에서 threshold 3/3 수동 unseal이 실제로 필요했고 `CERTMGR-01`·`PKI-01`이
Vault 가용성에 의존하기 시작하므로 재부팅 비용은 계속 늘어난다. 남은 조건인 "AWS IAM·KMS
최소권한과 비용·감사 기준 검증"은 별도 gate로 두지 않고 `KMS-01`의 완료 증거에 넣었다.

`KMS-01`은 `VAULT-INIT`을 단독으로 잡고 Vault를 내렸다 올린다. Vault Agent init을 쓰는 앱의
Pod 재생성이나 `CERTMGR-01`의 Issuer 검증과 같은 창에서 실행하면 실패 원인을 분리할 수 없으므로
겹치지 않게 잡는다. auto-unseal로 바꾼 뒤에도 Shamir 복귀 경로는 보존한다.

2026-08-03 `KMS-01`에서 migration 전 Raft snapshot을 확보하고 별도 AWS state의 대칭
single-Region KMS key와 exact-key `Encrypt`·`Decrypt`·`DescribeKey` IAM policy를 적용했다.
IAM policy 한 개만 회수한 장애 시험은 service credential 거부 전파 뒤 Vault가 KMS
`AccessDenied`로 NotReady가 되고, 같은 Pod가 policy 복구 뒤 share 없이 auto-unseal됨을
확인했다. `auto-unseal → Shamir → auto-unseal` rollback drill, migration 뒤 무인 재기동,
새 recovery share 5/3 verification을 마쳤다. 월 USD 1 고정비와 request 단가를 계산했고
CloudTrail에서 성공·거부 event를 확인했다. 공인 KMS endpoint를 써 VPN은 선행으로 추가하지
않았다. 따라서 `KMS-01`을 `DONE`으로 닫는다. `KMS-01`을 직접 선행으로 둔 후속은 없어 새로
`READY`로 여는 작업은 없다.

2026-08-03 `EDGE-01`에서 공개 권위 DNS를 DNS-only `netbird` A 한 건으로 정리하고 현재
OPNsense WAN IPv4로 교정했다. 두 authoritative NS에서 그 밖의 A·AAAA·CNAME 0건과 일본
외부 HTTPS HTTP 200을 확인했다. OPNsense 저장 설정과 PF runtime의 inbound NAT는 기존
NetBird TCP 80·443, UDP 3478 세 건뿐이었다. 같은 외부 TCP 443 흐름은 DMZ Suricata
`eve.json`에 관측됐다. Warpgate에는 `v0.73.0` direct peer를 선언하고 Default All↔All을
비활성화한 뒤 recovery client group에서 Warpgate TCP 8888로 향하는 단방향 policy만
적용했다. 격리 ephemeral peer의 내부 Warpgate HTTPS 요청은 `wt-edge01` overlay로 한 번에
통과했고 public Warpgate DNS·NAT와 Cloudflare proxy를 사용하지 않았다. one-off key와
ephemeral peer·container·state·image는 제거했고 persistent peer만 connected 상태로
남겼다. OPNsense drift는 EDGE-01 exact rule 한 건으로 스냅샷을 갱신한 뒤 0이었다. 따라서
`EDGE-01`을 완료하고 선행이 모두 충족된 직접 후속 `AUDIT-01`만 `READY`로 연다.
조건부 `EDGE-02`와 `NIPS-01`은 `DEFERRED`를 유지한다.

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
| `AUDIT-01 DONE` | Suricata·CrowdSec AppSec(Coraza/CRS)·Falco·Kubernetes·Vault·Keycloak·Pomerium·접근 서비스 이벤트 분류 | `EDGE-01`, `POL-02`, `FALCO-01` | 없음 | Loki·Wazuh | 보안/운영 경계, 시각·사용자·요청 ID, 마스킹, 보존 기준 |
| `LOKI-01 DONE` | Alloy·Loki와 제한된 운영 로그 수집 | `AUDIT-01` | `K3S-HEAVY` | Grafana | 보안 이벤트의 Wazuh 중복 저장 없음, label cardinality·retention·disk 상한 |
| `OBS-01 DONE` | kube-prometheus-stack·Alertmanager·Grafana | `LOKI-01` | `K3S-HEAVY` | 운영 경보·Wazuh·Shuffle | node/PVC/backup/cert·수집 파이프라인 지표, 실제 경보 전달, disk 상한 |
| `OPN-METRICS-01 DONE` | OPNsense exporter와 최소 metric 방화벽 경로 | `OBS-01` | `OPNSENSE-LIVE` | 운영 경보 | exporter target `up=1`, CPU·memory·interface 대표 시계열, 최소 rule 한 건과 rollback·drift 없음 |
| `WAZUH-01 DONE` | Wazuh 배치·보안 소스 직접 수집·규칙 PoC | `AUDIT-01`, `OBS-01`, `FALCO-01`, `NIDS-01`, `CAP-03` | `K3S-HEAVY` | Shuffle, `CERTMGR-01` | Suricata 등 대표 이벤트의 직접 탐지·검색·retention, Loki relay 없음, active response 비활성, 오탐·용량 gate |
| `WAZUH-01-FIX-01 DONE` | WAZUH-01의 OPNsense live 상태와 masked drift snapshot을 일치시키고, 성공 경로에서 snapshot 갱신이 다시 누락되지 않도록 절차를 보정 (`gitops/tools/wazuh-01/apply-opnsense.sh`, `infra/opnsense/config.xml`) | `WAZUH-01` | `OPNSENSE-LIVE` | `OBS-02` | 라이브 Wazuh Agent 설정이 WAZUH-01 선언과 exact match, IDS 차이가 `persisted_at` metadata뿐이며 의미 설정 차이 0건이거나 다르면 변경 없이 중단, 갱신 전 sanitized drift가 승인된 WAZUH Agent subtree와 판정된 metadata 차이뿐, `check-drift.sh --update` 뒤 일반 drift 없음, snapshot의 credential 원문 0건과 Wazuh password masking 유지, 향후 성공 절차가 exact drift 분류 → snapshot update → 일반 drift 확인 없이는 완료되지 않음, 작업 전후 OPNsense live revision·Wazuh service·PF·NAT·DNS·IDS 의미 설정 불변, 최신 main에서 `platform-root`·`wazuh`가 `Synced/Healthy` |
| `OBS-02 DONE` | Grafana·Prometheus·Alertmanager UI를 Pomerium Route로 노출하고 최소 대시보드 확보 (`gitops/apps/obs/`) | `OBS-01`, `POM-01` | `OPNSENSE-LIVE` | 운영 경보 silence·팀 온보딩 | Route 3건과 `pomerium`→`obs` NetworkPolicy egress 선언, Grafana 로그인 뒤 node·PVC·Loki 대표 패널 표시, Prometheus target `up=1`과 PromQL 실행, Alertmanager silence 생성·조회·만료 왕복, `/platform-users` 허용과 미소속 계정 403의 같은 시점 대조 및 Alertmanager 쓰기 경로의 `/platform-privileged` 한정, alias 3건 내부 A만·내부 AAAA·공개 A/AAAA 0건, 표준 Ingress만 사용해 HelmChartConfig generation·Traefik Pod UID·restart 불변, 배포 전후 available RAM 정지선 통과와 신규 PVC 0개, Argo child `Synced/Healthy`와 OPNsense drift 없음, rollback 뒤 기존 Route·경보 전달 회귀 없음 |
| `OBS-03 DONE` | Grafana에 Keycloak `generic_oauth` 로그인을 추가하고 전용 group `/grafana-editors`(`imcherry5778`, `cerberos2022`)만 Editor로 매핑, 나머지 `/platform-users`는 Viewer 고정 (`gitops/apps/obs/`, `gitops/tools/obs-03/`) | `OBS-02` | `IDENTITY-LIVE` | Grafana 대시보드 편집 권한 운영 | 새 Keycloak confidential client `grafana`와 group `/grafana-editors`가 기존 realm 객체 무변경으로 check-first 선언과 일치, 실제 OIDC 로그인으로 `imcherry5778`의 Grafana `orgRole=Editor`와 `foxgeun`·`Jaeeyun`·`snsd-hybirdinfra` 중 1명의 `orgRole=Viewer` 확인, 아직 Keycloak 가입을 완료하지 않은 `cerberos2022`는 `/grafana-editors` membership과 공통 role mapping 선언까지 확인하고 실제 로그인은 온보딩 시점으로 이관, `imcherry5778-admin`(`/platform-privileged`)에는 Grafana 권한을 매핑하지 않음, 로컬 `admin` 복구 로그인과 기존 데이터소스·대시보드 provisioning(`editable: false`) 회귀 없음, Vault `kv/obs/grafana`에 `oidc_client_secret` 키만 추가하고 기존 `obs-grafana` policy·role 무변경, Argo child `obs` `Synced/Healthy` |
| `OBS-04 DONE` | Platform Capacity Sentinel 대시보드 구축 (`gitops/apps/obs/`) | `OBS-03` | 없음 | 관측·운영 경보 | `obs-04-capacity-sentinel` ConfigMap 선언 및 Grafana 마운트, RAM(8/12GiB)·PVC(96/120GiB)·thin-pool(60/70%) 정지 기준 Threshold 시각화, Argo child `obs` `Synced/Healthy` |
| `OBS-05 DONE` | Core Services & Traffic Infrastructure 대시보드 구축 (`gitops/apps/obs/`) | `OBS-04` | 없음 | 관측·운영 | `obs-05-core-services` ConfigMap 선언 및 Grafana 마운트, Traefik(QPS/Status/Latency)·Pomerium(SSO/Route)·PostgreSQL(쿼리/커넥션/WAL)·Vault(Unseal/Cert-TTL) 패널 표시, ConfigMap 선언 및 kustomization 추가, Argo 검증 완료 |
| `OBS-06 DONE` | Data Protection & Backup Pipelines 대시보드 구축 (`gitops/apps/obs/`) | `OBS-05` | 없음 | 관측·백업 | `obs-06-backup-pipelines` ConfigMap 선언 및 Grafana 마운트, Velero 백업 성공률·SeaweedFS S3 용량/일일 증가율·AWS S3 오프사이트 헬스 시각화, Argo child `obs` `Synced/Healthy` |
| `OBS-06-FIX-01 DONE` | Data Protection & Backup Pipelines 대시보드의 S3 용량 오매핑 및 더미 fallback 쿼리 결함을 실제 Velero 메트릭으로 보정 (`gitops/apps/obs/`) | `OBS-06` | 없음 | 관측·백업 | `obs-06-backup-pipelines` ConfigMap 쿼리 교정(노드 파일시스템 오참조 및 더미 0 Bps/1 제거 ➔ `velero_backup_tarball_size_bytes` 및 BSL `Available` 실측 매핑), YAML/JSON 유효성 확인, Argo child `obs` `Synced/Healthy` |
| `OBS-07 DONE` | Loki Operational Log Explorer 대시보드 구축 (`gitops/apps/obs/`) | `OBS-06` | 없음 | 관측·로그 | `obs-07-loki-log-explorer` ConfigMap 선언 및 Grafana 마운트, Namespace/App별 5분 단위 `level=error|warn` 로그 발생률 차트 및 dynamic filter Log Stream 패널 표시, Argo child `obs` `Synced/Healthy` |
| `OBS-08 DONE` | Platform Observability Overview 대시보드 최종 7개 패널 재구성 (`gitops/apps/obs/`) | `OBS-02` | 없음 | 관측·운영 경보 | `OBS-02` 대시보드 패널 7종으로 재구성 (Node Ready, 컴포넌트 상태, 경보, Argo Sync 등), Argo child `obs` `Synced/Healthy` |
| `OBS-09 DONE` | Kubernetes 비민감 리소스 인벤토리 수집 확대와 drill-down 대시보드 (`gitops/apps/obs/`) | `OBS-08` | 없음 | 관측·운영 | kube-state-metrics의 기존 node·pod·PV·PVC collector를 유지하면서 namespace·Deployment·DaemonSet·StatefulSet·ReplicaSet·Job/CronJob·Service/Endpoint·Ingress·HPA·NetworkPolicy·ResourceQuota만 추가하고 Secret·ConfigMap collector와 `kube_secret_*`·`kube_configmap_*` 대시보드 패널은 제외한다. Grafana.com Kubernetes / Views / Global ID 15757의 고정 revision을 Prometheus datasource UID `prometheus`, Grafana 13 panel schema, read-only provider에 맞춰 vendoring한다. 추가한 각 자원군의 대표 Prometheus 시계열, kube-state-metrics target `up=1`, dashboard drill-down 표시를 확인하고, 적용 전후 `prometheus_tsdb_head_series`·Prometheus/kube-state-metrics working set·k3s available RAM/swap·Prometheus retention 3d/6GiB를 같은 측정으로 판정해 정지 기준 밖을 유지한다. 신규 Service·NetworkPolicy·PVC·Secret·외부 노출은 0건이어야 하며, rollback은 collector 목록과 dashboard ConfigMap만 동일 작업에서 원복한다. 최신 main의 `platform-root`·`obs`가 `Synced/Healthy` |
| `OBS-09-FIX-01 DONE` | Kubernetes Global dashboard의 KSM allocatable query quote escaping 보정 (`gitops/apps/obs/`) | `OBS-09` | `ARGO-ROOT` | Kubernetes 자원 현황 조회 | `normalize-dashboard.jq`의 `machine_cpu_cores`·`machine_memory_bytes` 치환이 PromQL label value에 literal backslash를 넣지 않도록 보정하고 ConfigMap을 재생성한다. Grafana API에서 affected query의 `\\` 0건과 Prometheus API parse 성공, read-only dashboard 표시를 확인한다. collector·RBAC·ServiceMonitor·NetworkPolicy·PVC·Secret·Ingress·외부 노출은 변경하지 않으며 rollback은 normalizer와 기존 dashboard ConfigMap만 원복하고 최신 main의 `platform-root`·`obs` `Synced/Healthy` |
| `OBS-10 DONE` | Traefik 공식 Traffic Drill-down 대시보드 GitOps vendoring (`gitops/apps/obs/`) | `OBS-09`, `TRAEFIK-METRICS` | 없음 | ingress 장애 분류·운영 | Grafana.com Traefik Official Standalone Dashboard ID 17346 revision 9과 upstream SHA-256 `3ad329d2737120f32f67aab083f245b554ea5c4ec8378feee7196ef6bb9f7da9`를 고정해 Prometheus UID `prometheus`, Grafana 13 schema 41, read-only provider로 정규화했다. 실측 target `up=1`과 entrypoint/histogram/router/service label inventory를 기반으로 QPS, HTTP 상태/5xx, p95/p99, Top entrypoint/router/service만 남겼고 path·client IP·사용자·인증 header와 `or vector(0)` fallback은 제외했다. 기존 Grafana file provider가 읽는 `obs-05-core-services` ConfigMap에 `traefik-traffic.json`을 추가해 Pod 재기동 없이 provisioning하고, OBS-05 Traefik 3개 summary panel은 새 UID의 Markdown link 한 건으로 치환했다. immutable root/config SHA에서 Grafana API model·Prometheus query·scope/Pod UID 불변을 판정한 뒤 literal main으로 복구한 근거는 [`docs/evidence/obs-10/README.md`](evidence/obs-10/README.md)에 기록했다. rollback은 dashboard ConfigMap과 OBS-05 link만 원복하고 최신 main의 `platform-root`·`obs` `Synced/Healthy`를 확인한다. |
| `TRAEFIK-METRICS DONE` | packaged Traefik의 private Prometheus scrape 경로 준비 (`gitops/apps/ingress/`, `gitops/apps/obs/`) | `OBS-09` | `TRAEFIK-LIVE` | `OBS-10`·ingress 관측 | 2026-08-11 read-only inventory에서 Traefik은 `metrics` entrypoint와 Prometheus metric을 이미 켰지만, `traefik` Service에는 80/443만 있고 Traefik ServiceMonitor·Prometheus target·`traefik_*` metric은 모두 0건이었다. check-first로 기존 metric entrypoint·Pod args를 보존하고, 필요할 때만 static config/HelmChartConfig를 바꿔 유일한 Traefik Pod 재기동 영향과 rollback을 판정한다. TCP 9100은 기존 외부 serving Service에 추가하지 않고 Traefik Pod selector의 private ClusterIP metrics Service, `obs` namespace의 `release=obs` ServiceMonitor, Prometheus→Traefik Pod TCP 9100 exact NetworkPolicy만으로 수집한다. 실제 native metric과 entrypoint·code·router·service label set을 값 없이 inventory해 `OBS-10`이 사용할 범위를 확정하고, target `up=1`, QPS·HTTP 상태군/5xx·p95/p99·top entrypoint/router/service 대표 series, 전후 Prometheus head series·working set·k3s available RAM/swap을 판정한다. 기존 web/websecure Service, 공개 DNS/NAT/외부 9100, access-log header 정책, Secret/PVC/Ingress와 확인된 것 외 label 수집은 변경하지 않으며, rollback은 metric entrypoint 변경(있을 때), private Service·ServiceMonitor·NetworkPolicy를 함께 원복한다. 최신 main의 `platform-root`·`ingress`·`obs` `Synced/Healthy`; 완료 증거는 [`docs/evidence/traefik-metrics/README.md`](evidence/traefik-metrics/README.md)에 기록했다. |
| `OBS-11 DONE` | Proxmox·Linux VM node-exporter fleet과 Node Exporter Full 대시보드 (`infra/ansible/`, `gitops/apps/obs/`) | `OBS-01`, `VM-01`, `NET-04` | `OPNSENSE-LIVE` | 물리·VM 자원 장애 분류 | `infra/ansible/roles/node_exporter_baseline`이 `proxmox-01`·`postgres-01`·`object-01`·`warpgate-01`·`netbird-01`에 checksum 고정 node_exporter v1.12.1 systemd unit을 선언(`k3s-01`은 기존 DaemonSet 재사용, 2차 적용 `changed=0`)했고, canary(`netbird-01`) 실측으로 systemd collector는 fleet 기본값으로 확대하고 processes collector는 `ProtectProc=invisible` 하드닝 아래 미달로 판정해 의존 panel 3개를 제거했다. OPNsense `opt2`에 `k3s-01`→5개 대상 TCP 9100 exact PASS rule 5건(seq 1003~1007, 기존 `NET-04` 비공개 BLOCK seq=1022 앞)을 disabled stage→enable·apply로 추가했다. Node Exporter Full(ID 1860, revision 45, SHA-256 `184c6b7409f306da75525d7772f71945b10cea23ad16b5d78c4698ea0ea51986`)을 `job=node-exporter`로 정규화해 read-only vendoring했다. immutable root `248b2bf6112204db26904a43aaab1611b039a42b`·child `d1103bc9631cd244b38de1056257fd9c1abcf650`에서 target `up=1` 6건, CPU·memory·disk·network 대표 시계열 6/6, filesystem 5/6(`k3s-01` DaemonSet의 non-root securityContext로 `/proc/1/mountinfo` 권한 없음은 이 작업 범위 밖 기존 한계), systemd 5/5, Grafana dashboard read-only·host 전환 실측 확인, `prometheus_tsdb_head_series` 43,461·retention 3d/6GiB 불변, k3s-01 available 14.0 GiB/swap 0, proxmox-01 available 20.0 GiB/swap 0, 신규 PVC·Secret·공개 DNS/NAT 0건을 판정했다. 검증 뒤 root·child는 literal `main`(`6cdb8c2445a0575edec07e978f0a48a348b7c412`)의 `Synced/Healthy`로 복귀했다. 완료 증거는 [`docs/evidence/obs-11/README.md`](evidence/obs-11/README.md)에 기록했다. |
| `OBS-12 DONE` | ArgoCD / Application / Overview 대시보드와 최소 Application metric 수집 (`gitops/apps/obs/`) | `OBS-01`, `OBS-08`, `GITOPS-02` | `ARGO-ROOT` | GitOps 상태 drill-down·운영 | Grafana.com ArgoCD / Application / Overview ID 19974 revision 6과 upstream download SHA-256 `7a230d1221b1014a40a70d989a80d25d3d800c3a62dd77b63a4a1088c5fbbaf1`를 Grafana 13 read-only provider·Prometheus UID `prometheus`로 vendoring한다. Prometheus가 `obs` namespace ServiceMonitor만 선택하는 현재 경계를 보존하며, `obs`의 ServiceMonitor 한 건으로 기존 `argocd/argocd-metrics:8082`만 30초 scrape하고 default-deny 아래 Prometheus Pod→application-controller Pod TCP 8082 exact egress 한 건만 추가한다. `argocd_app_info`·`argocd_app_sync_total`만 keep하고 template에 불필요한 `repo`·`operation`·`dry_run` label은 ingestion 전에 drop한다. 실제 metric label에 없는 upstream `cluster` selector는 제거하고 `exported_namespace`는 `dest_namespace`로 정규화하며, namespace label이 없는 sync counter panel은 해당 selector를 제외한다. 기존 Platform Overview의 Argo CD OutOfSync 요약은 유지하고 drill-down link만 추가한다. target `up=1`, 두 metric의 대표 series, target별 `scrape_samples_post_metric_relabeling` 1~128, drop label 부재, Grafana API의 read-only dashboard·정규화 query와 immutable `platform-root`·`obs` `Synced/Healthy`를 한 verifier에서 판정한다. 전후 `prometheus_tsdb_head_series`·Prometheus/Grafana working set을 기록하고, k3s available RAM 8 GiB 이상·swap 0·PVC 요청량 불변을 같은 측정으로 판정한다. Argo CD 설정·Service·ingress 정책·RBAC·Secret·PVC·외부 노출은 0건이어야 하며, rollback은 ServiceMonitor·Prometheus egress rule·dashboard ConfigMap·Grafana mount/provider·Overview link만 원복한다. |
| `OBS-12-FIX-01 DONE` | ArgoCD / Application / Overview 대시보드의 변수 datasource 참조 보정 (`gitops/apps/obs/`) | `OBS-12` | `ARGO-ROOT` | GitOps 상태 drill-down·운영 | `datasource` 변수를 제거한 뒤 남은 namespace·job·kubernetes_cluster·project·application_namespace·application 변수 6건의 `datasource.uid: "${datasource}"`를 `prometheus`로 고정한다. `kubernetes_cluster`의 실제 `dest_server` 정규화와 기존 패널 query는 유지한다. 정적 JSON과 Grafana API에서 6개 변수 모두 datasource UID `prometheus`, `${datasource}` 참조 0건, read-only dashboard를 확인하도록 OBS-12 verifier를 보완하고 immutable `platform-root`·`obs` `Synced/Healthy`를 판정한다. Prometheus scrape/metric/label/ServiceMonitor/NetworkPolicy/PVC/Secret/Ingress/외부 노출은 변경하지 않으며, rollback은 dashboard ConfigMap과 Grafana mount checksum만 동일 작업에서 원복한다. |
| `WAZUH-02 DONE` | Wazuh Dashboard 배포와 보안 이벤트 조사 경로 확보 (`gitops/apps/wazuh/`) | `WAZUH-01`, `POM-01`, `CAP-04` | `K3S-HEAVY`, `OPNSENSE-LIVE` | 사고 조사·`SOAR-01` 용량 | 배포 직전 capacity gate 재측정으로 자기 8 GiB 정지선 통과를 판정하고 배포 후 available이 `SOAR-01` 진입선 12 GiB를 남기는지 기록(미달이면 `k3s-01` 32 GiB 증설이 `SOAR-01`의 선행임을 함께 기록), Dashboard를 `WAZUH-01`과 같은 4.14.7 계열 고정 version·image digest로 선언, Pomerium Route와 `pomerium`→`wazuh` NetworkPolicy egress, Dashboard 로그인 뒤 `D30`·`A90` index 검색과 `WAZUH-01`의 Suricata sid `2029054` 재현, indexer 자격증명을 Kubernetes Secret 원문 없이 Vault Agent로만 주입, `/platform-privileged` 허용과 일상 계정 거부, active response 비활성과 ISM 정책 두 건 불변, `wazuh` alias 내부 A 1건·공개 A/AAAA 0건, 배포 후 available·PVC 정지선 통과, Argo child `Synced/Healthy`, rollback 뒤 indexer·manager·retention 회귀 없음 |
| `WAZUH-02-FIX-01 DONE` | Wazuh Dashboard의 내부 local login을 Keycloak native OIDC와 Indexer RBAC로 전환 (`gitops/apps/wazuh/`, `gitops/tools/wazuh-02-fix-01/`) | `WAZUH-02`, `KC-01`, `IAM-MIG-01` | `IDENTITY-LIVE`, `ARGO-ROOT` | 사고 조사 UI의 사용자 SSO | check-first Keycloak confidential `wazuh` client·`wazuh-admin` client role·기존 `/platform-privileged` group mapping exact, 사용자·MFA·기존 group membership 생성/수정/비활성/삭제 0건, Vault `kv/wazuh/dashboard`의 `oidc_client_secret` key만 추가, 기존 Indexer security config의 JWT·LDAP·proxy·client-cert·internal basic domain을 보존하고 native `openid_auth_domain`·audience·`all_access` mapping만 정확 병합, Dashboard native OIDC 세션의 D30/A90 기존 문서 검색, IdP 장애 시 trusted k3s mTLS rollback Job으로 OIDC domain·task client만 제거하는 local-admin 복구, immutable `platform-root`·`wazuh` `Synced/Healthy`, Vault key·Keycloak client 순서와 main 복귀 확인 |
| `WAZUH-02-FIX-02 DONE` | Wazuh Dashboard native OAuth 선택 UI와 Manager API URL 보정 (`gitops/apps/wazuh/`, `gitops/tools/wazuh-02-fix-02/`) | `WAZUH-02-FIX-01` | `ARGO-ROOT` | 사고 조사 UI 로그인 UX·Server APIs 상태 | Dashboard가 native multi-auth `basicauth`·`openid`로 `Keycloak SSO로 로그인` 선택지를 표시하고, normal OIDC 선택 뒤 기존 Keycloak session과 Indexer `wazuh-admin` RBAC로 D30/A90을 조회한다. local basic form은 Pomerium `/platform-privileged` 뒤의 IdP 장애 break-glass만 보존하며 Keycloak client·role·group·Vault·Indexer security 선언은 변경 0건이다. `WAZUH_API_URL`은 port 없는 scheme/host로 고정해 생성 `wazuh.yml`의 단일 `55000`과 결합되고 Server API check가 Online이어야 한다. immutable `platform-root`·`wazuh` `Synced/Healthy`, main 복귀와 Dashboard API config rollback을 한 verifier에서 판정한다. |
| `WAZUH-02-FIX-03 DONE` | Dashboard의 Manager API 사용자 범위 token이 기본 `run_as=true` 때문에 거부되는 결함을 최소권한으로 보정 (`gitops/apps/wazuh/`, `gitops/tools/wazuh-02-fix-03/`) | `WAZUH-02-FIX-02` | `ARGO-ROOT` | Wazuh Server APIs·Overview | 고정 image는 entrypoint가 `wazuh.yml` API host를 처음 만들고, 이후 `wazuh_app_config.sh`가 existing host를 보존해 `RUN_AS`를 반영하지 않는 것을 확인했다. 같은 generator를 먼저 실행한 뒤 단일 `run_as` 필드만 `false`로 강제해 `wazuh-01-api`의 `allow_run_as=false`와 일치시킨다. API 사용자·password·Vault·Keycloak·Pomerium·Indexer RBAC 변경은 0건이다. immutable SHA에서 생성 `wazuh.yml`의 scheme/host·단일 55000·`run_as:false`, OIDC session의 실제 `/api/login` scoped token 발급 HTTP 200, `platform-root`·`wazuh` `Synced/Healthy`, literal main 복귀를 단일 verifier로 판정한다. |
| `OBS-13 DONE` | Prometheus 상시 alert rule과 실제 알림 채널 (`gitops/apps/obs/`) | `OBS-01`, `OBS-06`, `OBS-11` | `ARGO-ROOT` | 운영 장애 조기 탐지 | host down(`up{job="node-exporter"}==0` 5분 지속)·root/PVC 사용률 85%(경고)·95%(심각) 2단계·TLS 인증서 만료 14일 미만(`probe_ssl_earliest_cert_expiry` 기반)·Velero backup 실패(완전·부분) 4종(5개 alertname) PrometheusRule을 선언한다. Alertmanager receiver는 라이브 실측 결과 Wazuh manager·Shuffle 둘 다 "기존 endpoint 연결"이 아니라 새 통합 지점을 만드는 작업으로 판정해(상세는 완료 증거) 대신 OBS-01 임시 검증 receiver 패턴을 상시화한 `obs-13-receiver`로 고정했다. 각 rule은 인위로 만든 실제 조건에서 firing→Alertmanager active→실제 채널 수신까지 실증하고, 배포 직후·cleanup 후 모두 0건 firing을 확인했다. rollback은 PrometheusRule·receiver·ScrapeConfig·NetworkPolicy만 원복하고 최신 main의 `platform-root`·`obs` `Synced/Healthy` |
| `WAZUH-03 DONE` | 6개 Linux 대상 Wazuh agent 설치와 OPNsense 기존 agent HIDS 확장 (`infra/ansible/`, `gitops/apps/wazuh/`) | `WAZUH-02`, `OBS-11` | `OPNSENSE-LIVE` | 호스트 침해 탐지, `SOAR-01` 신호 품질 | `infra/ansible/roles/wazuh_agent_baseline`이 6대(rpm 5대 GPG 서명+checksum, proxmox-01 deb checksum)에 Wazuh agent 4.14.7-1을 설치해 기존 manager(`10.10.20.10:31514/31515`)에 `agent-auth`로 1회 등록했다. `ossec.conf`는 `syscheck`(대상별 최소 경로)·`rootcheck`만 선언하고 `syscollector`·SCA·`localfile`·`active_response`는 아예 없다. OPNsense 기존 agent는 `rootcheck`·`syscheck`만 `1`로 전환했고(플러그인이 경로 세분화 필드를 노출하지 않아 그 축소 수단은 없음, `gitops/apps/wazuh/README.md`에 한계로 기록) `active_response`·`syscollector`는 `0`으로 불변임을 재확인했다. `wazuh-manager-agent-ingress` NetworkPolicy에 6개 host IP를 추가하고 OPNsense에 cross-VLAN PASS 규칙 3건(`opt3`·`opt4`·`opt5`, MGMT `lan`은 기존 allow-all이라 신규 규칙 없음)과 port alias 1건을 신설해 immutable root `39af72e51fe652d3d467e98a05d1bb6f76b983c5`·child `1e49a8f025d771e4e01dabf7c6764ef8fbf784b6`에서 7개(OPNsense+6대) agent 전부 `Active`, k3s-01 syscheck의 실제 "File added" alert(rule 554)로 baseline scan 완료와 변경 탐지를 함께 확인, k3s-01 rootcheck 시작·종료를 agent 로컬 로그로 확인, 304초 관측창의 D30/A90 저장 증가량이 16 GiB 상한 안(측정 delta 0바이트), Loki FIM/rootcheck 복제본 0건을 판정했다. 라이브 검증 중 `WAZUH-01` rule `100130`(`if_group=ossec`)이 `0015-ossec_rules.xml` 전체를 감싸는 group을 상속해 agent 연결·rootcheck·syscheck alert를 전부 침묵시키던 기존 결함을 발견해 `if_sid=502`(Manager started만)로 좁혀 같은 브랜치에서 고쳤다. rollback은 6개 agent 제거, `apply-agent-hids.sh rollback`으로 OPNsense agent `syscheck`·`rootcheck`를 `0`으로, `apply-firewall.sh rollback`으로 방화벽 규칙·alias 제거, NetworkPolicy 6개 IP 원복이며 최신 main의 `platform-root`·`wazuh` `Synced/Healthy`, OPNsense drift 없음 |
| `WAZUH-04 DONE` | Keycloak·Pomerium·Vault·CrowdSec AppSec·Falco·Warpgate 6개 소스를 Wazuh D30/A90 직접 수집에 온보딩 (`gitops/apps/wazuh/`, `infra/ansible/`) | `WAZUH-01`, `KC-01`, `POM-01`, `VAULT-02`, `CROWDSEC-FIX-01`, `FALCO-01`, `WG-01` | `ARGO-ROOT` | 계정·접근·WAF·runtime 탐지 중앙화 | 원안(hostPath `<localfile>` 직접 tail)은 `pol-02-wazuh-root-manager-baseline`이 manager Pod의 hostPath를 k3s audit 로그 한 곳으로 고정해 admission에서 거부됐고, 대안(Alloy→remoted syslog remote 직접 수신)은 Wazuh의 원격 syslog(내부 queue type 2)가 로컬 파일 tailing(queue type 1)과 디코딩 경로가 달라 custom rule이 전혀 매칭되지 않는 것을 라이브로 확인했다. 최종적으로 k3s Pod 4종(Keycloak·Pomerium·Vault·Falco)과 CrowdSec AppSec은 Alloy(`gitops/apps/loki`, hostPath 없이 K8s API로 Pod 로그를 읽는다)가 O7 파이프라인이 이미 drop하는 보안 관련 라인만 골라 syslog로 전송하고, wazuh-manager Pod를 전혀 건드리지 않는 별도 Pod `wazuh-04-relay`(python stdlib TCP 릴레이 + 실제 wazuh-agent, `wazuh-04-relay-agent.yaml`)가 이를 받아 파일로 적은 뒤 `WAZUH-03`과 같은 secure agent 프로토콜(queue type 1)로 manager에 전달한다. wazuh-agent 이미지가 s6-overlay 초기화에서 UID 0을 요구해(PVC 없음, capability 7개는 manager와 동일) `pol-01-require-pod-run-as-non-root`에 이 Pod 이름만 좁힌 PolicyException 2건을 추가했다(`policies/pol-02-policy-exceptions.yaml`). Warpgate는 `WAZUH-03` host agent에 journald `<localfile>`(`_SYSTEMD_UNIT=warpgate.service`) 하나만 추가해 재사용한다(신규 방화벽 규칙 0건). 전용 rule ID는 A90 `100102`(Pomerium)·`100103`(Vault)·`100104`/`100105`(Keycloak 기본/인증 실패)·`100106`/`100107`(Warpgate 기본/인증 실패), D30 `100121`(Falco)·`100122`(CrowdSec AppSec WAF block)이며 `100108`~`100109`는 `WAZUH-05`를 위해 비웠다. 마스킹은 6개 rule 모두 `<options>no_full_log</options>`로 원문 저장을 막아(alerts.json에 `full_log` 필드 없음을 확인) 적용했다. 라이브에서 Pomerium 52건·Vault 232건·Keycloak 116건(기본 13+인증실패 103)·Falco 276건·CrowdSec AppSec WAF block 1건(직접 발생시킨 대표 event)을 D30/A90 index에서 확인했다. Warpgate는 설정을 diff로 확인해 적용하고 agent 재연결·journald 모니터링 시작(`(9203): Monitoring journal entries`)까지 라이브로 확인했지만, 실제 사용자 세션이 그 사이 발생하지 않아 대표 audit event 1건 확인은 다음 자연 발생 세션에서 스팟체크가 남아 있다(decoder/rule 매칭 로직 자체는 `wazuh-logtest`로 이미 검증됨). Loki O7 파이프라인은 기존 `loki.process` 흐름을 그대로 두고 두 번째 `forward_to`만 추가해 확인 시점에 정상 동작했고 이 6개 소스의 보안 event 복제본은 설계상 0건(O7이 drop하는 라인만 골라 wazuh로 보냄). D30/A90 저장 증가량은 별도 관측창을 두지 못해 라이브 관측치(약 10분 창에 6개 소스 합계 677건, alert 1건 평균 ~400바이트 무 `full_log`)로 추정하면 일 환산 약 39 MB 수준으로 16 GiB 상한에 크게 못 미친다(정밀 측정이 아니므로 후속 관측 권장). rollback은 `wazuh-04-relay-agent.yaml`·PolicyException 2건 제거, Alloy taps·otelcol 3종 제거, Warpgate `<localfile>` 제거(host agent는 `WAZUH-03` 종료 상태로 복원)이며 최신 main의 `platform-root`·`wazuh`·`loki`·`policy-baseline` `Synced/Healthy`, 신규 방화벽 규칙이 없으므로 OPNsense drift 확인은 대상 아님 |
| `WAZUH-04-FIX-01 DONE` | `wazuh-04-relay-agent`의 `client.keys`가 pod 파일시스템에만 있어 재시작마다 사라지고, `wazuh-agentd`의 자동 재등록이 같은 이름의 기존(비활성) 등록과 충돌해 영구 재시도에 빠지는 결함을 정적 키 렌더링으로 근본 수정 (`gitops/apps/wazuh/`) | `WAZUH-04` | `ARGO-ROOT` | `WAZUH-04` 6개 소스 수집 가용성 | WAZUH-04 병합 뒤 사용자가 Dashboard에서 `wazuh-04-relay`(당시 ID 009)의 `disconnected` 상태를 발견해 라이브로 원인을 특정했다: `client.keys`가 컨테이너 파일시스템에만 있어 pod가 재시작될 때마다 사라지고, `wazuh-agentd`의 자동 enrollment가 같은 이름의 기존(비활성) 등록과 매니저에서 충돌해(`ERROR: Duplicate agent name`) 영구 재시도에 빠졌다(즉시 완화로 `manage_agents -r`를 한 번 실행해 ID 010으로 재연결시켰으나 근본 원인은 남아 있었다). 근본 수정은 매니저에 이미 살아 있는 등록의 `client.keys` 한 줄을 `gitops/tools/wazuh-04-fix-01/apply-client-keys.sh`(check/apply 분리, 값은 어떤 모드에서도 출력하지 않음)로 `kv/wazuh/manager`에 새 필드 `wazuh_04_relay_client_keys`로만 patch하고(기존 필드는 `vault kv patch`로 보존, 새 Vault policy·role 없음 — manager와 이미 공유하는 read 경로), `vault-agent-relay-agent.hcl`이 `authd.pass` 대신 이 필드를 `/var/ossec/etc/client.keys`로 정적 렌더링하도록 바꿨다. `ossec.conf`의 `<enrollment>`는 `WAZUH-03` host agent와 동일하게 `<enabled>no</enabled>`로 고정해 `wazuh-agentd`가 아예 재등록을 시도하지 않는다. `ARGO-ROOT` 잠금 아래 `platform-root`·`wazuh`를 커밋 SHA `33ee3e8a423c3c21b2dc8611f51e9d5523501c61`로 전환해 `gitops/tools/wazuh-04-fix-01/verify-live.sh`로 실제 `kubectl rollout restart`를 실행했고, 새 pod의 `client.keys` ID가 재시작 전과 동일(010)·`ossec.conf` enrollment disabled 확인·`agent_control -l`이 재시작 전후 동일 ID `Active`·새 pod 로그의 `Duplicate agent name` 오류 0건을 모두 확인했다(`VerifyLive=PASS`). 검증 뒤 `platform-root`를 main SHA `f52dab78037ff00a192faf390b2e288a4044646e`로 되돌리자 아직 이 수정이 없는 main의 옛 spec으로 pod가 다시 롤백되며 같은 재등록 충돌이 즉시 재현되어(ID 010 재차 `Disconnected`) 결함 원인을 한 번 더 교차 확인했다 — 이 상태는 이 작업 병합과 함께 selfHeal로 해소된다. rollback은 `client.keys` 템플릿·`ossec.conf` enrollment·Deployment 커맨드를 `WAZUH-04` 병합 시점으로 원복하고 `kv/wazuh/manager`의 `wazuh_04_relay_client_keys` 필드를 제거 |
| `WAZUH-05 DONE` | NetBird `events.db` 감사 이벤트를 Wazuh A90 직접 수집에 온보딩 (`gitops/apps/wazuh/`, `infra/ansible/`) | `WAZUH-01`, `NB-01` | `ARGO-ROOT` | VPN peer·정책 변경 탐지 | NetBird 감사 기록은 로그 파일이 아니라 SQLite `events.db`(`netbird-01`, root:root 0600)라 `WAZUH-04`의 hostPath tail 패턴을 그대로 쓸 수 없다. 전용 non-root system user(`wazuh05-relay`)를 만들어 `events.db` 파일 하나에만 read-only POSIX ACL을 주고(`setfacl`, root 실행 없음), `netbird_audit_relay` ansible role의 60초 systemd timer가 `netbird-audit-relay.py`(순수 stdlib, `PrivateNetwork=true` 포함 전면 hardening)로 read-only(`mode=ro`) polling한다. NetBird 공식 소스(`activity/codes.go`)의 activity 코드 전체를 매핑해 "account·user·peer·정책·setup-key 변경과 접근 event"(계정 설정 토글 포함, group 변경은 정책 대상 변경으로 policy 버킷에 포함)만 골라 두 버킷(`account_access`/`policy_setupkey`)으로 나누고 `WAZUH-04`가 남긴 마지막 두 rule ID(`100108`=계정·사용자·피어·접근 level 3, `100109`=정책·그룹·setup-key level 5)에 각각 배정했다(추가 배정 없음). meta는 allowlist(`name`·`fqdn`·`ip`·`ipv6`·`group`·`group_id`·`type`·`is_service_user`·`pending_approval`·`created_at`)만 통과시켜 setup key 값(`key`)·geo/city(`location_*`)를 원천 제거하고, `wazuh_agent_baseline`에 새 `wazuh_agent_localfile_json_path` 변수로 `netbird-01`에만 JSON `<localfile>` 하나를 추가했다(decoder는 Wazuh 기본 `json`을 그대로 씀, 커스텀 decoder 없음). **라이브 검증 중 실제 결함을 하나 찾아 고쳤다**: 최초 배포에서 4건의 실제 로그인 유발 group 변경 event가 alerts.json에는 정확히 기록됐지만 A90 index에 전혀 나타나지 않았다. `_ingest/pipeline/_simulate`와 실제 색인 시도로 원인을 특정한 결과, 필드 이름을 `timestamp`로 뒀던 것이 문제였다 — 이 인덱스는 다른 `WAZUH-04` 소스가 이미 `data.timestamp`를 ISO 8601 `date` 필드로 매핑해 둔 상태였고, NetBird SQLite 원본 형식(공백 구분자·나노초)이 그 매핑과 파싱 충돌해 `mapper_parsing_exception`으로 ingest pipeline의 `on_failure`가 문서를 조용히 drop했다(원문은 남아 있어 발견이 늦었다). 필드명을 `event_time`으로 바꾸고 ISO 8601로 변환해 재배포한 뒤 `ARGO-ROOT` 잠금 아래 실제 A90 index 검색으로 두 rule(`100108`·`100109`) 모두 110건(실제 로그인 유발 group 변경 4건 포함, 과거 이력 재처리분 포함)을 확인했다. netbird-01 host agent는 재등록 없이 그대로 `Active` 유지, `events.db` polling 상태 파일(`last-event-id`)이 실제 `MAX(id)`와 일치해 재실행이 idempotent(중복 없음)함을 확인했다. Loki 복제본은 설계상 대상이 아니므로 0건이며(`LOKI-02` 별도 범위), 실측 볼륨이 12일간 118건(≈10건/일, event당 수백 바이트)으로 `WAZUH-04`가 이미 확인한 16 GiB 상한과 비교해 무시할 수준이라 별도 관측창 없이 정성적으로 판정했다. rollback은 `netbird_audit_relay` role·systemd unit·`events.db`의 ACL·`wazuh_agent_localfile_json_path`·`wazuh-05-a90-netbird-audit.xml` 제거이며(host agent는 `WAZUH-03` 종료 상태로 복원), 최신 main의 `platform-root`·`wazuh` `Synced/Healthy`, 신규 방화벽 규칙이 없으므로 OPNsense drift 확인은 대상 아님 |
| `LOKI-02 DONE` | 6개 Linux 대상 host journald/syslog를 Loki로 수집 (`infra/ansible/`, `gitops/apps/obs/`) | `LOKI-01`, `OBS-11` | `ARGO-ROOT` | 호스트 장애 조사 | `audit-event-standard.md`에 host 운영 로그(O7 확장) 분류를 추가해 대상을 `sshd`·`sudo`·systemd unit 실패·kernel(dmesg)로 한정하고, 인증 성공/실패 시도가 `WAZUH-03`의 보안 이벤트와 중복되지 않도록 소스별로 정확히 한쪽에만 보낸다. `k3s-01`·`postgres-01`·`object-01`·`warpgate-01`·`netbird-01`·`proxmox-01`에 checksum 고정 로그 수집 agent를 설치해 journald만 읽고(파일시스템 전체 tail 금지) hostname·unit label만 쓰며 PID·세션 단위 label은 만들지 않는다. Loki 14 GiB hard cap 안에서 실측 저장 증가량을 계산하고 초과 시 allowlist를 줄인다. 기존 K8s O7과 새 host O7이 `OBS-07` Log Explorer에서 host selector로 구분 조회됨을 확인한다. immutable root `e6773ae8398955647fc3a44683834d06bc55b3ad`·obs `a11ce4913e2c662720b5577f0df07978a094d5fd`에서 gateway private LB·6대 agent active를 확인하고, 승인된 `loki-02-o7-verify` transient failure를 host별 1회 생성·자동 수거했다. Loki는 6 host·12 record를 고정 5-label(`hostname`·`unit` 포함)과 `systemd_unit_failure` JSON만으로 반환했으며 원문은 조회·저장하지 않았다. 180초 관측창 S3는 14,101,348→14,106,083 bytes(4,735 bytes 증가; 180초 기준 보수 일환산 2,272,800 bytes)로 14 GiB retained·2 GiB/day cap 이하였다. OPNsense TCP 3100 rule 3건 snapshot과 normal drift도 일치한다. rollback은 6개 host agent 제거와 gateway·Loki 설정 원복이며 최신 main의 `platform-root`·`obs` `Synced/Healthy` |
| `OBS-14 DONE` | PostgreSQL·SeaweedFS·Warpgate·NetBird 등 앱 native metric 조사·수집 (`gitops/apps/obs/`) | `OBS-11`, `PG-01`, `S3-01`, `WG-02`, `NB-02` | `ARGO-ROOT` | 서비스 내부 상태 가시성 | 4개 VM(`postgres-01`·`object-01`·`warpgate-01`·`netbird-01`)에 SSH로 직접 접속해 read-only로 확인했다. PostgreSQL은 `postgres_exporter`·`pg_stat_statements` 등 어떤 Prometheus 경로도 없다(`5432`·`9100`만 LISTEN). SeaweedFS는 `infra/ansible/roles/seaweedfs_s3`의 4개 systemd unit(`master`·`volume`·`filer`·`s3`) 모두 `-metricsPort=0`으로 명시 비활성화돼 있음을 템플릿과 라이브 `ss -tlnp`로 함께 확인했다. Warpgate v0.26.1은 CLI(`warpgate --help`/`run --help`) 전체에 metrics 관련 옵션이 없고 `/metrics`·`/api/health`가 SPA 로그인 페이지로 200/307 fallback되는 것을 확인해 현재 버전은 native Prometheus 노출을 지원하지 않는다. NetBird management 컨테이너는 `--metrics-port`(기본 9090)를 갖고 있고 꺼 둔 적이 없어 실제로 컨테이너 내부 `0.0.0.0:9090`에 이미 LISTEN 중임을 `/proc/net/tcp`로 확인했지만, `docker-compose.yml.j2`가 이를 host에 publish하지 않고 Traefik route도 없어 Prometheus(k3s-01, cross-VLAN)에서는 도달 불가하다. 4개 제품 모두 지금 시점에 실제로 도달 가능한 노출이 없어 `up=1`을 낼 대상이 없으므로 이번 작업에서는 신규 `ScrapeConfig`·`NetworkPolicy`를 추가하지 않았다(라이브 변경 0건, rollback 대상 없음). PostgreSQL(신규 exporter 설치)과 SeaweedFS·NetBird(내장 flag 활성화 + `OPNSENSE-LIVE` 신규 방화벽 규칙)는 이번 `ARGO-ROOT` 단독 잠금 범위 밖이라 각각 `OBS-15`·`OBS-16`으로 열었다. Warpgate는 실행 가능한 후속 경로가 없어 새 백로그 ID를 만들지 않았다. 상세 조사 로그는 [`docs/evidence/obs-14/README.md`](evidence/obs-14/README.md) |
| `OBS-15 DONE` | PostgreSQL native metric 수집 — `postgres_exporter` 신규 설치 (`infra/ansible/`, `gitops/apps/obs/`) | `OBS-14` | `OPNSENSE-LIVE`, `ARGO-ROOT` | 서비스 내부 상태 가시성 | `postgres-01`에 최소권한 read-only DB role로 `postgres_exporter`를 checksum 고정 설치하고 `OBS-11` node_exporter 패턴대로 관리 주소에만 bind한다. `k3s-01`→`postgres-01` 신규 포트 exact PASS 1건을 OPNsense에 추가하고 `ScrapeConfig`·`NetworkPolicy`를 `obs`에 추가한다. target `up=1`과 `pg_stat_database_xact_commit` 등 대표 시계열을 확인한다. rollback은 exporter unit·DB role·`ScrapeConfig`·`NetworkPolicy`·방화벽 규칙만 원복하고 최신 main의 `platform-root`·`obs` `Synced/Healthy` |
| `OBS-16 DONE` | SeaweedFS `-metricsPort`·NetBird `--metrics-port` 활성화와 native metrics 운영 화면·경보 (`infra/ansible/`, `gitops/apps/obs/`) | `OBS-14` | `OPNSENSE-LIVE`, `ARGO-ROOT` | 서비스 내부 상태 가시성 | `object-01`의 SeaweedFS 4개 unit(`infra/ansible/roles/seaweedfs_s3`) `-metricsPort=0`을 관리 주소 bind로 전환하고, `netbird-01`의 `docker-compose.yml.j2`가 management 컨테이너의 기본 `--metrics-port`(9090)를 관리 주소에만 publish하도록 바꾼다. OPNsense `opt2` exact TCP PASS 5건(9325·9326·9327·9328·9090)과 `ScrapeConfig`·`NetworkPolicy`를 `obs`에 추가했다. immutable root `333ebbfce0495d9df2bcca71397ccbebb045f708`·obs `50dfe7b0ce6160059dc88f7ffc0e2ce0ef8523e5`에서 PostgreSQL 1·SeaweedFS 4·NetBird 1 target이 모두 `up=1`, 대표 series(PG 9개·SeaweedFS volume used·NetBird stream)가 반환됐다. read-only Grafana dashboard와 5분 `up=0` alert rule의 baseline firing 0건을 확인하고 최신 main의 `platform-root`·`obs` `Synced/Healthy`로 복구했다. rollback은 서비스 flag·docker publish·`ScrapeConfig`·`NetworkPolicy`·dashboard·alert rule·방화벽 규칙만 원복한다. 상세는 [`docs/evidence/obs-16/README.md`](evidence/obs-16/README.md) |
| `OBS-16-FIX-01 DONE` | OBS-16의 native metric 두 경보를 기존 상시 receiver route에 포함하고, 수신까지 한 번만 안전 검증 (`gitops/apps/obs/`) | `OBS-16` | `ARGO-ROOT` | PostgreSQL·SeaweedFS·NetBird 장애 알림 | `NativeMetricsTargetDown`·`PostgreSQLDatabaseMetricsDown`만 기존 `obs-13-receiver` route에 추가했다. immutable root `1bffd29e258c7c09bb8df0c357c4b6db3d41392f`·obs `c74d88a0fc662c92ac6ed92309f379b282673432`에서 runtime matcher·baseline 0건을 확인한 뒤, 같은 `NativeMetricsTargetDown`, `test=true`, 만료 시각 test alert 정확히 한 건이 receiver에 firing 1회·자동 만료 resolved 1회로 수신됨을 확인했다. 서비스·exporter·방화벽·경보 임계치·기존 5개 route·기본 discard·외부 egress는 변경 0건이고 종료 시 literal main `60cad6c5b6278fc384df1d2757ac3efca3490864`의 `platform-root`·`obs` `Synced/Healthy`다. 상세는 [`docs/evidence/obs-16-fix-01/README.md`](evidence/obs-16-fix-01/README.md) |
| `OBS-17 DONE` | Warpgate systemd·ACME timer와 private TLS 만료의 최소 경보 (`gitops/apps/obs/`, `infra/opnsense/`) | `OBS-16-FIX-01` | `OPNSENSE-LIVE`, `ARGO-ROOT` | 특권 접근 경로의 가용성·인증서 갱신 | `WarpgateServiceDown`·`WarpgateACMERenewTimerDown`은 기존 node_exporter의 active state가 5분간 1이 아닐 때만 critical이고, `Type=oneshot`인 `warpgate-acme-renew.service`의 inactive는 경보식에 넣지 않았다. blackbox의 private SNI probe가 `warpgate.imcherry5778.xyz:8888`에서 `probe_success=1`, TLS 잔여 78일(14일 초과)을 확인했으며, 세 alertname은 기존 `obs-13-receiver` matcher에만 추가했다. OPNsense `opt2` seq `1013` UUID `98957500-c698-4c3b-a241-a56db40d69ca`와 blackbox NetworkPolicy의 k3s-01→warpgate-01 TCP 8888 exact path만 추가했고 public DNS/NAT·외부 노출·인증서 재발급·서비스 재기동·합성 장애는 0건이다. immutable root `6687d26af1577335feac9f5694c07cde9c5f7a69`·obs `05af5367c623c2eeca1bd9f9e49e804c15333930`에서 verifier `ALL PASS`, rollback 뒤 literal main `d207ffc6b810daf9733f853ecab7f5cd7c837c55`의 `platform-root`·`obs` `Synced/Healthy`, OPNsense drift 없음을 확인했다. 완료 증거는 [`docs/evidence/obs-17/README.md`](evidence/obs-17/README.md)에 기록했다. |
| `OBS-18 DONE` | Alertmanager의 팀 운영 Slack 통지 경로 (`gitops/apps/obs/`, Vault, `infra/opnsense/`) | `OBS-16-FIX-01` | `VAULT-CONFIG`, `OPNSENSE-LIVE`, `ARGO-ROOT` | 클러스터 밖 운영자 인지 | Alertmanager는 `#platform-alerts`로 critical firing·resolved 모두 `@channel`, warning firing·resolved는 무멘션으로 보내고 info는 보내지 않는다. payload는 alertname·severity·instance·시각·Grafana link만 허용한다. 재발급 Incoming Webhook은 Git·ConfigMap·로그·명령 출력에 두지 않고 전용 `kv/obs/alertmanager`의 `slack_webhook_url` 한 field와 별도 Kubernetes auth policy·role로만 주입한다. Alertmanager는 Vault TCP 8200·내부 Slack CONNECT proxy TCP 8444만, proxy만 전용 source identity에서 `hooks.slack.com` FQDN alias TCP 443을 시작한다. proxy는 client source와 `CONNECT hooks.slack.com:443`을 고정해 FQDN alias의 L3 제한을 보강하며 기존 k3s 공용 HTTPS egress는 바꾸지 않는다. alias 검증이 불가능하면 포괄 egress로 완화하지 않고 중단한다. 승인된 일회성 `[TEST]` critical은 firing·resolved를 팀 채널에서 확인한 뒤 test alert·silence·임시 상태를 모두 제거한다. 기존 internal receiver와 보안 Slack secret·채널은 공유하지 않으며 최신 main의 `platform-root`·`obs` `Synced/Healthy`와 OPNsense drift를 확인했다. immutable root `27262d35eb5d49833ff431ff0ce0b6db7fba64fc`·obs `2b7da5b37797b70634dd9b92c7b6880de30f7584`에서 verifier와 internal receiver firing·resolved를 통과했고, 사용자가 #platform-alerts의 FIRING(11:35:26 UTC)·RESOLVED(11:36:56 UTC)를 확인했다. 상세는 [`docs/evidence/obs-18/README.md`](evidence/obs-18/README.md). |
| `WAZUH-06 DONE` | Wazuh high-severity 보안 사건의 분리된 Slack 통지 relay (`gitops/apps/wazuh/`, Vault) | `WAZUH-05`, `SOAR-01` | `VAULT-CONFIG`, `ARGO-ROOT` | 보안 사건의 팀 인지·조사 | `level >= 14`만 별도 Pod `wazuh-06-notifier`를 통해 `#security-alerts`로 보낸다. manager Pod에는 sidecar를 붙일 수 없고(`pol-02-wazuh-root-manager-baseline`이 `containers` 배열을 고정 이미지와 일치시킨다, `WAZUH-04`에서 확인) manager가 webhook을 읽으면 "중앙 수집기는 외부로 나가지 않는다"는 경계가 무너지므로, manager의 `custom-wazuh06` integration은 webhook을 모른 채 in-cluster Service로 allowlist payload만 넘기고 외부 TCP 443 egress는 notifier Pod가 단독으로 갖는다. `SOAR-01`의 `custom-soar01`(level 7) read-only·사람 승인 흐름은 그대로 두고 나란히 동작한다(라이브에서 `wazuh06=level14 soar01=level7` 공존 확인). credential은 전용 `kv/wazuh/security-notifier`·전용 policy·role이며 `wazuh-manager` policy에 이 경로 참조가 0건임을 확인했다 — `WAZUH-04`가 manager role을 재사용한 것과 반대 결정이다. payload는 severity·rule ID·description·group·agent alias·시각·Dashboard link 8개 필드만 allowlist하고 `full_log`·`previous_output`·`data.*`(srcip·dstuser·token)·`decoder`·`location`·`agent.ip`·`mitre`는 manager를 떠나지 못하며, notifier가 같은 allowlist를 다시 강제한다(2중 방어). `<`·`>`·`@`를 제거해 Slack 마크업·멘션 주입도 막는다. resolved 통지는 만들지 않는다(보안 사건은 상태 경보가 아니다). 라이브 실측 결과 전체 보존 기간의 `level >= 12` 경보가 **0건**(최대 level 8, 12건)이라 평상시 이 경로는 완전히 조용하고, 전달은 승인된 임시 level 14 test event 한 건으로만 판정했다. immutable root `2052e0f6917eb1d59a0af9f4aab6b963e1bdd184`·child `6f9d6869698e541bf235684efcd902748deab189`에서 `verify-live.sh`가 notifier 전용 SA·webhook `0440`·host 검증, manager 쪽 webhook 부재·Vault 렌더 무참조, integratord running, **manager → `hooks.slack.com` 차단(`000`)과 notifier → 도달(HTTP 200)**, 외부 egress 정책이 notifier TCP 443 정확히 하나, active-response disabled·`ar.conf` 차단성 명령 0건·Shuffle 외부 egress ipBlock 0건을 통과했다(`VerifyLive=PASS`). test event는 analysisd queue socket으로 한 건만 주입해(선언 `ossec.conf`에 `<localfile>`을 추가하지 않는다) `[TEST][SECURITY][CRITICAL] @channel` 메시지가 `#security-alerts`에 정확히 한 건 수신되고 원문·IP·사용자명·token이 없음을 스크린샷으로 확인했으며, 임시 rule `100129`·`alerts.json` 기록·indexer 문서 1건을 모두 제거했다(`temp_rule=absent alerts_json_records=0`). 라이브 검증 중 결함 하나를 같은 브랜치에서 고쳤다: `pol-01-require-pod-run-as-non-root`는 container가 아니라 **Pod spec**의 `securityContext.runAsNonRoot`를 보는데 이를 container에만 둬 첫 sync가 admission에서 거부됐고, Pod 수준에 선언해 PolicyException 없이 통과시켰다. **OPNsense 신규 규칙은 0건이다** — `opt2` seq `1032`(`NET-04`: k3s-01 → public IPv4 TCP 80/443)가 이미 이 경로를 포함해 `hooks.slack.com` FQDN alias PASS를 더해도 아무것도 좁히지 못하는 중복이 되고, 실제로 좁히려면 `NET-04` 소유의 그 규칙을 축소해야 해 범위 밖이다(`WAZUH-03`이 MGMT `lan` allow-all 때문에 신규 규칙을 만들지 않은 것과 같은 판단, 사용자 확인함). 목적지 제한은 NetworkPolicy(어느 Pod가)와 notifier의 `EXPECTED_HOST` 고정(어느 host로)이 나눠 담당한다. 라이브 변경이 없으므로 OPNsense drift 확인은 대상이 아니다. 마스킹 경계는 라이브와 무관하게 `gitops/tools/wazuh-06/tests/test_notifier_allowlist.py` 16개 테스트가 지킨다. `platform-root`를 main SHA `16bb95471a43f137e77fde45a7997d02fa7d58f0`로 되돌리자 notifier Pod와 NetworkPolicy가 prune돼 rollback 가능성도 함께 확인했다. rollback은 `wazuh-06-notifier.yaml`·ConfigMap 3종·`ossec.conf`의 `<integration>`·manager mount·SA·NetworkPolicy 제거와 `provision.sh rollback`이다 |
| `OBS-19 DEFERRED` | PostgreSQL·SeaweedFS·NetBird 사용량 baseline 후 임계치 경보 결정 (`gitops/apps/obs/`) | `OBS-15`, `OBS-16` | `ARGO-ROOT` | 경보 품질·운영 소음 | 발표일 2026-08-18이 28일 관측창보다 앞서므로 발표 완료 대상으로 삼지 않고 DEFERRED한다. 발표는 [`docs/evidence/obs-19/README.md`](evidence/obs-19/README.md)의 관측 경로·가용성 경보 요약만 사용한다. 2026-09-10 KST 이후 누적된 28일 관측 데이터로 PostgreSQL 연결/DB 상태, SeaweedFS volume 용량·disk error, NetBird connected stream·peer 상태의 일·주간 변동을 검토한다. 이 기간 전에는 새 용량·부하 임계치 경보를 추가하지 않는다. 기간 뒤 p50/p95/max와 실제 장애·점검 시간을 분리해 각 후보를 추가·보류·기각으로 판정하고, 근거가 있는 rule만 추가한다. `up`/`pg_up` 가용성 경보와 raw query·S3 object name·peer identity 수집 범위는 바꾸지 않는다. rollback은 새 threshold rule과 해당 route만 원복하며 최신 main의 `platform-root`·`obs` `Synced/Healthy` |

2026-08-13 `WAZUH-06`에서 "방화벽 규칙을 더하는 것"과 "실제로 좁히는 것"이 다르다는 점이
드러났다. 완료 조건은 OPNsense에 `hooks.slack.com` FQDN alias의 TCP 443만 허용하라고 적었지만,
라이브 규칙을 읽어보니 `NET-04`가 이미 `opt2` seq `1032`으로 `k3s-01` → public IPv4 TCP 80/443을
열어 두고 있었다(ACME·image pull·Renovate가 이 규칙에 매달려 있다). 그 위에 FQDN alias PASS를
더하면 이미 통과하는 트래픽의 부분집합을 다시 통과시키는 것이라 아무것도 제한하지 못하면서
drift와 "좁혔다"는 착각만 남는다. 실제로 좁히려면 seq `1032`를 축소해야 하는데 그건 `NET-04`
소유이고 이 작업 범위 밖이다. 그래서 신규 규칙 0건으로 두고, 목적지 제한은 NetworkPolicy(어느
Pod가 나갈 수 있는가)와 애플리케이션의 host 고정 검증(어느 host로 나가는가)이 나눠 담당하게
했다. 앞으로 "외부 서비스 하나만 허용" 류의 완료 조건을 쓸 때는 그 경계가 host 계층에서 이미
열려 있는지 먼저 확인하고, 열려 있으면 규칙을 더하는 대신 어디서 좁힐지를 명시한다.

또 하나: `level >= 14`는 이 랩에서 전체 보존 기간 동안 0건이었다(최대 level 8). 임계치를 높게
잡은 경보 경로는 "조용한 것"과 "고장난 것"이 구분되지 않으므로, 이런 경로는 배포 시점의 일회성
test event만으로 끝내지 말고 주기적으로 전달 경로가 살아 있는지 확인할 방법을 함께 갖는 편이
낫다. 이번에는 `WAZUH-06` 범위를 넘으므로 별도 작업으로 열지 않고 이 판단만 남긴다.

2026-08-12 `WAZUH-03` 완료 뒤 사용자 요청으로 Wazuh 수집 범위 gap을 재검토했다.
`docs/audit-event-standard.md`의 소스별 routing 표는 Suricata·Kubernetes 외에도 CrowdSec
AppSec·Falco·Vault·Keycloak·Pomerium·NetBird·Warpgate 7개 소스가 D30/A90으로 가야 한다고
이미 정의해 뒀지만, `WAZUH-01` README가 "전 소스 온보딩은 이 작업 범위가 아니다"로 명시적으로
미뤄둔 뒤 지금까지 아무도 손대지 않은 상태였다(`FALCO-01`도 후속 필드에 `Wazuh`를 남겨둔
채였다). 7개를 실제 수집 메커니즘 기준으로 나눠보면 NetBird만 감사 기록이 로그 파일이 아니라
SQLite `events.db`라 새 polling 메커니즘이 필요하고, 나머지 6개(Keycloak·Pomerium·Vault·
CrowdSec AppSec·Falco·Warpgate)는 `WAZUH-01`이 K8s audit에 이미 쓴 hostPath tail + decoder +
전용 rule ID 패턴을 그대로 반복 적용할 수 있다. 그래서 제품이 아니라 구현 패턴 기준으로
`WAZUH-04`(같은 패턴 6개)와 `WAZUH-05`(NetBird 단독, 새 메커니즘이라 실패해도 나머지 6개
merge를 막지 않게 격리)로 나눠 연다. 둘 다 선행(`WAZUH-01`과 각 제품 배포 작업)이 모두
`DONE`이라 `READY`다. A90 예약 rule ID(`100102`~`100109`, 8개)를 두 작업이 나눠 써야 하므로
`WAZUH-04`가 먼저 배정하고 최소 1개 이상을 `WAZUH-05`용으로 비워 두도록 각 작업 설명에
명시했다.

2026-08-12 `WAZUH-03`은 immutable root `39af72e51fe652d3d467e98a05d1bb6f76b983c5`와 child
`1e49a8f025d771e4e01dabf7c6764ef8fbf784b6`에서 `verify-live.sh`로 판정했다. 6개 host agent
설치와 OPNsense agent HIDS 확장 자체는 계획대로 진행됐지만, 라이브 검증 중 FIM alert가
계속 0건으로 나와 원인을 추적한 결과 `WAZUH-01`이 만든 rule `100130`(`<if_group>ossec</if_group>`,
"manager 자신의 기동·종료·연결 상태만 억제"할 의도)이 `ruleset/rules/0015-ossec_rules.xml`
전체를 감싸는 `<group name="ossec,">` 때문에 agent 연결·해제(rule 501/503~506)와
rootcheck(509+)·syscheck(550/553/554 등) 전부를 level 0으로 침묵시키고 있었다는 기존 결함을
발견했다. `WAZUH-01`·`WAZUH-02`는 rootcheck·syscheck를 켠 적이 없어 지금까지 드러나지
않았다. `if_group`을 존재하지 않는 그룹으로 바꿔 rule을 무력화한 A/B 테스트로 재현·확인한
뒤(neutralize 상태에서 rule 554 "File added to the system" alert가 즉시 나타남), `<if_sid>502</if_sid>`
(Manager started만 정확히 가리킴)로 좁혀 같은 브랜치·같은 커밋 계열에서 고쳤다. 이 결함은
merge 전 발견이라 별도 FIX 작업 ID를 만들지 않고 `WAZUH-03` 범위에 포함했다.
FIM 검증 방식도 실측 중 바로잡았다: `wazuh-agent` 전체 재시작(`systemctl restart`) 직후의
`scan_on_start`는 새 파일을 로컬 `fim.db`에 기록만 하고 "added" alert를 보내지 않았고,
이미 떠 있는 agent에 Manager API `PUT /syscheck?agents_list=<id>`로 즉시 재스캔을 요청하는
경로만 정상적으로 alert를 생성했다(실제 운영 중 scheduled rescan과 같은 코드 경로). manager
가 원래 갖고 있던 diagnostic 패치는 검증 직후 즉시 원복했고 최종 수정은 GitOps 커밋으로만
반영했다. 7개(OPNsense+6대) agent 전부 `Active`, k3s-01 rootcheck 시작·종료 로그, 304초
관측창의 D30/A90 저장 증가량 0바이트(16 GiB 상한 안), Loki FIM/rootcheck 복제본 0건을
확인했다. OPNsense agent의 syscheck는 플러그인 자체가 경로 세분화 필드를 노출하지 않아
"감시 경로 최소화"를 이 플러그인 안에서 더 좁힐 수단이 없다는 한계를 완료 증거에 그대로
남겼다. 검증 뒤 root·child는 main `894a716405a9d00b28b0953c4b4582f39b1782fe`의
`Synced/Healthy`로 복귀했다.

2026-08-12 `WAZUH-04`는 세 번의 설계 실패를 거쳐 지금 형태로 정착했다. 1차(원안)
hostPath `<localfile>` 직접 tail은 `pol-02-wazuh-root-manager-baseline`의
`restrict-wazuh-manager-host-paths`가 manager Pod의 hostPath를 k3s audit 로그
한 곳으로 고정해 admission이 `wazuh-manager-master-0` 생성 자체를 거부해
라이브 outage로 이어졌다(manager pod 0/1). 2차(Alloy→remoted syslog remote
직접 수신)는 hostPath 문제는 피했지만 Wazuh의 원격 syslog(내부 queue type 2)가
로컬 파일 tailing(queue type 1)과 디코딩 경로가 달라 custom decoder/rule이
전혀 매칭되지 않았다 — `wazuh-logtest`는 라이브 캡처와 정확히 같은 바이트로
성공하는데도 실제 remoted 수신 1,800건 이상 중 alerts.json에 단 한 건도
기록되지 않았다(Wazuh 자신도 이 경로를 legacy로 보고 제거를 논의 중,
wazuh/wazuh#34729). 3차(manager Pod에 python relay 사이드카 추가)는
`pol-02-wazuh-root-manager-baseline`의 `require-wazuh-manager-baseline`이
containers 배열 전체를 고정 이미지와 정확히 일치하도록 강제해 두 번째
container 자체가 거부됐다. 최종(4차)은 manager Pod를 전혀 건드리지 않는
별도 Pod `wazuh-04-relay`(python relay + 실제 wazuh-agent)를 세워 `WAZUH-03`
6대와 같은 secure agent 프로토콜로 전달하는 방식이며, 그 wazuh-agent
container가 s6-overlay 초기화(`/var/run/s6` mkdir)에서 PVC 유무와 무관하게
UID 0을 요구해(non-root로 라이브 실패 확인) `pol-01-require-pod-run-as-non-root`에
이 Pod 이름만 좁힌 PolicyException 2건을 추가했다 — manager가 이미 가진
것과 같은 이유·같은 형태의 예외다. 이 과정에서 Alloy config 문법(River는
`#`가 아니라 `//`만 주석), `otelcol.exporter.syslog`의 public-preview
stability gate, ConfigMap subPath 디렉터리가 fsGroup을 상속하지 않는 점
등 여러 실측 결함을 함께 고쳤다. 최종 라이브 검증은 wazuh 자신을 두 번(1차
hostPath outage 복구, 2차 relay+agent 배포) 포함해 root·child를 여러 차례
재조정했고, 매번 실패 즉시 해당 child를 main으로 롤백한 뒤 같은 브랜치에서
원인을 고쳐 재검증했다. 완료 증거의 rule ID별 alert 건수와 Warpgate의 남은
스팟체크 항목은 위 표 셀에 정리했다.

2026-08-12 `OBS-13`은 immutable root `7effa4bbab1c21d314489e0eb1fa05e0d9b9b99d`와 child
`e7e55c55fe2ebf1b5c6eb98708cf1ccf55f3aa2c`에서 `verify-live.sh`로 판정했다. backlog 원안의
"기존 Wazuh manager나 Shuffle 중 하나로 webhook forward"는 라이브 실측 결과 둘 다 새 통합
지점(Wazuh는 HTTP 수신 경로 자체가 없어 새 브리지·decoder·rule 필요, Shuffle은 `SOAR-DASH-01`이
막아둔 외부 앱 다운로드 없이는 webhook trigger에 action을 붙일 수 없음)을 만드는 작업이라
사용자와 함께 재검토해 `obs` 안의 상시 `obs-13-receiver`(OBS-01 임시 검증 패턴의 상시화, 새
credential·외부 egress 0건)로 대체했다. k3s-01 root filesystem 대표 시계열은 기존 DaemonSet의
non-root 권한 한계(`OBS-11`이 이미 발견)를 확대하지 않고 별도 포트(9101)의 host-level
node_exporter로 보완했다. 5개 alertname(NodeDown·RootFilesystemUsageWarning/Critical·
TLSCertificateExpiringSoon·VeleroBackupFailed) 전부 실제 조건에서 firing→Alertmanager
active→수신을 확인했고, 배포 직후·유발 조건 cleanup 후 모두 0건 firing이었다. 검증 중
Alertmanager PVC의 notification 이력이 반복 수동 테스트로 오염돼 `VeleroBackupFailed` 발송이
막힌 것을 발견해 PVC를 재생성(당시 실제 silence 0건, 손실 없음)해 해소했다. 상세 증거는
[`docs/evidence/obs-13/README.md`](evidence/obs-13/README.md)가 소유한다. 검증 뒤 root·child는
main `f7ea23546e67b2e85c2603db6769febb787ac9b8`의 `Synced/Healthy`로 복귀했다.

2026-08-12 `OBS-11` 완료 뒤 사용자 요청으로 관측·보안 커버리지 gap을 재검토해 `OBS-13`(Prometheus
상시 alert rule과 실제 알림 채널)·`WAZUH-03`(6개 Linux 대상 Wazuh agent와 OPNsense 기존 agent의
HIDS 확장)·`LOKI-02`(host journald/syslog 수집)·`OBS-14`(PostgreSQL·SeaweedFS·Warpgate·NetBird
native metric 조사)를 새로 연다. 넷 다 선행이 모두 `DONE`이라 `READY`다. 우선순위는 `OBS-13`
(지금은 대시보드를 사람이 봐야만 이상을 아는 상태) → `WAZUH-03`(OPNsense조차 FIM·rootcheck가
꺼져 있고 나머지 6개 대상은 agent 자체가 없는 상태) → `LOKI-02`·`OBS-14` 순으로 판단한다.

2026-08-11 `WAZUH-02-FIX-01`은 immutable root `b1339b0727e07f06a7d9d40b2a8e6fb574be367c`와 child `2f8f433593fc0cd9ae74552e9ff7a9c4ebc8ba58`에서 Keycloak client·Vault key·Indexer native OIDC domain·`all_access=wazuh-admin`을 확인했다. `imcherry5778-admin`이 Pomerium 통과 뒤 Dashboard native OIDC 세션으로 D30 sid `2029054`와 A90 기존 문서를 모두 검색했고, 검증 뒤 root·child는 main `2dc37f1a82ab404ff0f6cd6c2772e0b5df42391e`의 `Synced/Healthy`로 복귀했다.

2026-08-12 `WAZUH-02-FIX-02`는 immutable root `9239e8af13141923b32bf18a1fd2422638104f57`와 child `4ce771e197b6af32e4e23afe777b4e5c4673b99c`에서 Dashboard native multi-auth `basicauth+openid`와 `Keycloak SSO로 로그인` 선택 선언을 확인했다. 특권 계정은 Pomerium 통과 뒤 명시적인 Keycloak OIDC 선택으로 D30 sid `2029054`·A90 기존 문서를 조회했고 Server API check도 Online이었다. Keycloak client·role·group·Vault·Indexer security 변경은 없었으며, 검증 뒤 root·child는 literal `main`과 main `4f5811441f67b7af882d06eddcf320648d6c237b`의 `Synced/Healthy`로 복귀했다.

2026-08-12 `WAZUH-02-FIX-03`은 immutable root `50f0cbc1590023b800c6369370221dd7b26968a2`와 child `0ab08780ed8760f226fea08f09c1ab9ffc1bd6f0`에서 Dashboard가 생성한 `wazuh.yml`의 port 없는 Manager URL·단일 `55000`·`run_as:false`를 확인했다. 특권 OIDC session의 실제 `/api/login` scoped Manager token도 HTTP 200으로 발급됐고, API 사용자·Vault·Keycloak·Pomerium·Indexer RBAC 변경은 없었다. 검증 뒤 root·child는 literal `main`과 main `688db86570f78be63d353b7f77f4c8f08eca054f`의 `Synced/Healthy`로 복귀했다.

2026-08-03 `OBS-02`와 `WAZUH-02`를 신설한다. 두 작업은 결정된 목표와 실제 구현이 어긋난
상태를 닫는다. 이 저장소는 ADR과 `architecture.md`가 "무엇을 만들 것인가"를, 백로그가
"무엇을 할 것인가"를 소유하는데 둘을 대조하는 절차가 없다. "완료 증거 표에 적힌 항목만
검증한다"는 규칙은 중복 검증과 drift를 막지만, 완료 증거 표에 들어가지 않은 목표는 소유자
없이 남는다. 아래 두 건이 그 경우다.

`WAZUH-02`가 닫는 것은 명시적 결정이다.
[ADR-0007](adr/0007-detection-and-observability-staging.md)은 "보안 이벤트는 각 소스에서
Wazuh로 직접 수집하고 Wazuh Dashboard에서 조사한다"로 조사 창구를 Dashboard로 정했고
[`architecture.md`](architecture.md)의 탐지 흐름도 `Wazuh → Wazuh Dashboard → Shuffle`이다.
`WAZUH-01`이 Dashboard를 배포하지 않은 근거는
[`wazuh/README.md`](../gitops/apps/wazuh/README.md)의 "완료 증거를 indexer REST API로 만들 수
있다" 한 줄이며 이는 검증 범위 최소화의 결과이지 Dashboard가 불필요하다는 판정이 아니다.
ADR-0007을 대체하는 새 결정도 없으므로 현재는 결정과 구현이 어긋난 상태다.

`WAZUH-02`와 `SOAR-01`은 같은 여유 용량을 두고 경쟁한다. `CAP-04` 시점 `k3s-01` available은
14,481,977,344 bytes(13.487 GiB)이고 `SOAR-01` 진입선이 12 GiB이므로 잔여는 1.487 GiB다.
Dashboard가 이를 소비하면 `SOAR-01`은 `k3s-01`을 32 GiB로 올리기 전에는 진입할 수 없다. 이
lane의 상한은 `CAP-04`가 계산한 대로 32 GiB이며 36 GiB는 VM RAM 회계를 53 GiB로 만들어
52 GiB 경고선을 넘는다.

따라서 `SOAR-01`의 선행에 `WAZUH-02`를 추가하고 규칙 2에 따라 `READY`에서 `BLOCKED`로
되돌린다. 사람이 경보를 눈으로 확인할 창 없이 자동 대응을 얹는 것은 ADR-0007의 재검토 조건인
"경보 분류, 보존기간과 오탐 기준이 합의된다"를 충족하지 못한 채 SOAR를 시작하는 것이다.
`WAZUH-01`이 `NIDS-01` 테스트 룰 3건으로 전체 경보의 99.87%가 만들어지는 것을 발견해 저장
직전 ingest에서 제외한 것이 그 판단의 실례다. 이 종류의 오탐은 조사 창구 없이 찾기 어렵고,
찾지 못한 채 자동화를 얹으면 오탐에 반응하는 흐름이 된다. `SOAR-01`은 `WAZUH-02` 완료 뒤 남은
available로 진입선 12 GiB를 다시 판정하며, 미달이면 `k3s-01` 32 GiB 증설이 선행이다.

`OBS-02`는 `ip-plan.md`가 `grafana.imcherry5778.xyz`의 노출을 `Pomerium`으로 적어 두고도
소유 작업이 없어 미등록으로 남은 항목을 닫는다. `OBS-01`의 완료 증거는 Alertmanager까지의
실제 경보 전달이었고 Grafana UI는 증거가 아니어서 port-forward 확인조차 하지 않았다. 즉
수집과 전달은 검증됐지만 사람이 보는 창은 한 번도 열린 적이 없으며 `defaultDashboardsEnabled`도
꺼져 있다. 따라서 이 작업은 route만이 아니라 열었을 때 볼 것이 있는 상태까지를 범위로 한다.
Prometheus와 Alertmanager는 `ip-plan.md`의 DNS 표에 이름이 없으므로 alias를 새로 추가한다.
ADR-0007이 Grafana를 창구로 지정한 것은 사실이나 Prometheus UI를 금지하지는 않았고,
Alertmanager silence는 Grafana가 대체하지 않는 운영 경로다. 세 서비스는 같은 `obs`
namespace에 이미 배포돼 있어 Route 추가는 RAM을 늘리지 않으므로 `K3S-HEAVY` 잠금과 capacity
gate 없이 한 작업으로 묶는다. 다만 `pomerium` namespace는 default-deny이고 `POL-01-FIX-01`이
Dashy→Keycloak egress 누락으로 이미 한 번 실패했으므로 대상 namespace egress를 Route와 함께
선언한다.

2026-08-04 `OBS-02`에서 immutable root `af98312b53bf99858312b5cf3fb274d7b4156d7b`와 child
`8c32ae94aa1ccfd4e295041030cca413960fe8fc`로 Grafana·Prometheus·Alertmanager Route를 검증했다.
Grafana의 `Platform` dashboard는 node·PVC·Loki 대표 query를 표시했고, Prometheus의 node-exporter
target `up=1`과 PromQL, Alertmanager의 특권 session silence 생성·조회·만료를 확인했다. 일상
`/platform-users` session은 세 UI를 연속 통과했고 group 없는 session은 모두 403이었으며,
Alertmanager write는 `/platform-privileged`에만 허용됐다. 첫 backend 503은 Pomerium egress만
있고 `obs-default-deny`의 cross-namespace ingress 허용이 없던 원인으로 확인해, 세 backend의
Pomerium source·target Pod·port를 정확히 짝지은 ingress 정책을 추가했다. Loki는 datasource
resource handler가 아닌 proxy endpoint로 원래 query API를 전달하도록 보정했다. 내부 DNS는 세
alias 모두 A `10.10.20.10` 하나, 내부 AAAA와 공개 A/AAAA 0건이었고 OPNsense drift는 없었다.
배포 전 available은 12,996,599,808 bytes·swap 0·PVC 요청 97,844,723,712 bytes로 정지선을
통과했고 신규 PVC·HelmChartConfig generation·Traefik Pod UID/restart 변화는 없었다. rollback 뒤
root·`obs`·`pomerium`은 literal `main`에서 `Synced/Healthy`였고 기존 Pomerium Route와
Alertmanager Ready endpoint는 유지됐다. 직접 후속은 없다.

2026-08-04 `WAZUH-02`에서 immutable root `f96520c5f13dd8e1a002102d1c1819007e206a2a`와 child
`b7a36d8d1ad2ed2f71085a593b90d322d6c63ab0`(`wazuh`·`pomerium` 둘 다 같은 commit)로 Wazuh
Dashboard를 검증했다. `admin` 계정으로 Dashboard 자체 보안에 로그인한 뒤
`/api/console/proxy`로 `wazuh-alerts-4.x-*`의 sid `2029054*`와 `wazuh-alerts-4.x-audit-*`의
`rule.id:[100100 TO 100109]`를 조회해 `WAZUH-01`이 이미 수집한 문서를 Dashboard 경로로
찾았다(새 트래픽 재생성 없음). `/platform-privileged`(`imcherry-admin`)는 Route를 통과했고
`/platform-users`만 가진 `imcherry`는 403이었다. active response `disabled=yes`와
`wazuh-01-d30`·`wazuh-01-a90` ISM 정책은 배포 전후로 그대로였고 indexer·manager Pod는
재시작 없이 8시간 무변화를 유지했다. `wazuh` AppProject의 `namespaceResourceWhitelist`에
`apps/Deployment`가 없어 첫 sync가 거부된 것을 원인으로 확인해 같은 commit에서 whitelist를
넓혔다(manager·indexer가 StatefulSet만 써서 최초 선언에 빠져 있었다). capacity gate는 배포
전 available 13,179,863,040 bytes(12.273 GiB)에서 배포 후 12,715,151,360 bytes(11.842 GiB)로
자기 8 GiB 정지선을 통과했고 PVC는 91.125 GiB로 불변이었다. 다만 `SOAR-01` 진입선
12 GiB(12,884,901,888 bytes)에는 169,750,528 bytes(약 161.9 MiB) 미달이었다. Unbound `wazuh`
alias는 내부 A 1건만 등록했고 공개 A/AAAA는 없다. rollback 절차는 indexer·manager를 건드리지
않고 Dashboard 리소스와 `kv/wazuh/dashboard`만 되돌리도록 새로 설계했다(WAZUH-01의 전체
namespace 삭제 rollback과 분리).

`SOAR-01`은 이 결과로 진입선 미달이 확정됐으므로 `READY`로 열지 않고 `BLOCKED`를 유지한다.
`k3s-01` 32 GiB 증설([runbook](runbook/k3s-ram-expansion.md))이 그 선행이며, 아직 전용 작업
ID가 없으므로 새로 열지 않고 이 사실만 기록한다. 증설 작업 ID를 만드는 결정은 이 세션 범위가
아니다.

2026-08-04 `CAP-04`, `WAZUH-02`가 모두 `DONE`이라 `CAP-05`를 신설해 `READY`로 연다.
`CAP-03`(24→28 GiB)과 같은 VMID 120, 같은 잠금(`PVE-LIVE`, `TOFU-STATE`, `K3S-BOOTSTRAP`)
구조를 그대로 따르며 목표만 28→32 GiB로 바뀐다. `CAP-04`가 이미 이 증설을 조건부로
계획해뒀던 값(`28672→32768`, `0 add, 1 change, 0 destroy`)을 그대로 쓴다. 라이브 적용은
OpenTofu apply와 `k3s-01` 단일 서버 재부팅을 수반해 AGENTS.md의 "k3s server·물리 호스트
재시작" 승인 대상이므로, plan 확정 뒤 적용 직전에 별도 승인을 받는다. 완료 뒤에는
`k3s-01` available을 재측정해 `SOAR-01` 진입선 12 GiB 충족 여부로 `SOAR-01`의 `READY` 전환을
다시 판단한다.

2026-08-04 `CAP-05`에서 승인된 plan으로 VMID 120의 `memory.dedicated`만 `28672→32768`로
적용했다. 적용 직전 real state의 harmless refresh(게스트 agent가 보고하는
`ipv4_addresses`·`mac_addresses` 배열 순서만 재정렬, 다른 속성 diff 0건)로 최초 plan
`553a8fcebf5c53c7f200d6183c7baaa97f2c7d5a3fae5366447c6a8e3ecf4ba8`이 stale해져, 같은 state에서
`dc5d2d9bb8f11908b3887fe871f66eefd7819c3c731cb51178f772ee2bcafaae`를 다시 만들어 승인 범위와
동일한 `0 add, 1 change, 0 destroy`를 재확인한 뒤 적용했다. state SHA-256은
`f91f85cb0dec985f5ac84ac32957a9328e9684ea0bfceb60467122f5bc8974a7`(serial 5, rollback
지점)에서 `d42951947dc3c08d0295bda8614d943abbf09ff843bbdb4b27b6d65221634bc7`(serial 6)로
바뀌었고, OpenTofu 자체 pre-apply backup(`c42ee0f95ea72ca431b3c5443e964aabd04fecf1a24e5b5739ca935d6f9d317f`)을
저장소 밖 mode `0600` 사본으로 이중 보관했다.

Proxmox `qm pending`이 `cur memory: 28672`·`new memory: 32768`로 나뉘어 있어 `CAP-03`과 같이
정상 재부팅으로는 활성화되지 않음을 확인하고, guest `sudo shutdown -h now`로 정상 종료한 뒤
VMID 120을 cold start했다. boot ID는 `4e745572-8cf3-4bd2-91c2-a572ad45a382`에서
`5ebae80a-04a7-4765-a2c7-e8b9c037500d`로 바뀌었고 guest `MemTotal`은
29,154,533,376→33,382,391,808 bytes로 늘었으며 swap은 재부팅 전후 모두 0이다. k3s는 재기동
직후 `active`, Node `Ready`였다. Vault는 `KMS-01`이 도입한 AWS KMS auto-unseal(`Seal Type:
awskms`)로 별도 키 입력 없이 `Sealed: false`·`HA Mode: active`가 됐다.

재부팅이 모든 Pod를 한 번씩 재시작하며 `CAP-03`에서 이미 관측된 것과 같은 계열의 결함이
재현됐다. `crowdsec-appsec` Deployment의 init container `extract-crowdsec-01-crs-snapshot`이
새 sandbox에서 exit code 1로 실패해 `crowdsec` Application이 `Progressing`에 머물렀다
(스크립트가 표준출력을 `/dev/null`로 버려 정확한 실패 지점은 로그에 남지 않았다). `CAP-03`과
동일하게 정확한 Pod 한 건만 삭제해 ReplicaSet이 새 sandbox로 재생성하게 하자 다음 시도에서
Ready가 됐고, 이후 Argo 22개 Application이 모두 `Synced/Healthy`로 돌아왔다. 이 초기화는 매
`k3s-01` 전체 재부팅마다 재현될 수 있는 비멱등 결함이며 근본 수정은 이 작업 범위 밖이라
별도 검토로 남긴다. `kube-system`의 `helper-pod-delete-pvc-*` 여러 개가 SELinux 권한 거부로
반복 실패·재생성되는 현상도 관측했으나, 이는 `K3S-01` 완료 보고가 이미 남긴 local-path 삭제
helper의 SELinux 환경 한계와 같은 계열이고 이번 재부팅이 새로 만든 결함이 아니다. 두 현상
모두 PVC 선언·Argo 동기화 대상·capacity gate에는 영향이 없어 `CAP-05` 범위에서 고치지
않았다.

최종 실측: Proxmox available 32,170,692,608 bytes(29.960 GiB)·swap 0; VM RAM 회계는
44→48 GiB(overhead 포함 45→49 GiB)로 52 GiB 경고선 아래 3 GiB; `k3s-01` available은
12,710,690,816→18,511,921,152 bytes(11.837→17.244 GiB)로 `SOAR-01` 진입선 12 GiB
(12,884,901,888 bytes)를 5,627,019,264 bytes(5.240 GiB) 웃돈다; guest swap 0·root
사용률 20%로 불변; PVC 요청 합계는 91.125 GiB(11개)로 불변이다. 최종 refresh plan
`02cb0bd3683c401596fa91ac7baacb7b4fa5da6ddbab54bca5ee87ff0865fd1d`은 state resource 5개
모두 `no-op`, 변경·비통과 check 0건이며 plan 전후 state SHA-256은
`d42951947dc3c08d0295bda8614d943abbf09ff843bbdb4b27b6d65221634bc7`로 불변이다.

`SOAR-01` 진입선을 충족했으므로 `CAP-05`를 `DONE`으로 닫고, 선행이 모두 충족된 `SOAR-01`을
`BLOCKED`에서 `READY`로 전환한다. 상세 값과 rollback은
[`k3s-01 RAM 증설 runbook`](runbook/k3s-ram-expansion.md)과
[`capacity-plan.md`](capacity-plan.md)의 `CAP-05` 절이 소유한다.

2026-08-03 `AUDIT-01`에서 대상 아홉 소스의 기존 event 한 건씩을 read-only 구조로 확인하고
[단일 분류·보존 표준](audit-event-standard.md)을 확정했다. 탐지 event는 Wazuh 30일,
API·identity·접근 감사 metadata는 Wazuh 90일, 운영 로그는 Loki 7일로 분리하고 같은 event의
중복 저장을 금지했다. UTC 시각, native 사용자·SA·peer와 request/trace/session/flow ID를
필수 계약으로 두되 없는 ID는 `없음`과 대체 composite key를 명시했다. token·Secret·body·
command argument·파일/세션 내용은 수집 전에 제거하며, 저장 후 일일 증가량에서 역산한 Wazuh
16 GiB·Loki 14 GiB hard cap을 후속 capacity gate로 넘긴다. GitOps와 라이브 구성은 바꾸지
않았다. 따라서 직접 후속 중 선행이 모두 충족된 `LOKI-01`만 `READY`로 열고, `WAZUH-01`은
`OBS-01`이 남아 `BLOCKED`를 유지한다.

2026-08-03 `LOKI-01`에서 Grafana Alloy와 Loki를 digest·chart SHA로 고정해 `k3s-01`에
배포하고 O7 운영 로그만 Kubernetes API에서 allowlist 수집했다. 30분 고정창의 5,000건은
모두 O7이었고 Falco rule match, Pomerium authz, Vault audit, Keycloak event는 각각 0건이었다.
index label은 일곱 저cardinality field뿐이며 Pod·resource UID는 structured metadata로 남았다.
원문은 local spool에 기록하지 않고 Event `message`는 생성 단계부터 제외했다. S3 저장량은
1,805초 동안 154,695 bytes 증가해 7,404,792 bytes/일로 환산됐고 retained 272,996 bytes와
함께 14 GiB·2 GiB/일 hard cap 이하였다. running config의 7일 retention과 compactor 성공,
immutable root·child의 `Synced/Healthy`를 확인했다. 신규 PVC는 0개이며 배포 직후 available은
8 GiB 정지선보다 2,119.895 MiB 높았다. 따라서 `LOKI-01`을 완료하고 직접 후속 `OBS-01`만
`READY`로 연다. `WAZUH-01`은 `OBS-01`이 남아 `BLOCKED`를 유지한다.

2026-08-03 `OBS-01`에서 kube-prometheus-stack chart `88.1.3`과 blackbox chart `11.16.0`을
tarball SHA·source commit·image digest로 고정해 Prometheus Operator, Prometheus,
Alertmanager, node-exporter, kube-state-metrics, Grafana를 배포했다. node·PVC·Velero backup,
Traefik의 실제 TLS 인증서와 Loki·Alloy target은 모두 `up=1`이었고 각각 대표 시계열을
조회했다. cert-manager는 현재 설치·소비자가 없어 추가하지 않았고 인증서는 blackbox가
SNI와 chain을 검증했다. 전용 rule은 Prometheus firing, Alertmanager active를 거쳐 임시
receiver에 `RECEIVED alertname=OBS01Delivery status=firing`으로 실제 수신됐고 자원은 제거했다.
Prometheus running retention은 3일·6 GiB, PVC는 8 GiB와 Alertmanager 1 GiB뿐이었다. 최종
배포 전·후 available은 10,273,751,040→9,978,179,584 bytes, swap 0, PVC 합계는
66.125→75.125 GiB였으며 immutable root `d9b7d31aa23b93a04e7dca8bcc99a6949302f71f`와 child
`544d6611c4d43f8443cba905f56059be4c80fa05`가 `Synced/Healthy`였다. OPNsense metrics는 승인대로
`OPN-METRICS-01`로 분리했다. 따라서 `OBS-01`을 완료하고 직접 후속 `OPN-METRICS-01`과
`WAZUH-01`을 `READY`로 연다. `SOAR-01`은 `WAZUH-01`이 남아 `BLOCKED`를 유지한다.

2026-08-03 `WAZUH-01`은 최초 적용 전 capacity gate에서 **STOP**했다. 13:32 KST의
`k3s-01` available은 9,946,275,840 bytes였고 8 GiB 정지선까지 1,356,341,248 bytes
(1.263 GiB)만 남았다. [Wazuh 공식 Kubernetes 최소 요구량](https://documentation.wazuh.com/current/deployment-options/deploying-with-kubernetes/kubernetes-conf.html)인
3 GiB를 가장 낮은 배포 예상치로 적용해도 post-available은 6,725,050,368 bytes
(6.263 GiB)로 정지선을 1,864,884,224 bytes(1.737 GiB) 밑돈다. swap은 0, guest root
여유는 84%였고 PVC는 75.125 GiB에서 Wazuh 16 GiB를 더한 91.125 GiB로 96 GiB 경고선
안이므로 중단 원인은 RAM 하나다. replica·heap·PVC를 공식 최소 아래로 줄이거나 disk를
늘리지 않았으며 GitOps 선언, Kubernetes API audit 설정, OPNsense agent, `ARGO-ROOT`와 라이브
Wazuh 자원은 모두 변경하지 않았다. 따라서 다섯 완료 증거는 실행하지 않고 `WAZUH-01`을
`BLOCKED`로 되돌린다. 재진입은 배포 직전 available이 최소 11 GiB(8 GiB 정지선 + Wazuh
3 GiB) 이상이고 swap 0, guest root 여유 20% 이상, 기존 PVC와 Wazuh 16 GiB의 합계가
96 GiB 미만인 때 같은 gate를 다시 한 번 통과하는 조건이다. `SOAR-01`은 계속 `BLOCKED`다.

2026-08-03 `OPN-METRICS-01`에서 추가 credential이 없는 최단 경로인 OPNsense
`os-node_exporter`를 관리 주소에만 bind하고 CPU·meminfo·netdev collector만 활성화했다.
Prometheus는 외부 static target ScrapeConfig와 exact egress 한 건으로 수집했고 target
`up=1`, CPU `node_cpu_seconds_total=133659.968503937`, memory
`node_memory_size_bytes=33280430080`, interface
`node_network_receive_bytes_total{device="igc1"}=7359887362`를 실제 조회했다. k3s-01에서
OPNsense TCP 9100으로 향하는 방화벽 PASS UUID `850333eb-ba9f-4a03-a846-81b6bd24e1cf`는
sequence 1020의 PF rule 1개로 적용됐고 packets 11, bytes 5436을 기록했다. immutable root
`addba0e1aa8e6625345641b0d19929ee99e4f0b8`과 child
`df003d3fe221b488da7c4e24872fb3bf121b91c5`가 `Synced/Healthy`였으며 스냅샷 승인 뒤 일반
drift 검사는 무변경이었다. rollback은 생성 UUID만 disable·apply·delete·apply하고 이 작업이
설치한 exporter를 disable·remove하는 경로로 고정했다. 직접 후속 ID가 없어 새로 `READY`로
여는 작업은 없으며 `WAZUH-01`과 `SOAR-01`은 기존 `BLOCKED`를 유지한다.

2026-08-03 `WAZUH-01`에서 `CAP-03` 뒤 다시 측정한 capacity gate가 **GO**여서 배포했다.
배포 전 `k3s-01` available은 17,130,917,888 bytes, swap 0, guest root 여유 84%,
PVC 요청 80,664,854,528 bytes(75.125 GiB)로 Wazuh 16 GiB를 더한 91.125 GiB가 96 GiB
경고선 안이었다. 공식 Wazuh Helm chart가 없어 공식 Kubernetes 원본 `wazuh-kubernetes`
v4.14.7(tag commit `41871e55c21f048ec652acd74666c365b04febb9`, tarball SHA-256
`928dc1e46d4f9db5a3c4f358f13b6eea03fccdb1f0a036567deabcc5528567c1`)에서 파생한 선언을
직접 작성하고 manager·indexer image를 index digest로 고정했다. indexer는 single-node,
heap 1 GiB, PVC 15 GiB이고 manager PVC 1 GiB로 Wazuh PVC 합계는 정확히 16 GiB다.
Dashboard는 배포하지 않고 indexer REST API로만 완료 증거를 만들었다.

고정 관측창은 `2026-08-03T10:00:19Z`부터 907초 한 번이고 그 안에서 다섯 증거를 모두
판정했다. 대표 Suricata event는 `HOME_NET` 밖 `10.10.60.2`에서 감시 대상 `vlan02`를 지나는
cleartext HTTP 한 건으로 만들었고 `emerging-scan.rules` sid `2029054`가 정확히 한 건 발생해
`rule.groups:suricata AND data.src_ip:"10.10.60.2" AND data.alert.signature_id:2029054*`로
1건 검색됐다. running 설정은 `D30=30d`(`wazuh-alerts-4.x-*`)와 `A90=90d`
(`wazuh-alerts-4.x-audit-*`)이고 두 ISM 정책이 실제 index에 `enabled`로 붙었다. 같은 창의
index 증가량은 `D30` 63,386 bytes, `A90` 231,392 bytes로 일 환산 5.758·21.021 MiB,
기간 환산 0.169·1.848 GiB이며 전체 2.016 GiB로 16 GiB 상한의 12.60%다. 오탐 gate는
`NIDS-01` 테스트 시그니처 0건, D30/A90 밖 record 0건이었고 실제 인터넷發 탐지 2건은
참양성으로 보고만 했다. 같은 창의 Loki 보안 event 복제본은 0건이고 Loki 수집 설정의 Wazuh
endpoint, Wazuh 설정의 Loki endpoint, Wazuh NetworkPolicy의 Loki egress가 모두 0이다.
active response는 running `ossec.conf`의 `<disabled>yes</disabled>`, `<command>` 정의 0건,
`ar.conf`의 차단·계정 계열 응답 0건으로 비활성이며 agent 쪽도 `disabled=yes`다.
배포 후 available은 14,584,446,976 bytes로 8 GiB 정지선 위 5.583 GiB, swap 0, root 여유 82%,
PVC 합계 97,844,723,712 bytes(91.125 GiB)였다. immutable root
`b5466b727615191af712dcb076532dc63c63fc0e`와 child
`c11ac14c346a8e80cdaca6fe1a62fa87e71aed34`가 `Synced/Healthy`였다.

승인받은 라이브 변경은 두 가지다. Kubernetes API audit은 `k3s_baseline`이 `audit.k8s.io/v1`
`Metadata` 정책과 apiserver 인자를 선언하고 k3s를 재시작해 켰다. `Metadata` 전량 수집은 raw
135.6 MiB/일로 `A90` 상한의 141%여서 control plane 내부 조정 트래픽을 제외하고 raw
8.33 MiB/일로 줄인 뒤 배포했다. OPNsense에는 공식 `os-wazuh-agent` 1.3_1만 설치해
Suricata `eve.json` 한 소스만 켜고 active response·remote command·rootcheck·syscollector·
syscheck·syslog 수집은 모두 껐다. 방화벽 rule·NAT·DNS·Suricata 룰셋·인터페이스는 바꾸지
않았고 복구 지점은 `/home/imcherry/.local/state-backups/wazuh-01-opnsense-pJUvbjIt`다.

merge 전 실패는 모두 상태와 로그가 가리킨 지점만 고쳤다. `policy-baseline` child가 `main`을
읽어 PolicyException이 라이브에 없던 문제, root CA의 `keyUsage` 누락, `drop: [ALL]`로 사라진
`CAP_DAC_OVERRIDE`·`CAP_CHOWN`, `container_var_lib_t`를 읽지 못하는 SELinux 경계,
`date_index_name`이 `_index`를 덮어써 무력화된 filebeat 라우팅 조건, 그리고 Wazuh rule의
`<field>`·`<match>`로 걸러지지 않던 테스트 시그니처를 차례로 특정해 고쳤다. 마지막 세
검증 실패는 대상이 아니라 검증기 결함이었다. XML 주석 안의 `<command>`, 정상 상태에서도
1을 반환하는 `wazuh-control status`, 설명 문구의 "Loki"를 각각 실제 선언·출력 유무·endpoint
기준으로 바꿨다.

라이브 상태가 전제와 달랐던 점 하나를 보고한다. `NIDS-01`이 등록한 사용자 정의 테스트 룰
3건(sid `4294967292`·`4294967293`·`4294967294`)이 fingerprint 없이 `any -> any`라 모든 패킷마다
경보를 만든다. 실측 2.06 alert/s(약 177,826건/일)의 99.87%가 이 3건이고 `eve.json`은
225 MB/일이다. 그대로 저장하면 `D30` 일일 256 MiB와 30일 7.5 GiB 상한을 넘으므로
[분류·보존 표준](audit-event-standard.md) 4절의 "허용 event class를 줄인다"에 따라 저장 직전
ingest pipeline에서 제외했다. OPNsense 룰셋은 `NIDS-01` 소유라 이 작업에서 바꾸지 않았고
소스에서 이 룰을 정리하는 일은 후속 작업으로 남는다. 따라서 `WAZUH-01`을 완료하고 선행이
모두 충족된 직접 후속 `SOAR-01`만 `READY`로 연다.

2026-08-03 `WAZUH-01` squash commit(`862db2970b73b4b7c00792ccce5658d7032b419c`)이 merge된 뒤
post-merge 결함이 드러났다. `WAZUH-01`은 OPNsense에 `os-wazuh-agent`와 WazuhAgent 설정을 실제
적용했고 라이브 WazuhAgent `persisted_at`은 18:13:26 KST다. 같은 작업은 19:19:02 KST에 main으로
merge됐지만 그 squash commit에는 `infra/opnsense/config.xml` 변경이 없다. 원인은
`gitops/tools/wazuh-01/apply-opnsense.sh`의 성공 경로가 agent 적용과 readback까지만 수행하고
`check-drift.sh --update`와 후속 일반 drift 검사를 호출하지 않기 때문이며,
`gitops/apps/wazuh/README.md`의 설치 절차와 완료 증거에도 snapshot 갱신 단계가 없었다. 그 결과
라이브에는 저장소 snapshot에 없는 `os-wazuh-agent`·WazuhAgent subtree가 남았다. 같은 날 IDS
`persisted_at`은 21:08:39 KST로 별도 갱신됐는데, 직전 sanitized diff에서는 IDS의 의미 설정
차이 없이 `persisted_at`만 달랐다. 이 drift 때문에 merge 전 라이브 검증을 요구하는 `OBS-02`의
gate가 시작되지 못하고 중단됐다. IDS 21:08 write의 실행 주체는 이 시점까지 확인되지 않았으며
`WAZUH-01-FIX-01`이 read-only config history/revision metadata로 다시 판정한다.

2026-08-03 `WAZUH-01-FIX-01`에서 `OPNSENSE-LIVE` 잠금 아래 read-only 조회로 원인을 재확인하고
snapshot을 보정했다. plugin `os-wazuh-agent`는 버전 `1.3_1` installed, 서비스 `running`이었고
`/api/wazuhagent/settings/get` 값은 `apply-opnsense.sh`의 선언(서버·포트·suricata_eve_log=1·
active response/rootcheck/syscollector/syscheck/remote_commands=0)과 exact match였다. IDS
subtree는 `persisted_at`을 제외한 전체 XML을 직접 대조해 의미 설정 차이 0건을 확인했다.
21:08 write의 실행 주체는 OPNsense API가 read-only config history/revision 조회 endpoint를
제공하지 않아 확정하지 못했다. `actor=미확인`, `semantic_diff=0`으로 증거 한계를 남긴다.
sanitized drift는 firmware plugins 목록의 `os-wazuh-agent` 추가, `WazuhAgent` subtree 신규
추가, IDS `persisted_at` 변경 세 hunk뿐이었고 다른 PF·NAT·DNS·인터페이스·Suricata 설정
diff는 0건이었다.

절차는 `apply-opnsense.sh`가 `check-drift.sh --update`를 직접 호출하지 않도록 유지하고,
새 `gitops/tools/wazuh-01/classify_opnsense_drift.py`와
`finalize-opnsense-snapshot.sh`로 exact-diff gate를 분리했다. gate는 승인된 세 hunk
패턴과 순서까지 완전히 일치하는 diff만 통과시키며, fixture 테스트로 foreign PF 변경과
`WazuhAgent` 필드 조작(`active_response.enabled`를 `general.enabled`와 같은 문자열로
위장하는 경우 포함)이 `--update` 전에 거부됨을 확인했다. `shellcheck`와
`python3 -m unittest`가 모두 통과했다. gate 통과 후 `check-drift.sh --update`로 snapshot을
갱신했고 곧바로 실행한 일반 `check-drift.sh`는 드리프트 없음이었다. 갱신된
`infra/opnsense/config.xml`에서 password는 `***MASKED***`이고 저장소 밖 authd password
원문과 대조해 일치하는 원문이 없음을 확인했다. `git diff --check`도 통과했다. 이 작업은
GET 요청과 로컬 Git 파일만 바꿨고 OPNsense에 POST/PUT/DELETE를 보내지 않아 live revision·
Wazuh service·PF·NAT·DNS·IDS 의미 설정은 작업 전후 불변이다. 따라서 `WAZUH-01-FIX-01`을
완료한다. `OBS-02`는 이미 `READY`이므로 상태를 다시 쓰지 않으며, 이 완료로 `OBS-02`의 merge
전 gate를 막던 drift가 해소되어 `OBS-02`는 새 전용 branch/worktree로 다시 시작할 수 있다.

2026-08-05 `OBS-03`을 신설해 `READY`로 연다. `OBS-02`는 Pomerium이 Grafana·Prometheus·
Alertmanager 진입을 게이트하는 것까지만 검증했다. Grafana 자체는 `GF_SECURITY_ADMIN_USER`
로컬 계정 하나뿐이라 `/platform-users` 팀원이 Pomerium을 통과해도 Grafana 안에서는 로그인할
계정 자체가 없어, harbor·jenkins·grafana 접근 시 "OIDC 로그인이 안 보인다"는 관찰이 실제로는
설계대로였음을 확인하는 과정에서 이 gap이 드러났다. 대상 검토 결과 대시보드 편집이 실제로
필요한 사람은 `imcherry5778`(고광근, PM/온프레미스 보안)과 `cerberos2022`(이진희, 옵저버빌리티
담당) 둘뿐이라, harbor·jenkins까지 한 번에 열지 않고 Grafana 하나만 먼저 범위로 잡는다. Harbor는
OIDC 설정이 Helm values가 아니라 System Settings API(DB 저장)라 별도 idempotent Job 설계가
필요하고, Jenkins는 SecurityRealm을 하나만 가질 수 있어 지금의 로컬 복구 `admin` 계정을 어떻게
보존할지 먼저 결정해야 해서 이번 범위에서 제외했다.

`imcherry5778-admin`(`/platform-privileged`)은 이번 대상에 넣지 않았다. 이 계정이 실제로
쓰이는 곳(Vault operator policy, AWS IAM 변경, AWX workflow 승인, Wazuh Dashboard 조사,
Shuffle 조직·사용자 관리, Headlamp `pods/exec`, Alertmanager silence 쓰기)은 모두 blast
radius가 큰 mutating·관리 작업이고, ADR-0004가 일상 계정과 특권 계정을 분리한 이유도 이런
작업에만 특권 계정을 쓰기 위해서다. Grafana 대시보드 편집은 daily 계정(`imcherry5778`)이 이미
커버하므로 특권 계정을 끌어들일 이유가 없다. Grafana 자체의 관리 기능(데이터소스 추가·org
설정)은 지금 전부 Helm values로 GitOps 선언돼 있어 UI 관리 계층이 필요 없고, 그 필요가 실제로
생기면 Alertmanager의 "조회는 `/platform-users`, 쓰기는 `/platform-privileged`" 패턴을 그대로
재사용해 별도로 판단한다.

Vault는 새 policy·role을 만들지 않는다. `gitops/tools/obs-01/provision.sh`가 이미 만든
`obs-grafana` policy가 `kv/data/obs/grafana` 전체를 read하므로, 같은 secret에
`oidc_client_secret` 키만 추가하면 기존 Vault Agent 경로가 그대로 소비한다. Keycloak client·
group 선언은 `pom-01`/`headlamp-02`와 같은 check-first 패턴(`gitops/tools/obs-03/`)을 따른다.
이 세션은 백로그 항목만 추가했고 Keycloak·Vault·Helm values 라이브 변경은 없다.

2026-08-05 실행 중 `cerberos2022`가 아직 초기 비밀번호 변경·TOTP 등록을 하지 않아 본인 실제
로그인 증거를 만들 수 없음을 확인했다. 다른 사람이 계정을 대신 활성화하거나 인증 정보를
공유하는 것은 IAM 경계를 훼손하므로, OBS-03 완료 기준을 선언과 실제 사용 증거로 분리한다.
`/grafana-editors`의 exact 회원은 계속 `imcherry5778`·`cerberos2022` 두 명이고 하나의
`role_attribute_path`가 두 회원 모두에게 동일하게 적용되는 것을 check-first로 검증한다. 실제
로그인 대조는 이 세션에서 가능한 `imcherry5778=Editor`와 `/platform-users` 중 한 명의
`Viewer`로 완료하며, `cerberos2022`의 최초 로그인은 본인 IAM 온보딩 뒤 수행할 운영 확인으로
이관하고 OBS-03 완료를 막지 않는다. 이후 `cerberos2022`가 Grafana org에 나타난 상태라면
`Editor`가 아닌 경우에는 검증 실패로 판정한다.

2026-08-05 `OBS-03`을 완료했다. immutable root
`244cf4a0e91256c1788114cbeb7a8b9c149a2c8c`·child
`534db0945901922aa8c54e582200ec803c64bdfa`에서 실제 OIDC 로그인을 수행해 Grafana API의
`imcherry5778=Editor`, `snsd-hybirdinfra=Viewer`와 `imcherry5778-admin` org membership 부재를
확인했다. `cerberos2022`는 아직 IAM 온보딩 전이라 실제 로그인하지 않았고, Keycloak exact
group membership과 두 회원이 공유하는 role mapping 선언까지만 완료 증거로 삼았다.

완료 기준을 반영한 immutable root `69979a52273296a4ccbeb8f9810df28fe1d4539c`·child
`f50b1003dd8ba1db3bb69627946efa8d2e99b8eb`에서는 `grafana` confidential client, groups mapper,
`/grafana-editors` exact 회원 두 명, client secret, Vault KV의
`admin_password`·`oidc_client_secret` 두 key, 기존 `obs-grafana` policy·role 불변, local
`admin=Admin`, 로그인 form 유지, datasource 세 개와 dashboard provider의 `editable:false`,
root·child `Synced/Healthy`를 확인했다. 두 child SHA 사이 런타임 선언은 exact diff 0건이다.
Grafana persistence가 꺼져 있어 검증 배포를 되돌릴 때 OIDC org user가 초기화되므로 이미 확보한
실제 로그인 경계를 반복하지 않았다. 마지막으로 root와 child를 시작 main SHA
`5bd18572c83d0b297fdde25464015685df0d44e9`의 literal `main`으로 복구해 둘 다
`Synced/Healthy`임을 확인했다.

## 10. 마지막 단계: Shuffle

| ID·상태 | 작업과 소유 범위 | 선행 | 잠금 | 영향 | 완료 증거 |
|---|---|---|---|---|---|
| `SOAR-DASH-01 DONE` | Shuffle 엔진·대시보드만 배포(자체 OpenSearch 백엔드 포함, 워크플로·앱 연동 없음) | `OBS-01`, `WAZUH-01`, `WAZUH-02`, `FALCO-01`, `CAP-04`, `CAP-05` | `K3S-HEAVY` | `SOAR-01` | 배포 직전 capacity gate 통과, Wazuh indexer와 분리한 자체 OpenSearch 단일 노드, 고정 version·image digest, 내부 전용 노출(Pomerium Route)과 관리자 로그인 확인, 워크플로·앱·webhook 연동 0건, 재부팅 후 유지, PVC·available 정지선 통과, Argo child `Synced/Healthy` |
| `SOAR-01 DONE` | 이미 배포된 Shuffle 위에 경보 수신→정보 보강→통지→승인 흐름을 연동(사람 승인형, read-only) | `IAM-ENROLL-01` | 없음 | 사고대응 | `imcherry5778`을 reader에서 제거한 뒤 operator로 이동해 Shuffle role 하나만 발급, 나머지 팀 reader의 조회 성공과 쓰기·실행 거부, 대표 Wazuh 경보의 수신·정보 보강·통지·승인 각 단계 실동작, 자동 대응(격리·차단·계정 변경 등) 0건, 최소권한 credential, rollback 뒤 dashboard 기존 상태 회귀 없음 |
| `SOAR-02 DEFERRED` | 되돌릴 수 있는 대응 한 가지 자동화 | `SOAR-01`, 검증된 incident runbook | 없음 | 접근 정책 | 반복 시험, 승인·감사·rollback; 방화벽·계정 무인 파괴 금지 |

2026-08-04 `CAP-05` 완료로 `SOAR-01`(원래 범위: Shuffle 배포 + 자체 OpenSearch + 경보 수신→
정보 보강→통지→승인 흐름)이 `READY`로 열리자마자, 그 범위를 배포와 기능으로 나눈다.
`SOAR-DASH-01`을 신설해 Shuffle 엔진·대시보드와 전용 OpenSearch 배포만 먼저 맡기고
워크플로 연동은 붙이지 않는다. 선행이 이미 모두 `DONE`이므로 `SOAR-DASH-01`은 곧바로
`READY`다. 기존 `SOAR-01`은 그 위에서 경보 흐름을 연동하는 후속 작업으로 범위를 좁히고
선행을 `SOAR-DASH-01` 하나로 바꿔 `BLOCKED`로 되돌린다. 배포 자체를 맡는
`SOAR-DASH-01`이 `K3S-HEAVY` 잠금(큰 워크로드 최초 적용)을 갖고, 이미 뜬 Shuffle 위에서
앱·커넥터를 구성하는 좁아진 `SOAR-01`에는 걸지 않는다. `CAP-04`·`CAP-05`가 검증한
"`SOAR-01` 진입선"(available 12 GiB)은 이 분리 이전 완료 기록이라 다시 쓰지 않으며, 그
게이트가 실제로 지키는 대상은 지금부터 `SOAR-DASH-01`의 배포 capacity gate다.

2026-08-04 `SOAR-DASH-01`에서 Shuffle v2.2.1(tag commit `a106f27312bbb81791a33dfee585a6b8d0ad3289`,
GitHub Security Advisories 0건)의 backend·frontend와 Wazuh indexer와 분리한 전용
OpenSearch 3.2.0을 모두 image digest로 고정해 배포했다. 공식 Helm chart·Kubernetes manifest가
없어 upstream `docker-compose.yml`을 검토해 선언을 직접 파생했다. 배포 직전 `k3s-01`
available은 16.617 GiB로 진입선(12 GiB) 위 4.937 GiB였다.

merge 전 `ARGO-ROOT` 라이브 검증에서 실패 두 종류를 원인 특정 뒤 같은 브랜치에서 고쳤다.
`shuffle-backend-files` PVC(`local-path`, `WaitForFirstConsumer`)가 backend Deployment보다
이른 sync-wave에 있어 PVC health-wait와 Pod 생성이 서로를 기다리는 데드락이었던 것을 같은
wave로 옮겨 없앴고, upstream frontend 이미지의 `nginx.conf.tmpl`이 80/443을 바인딩해 root가
필요했던 문제는 자체 template으로 TLS block을 없애고 평문 8080으로 옮겨 PolicyException 없이
해결했다(빈 emptyDir subPath가 대상 파일 경로를 디렉터리로 잘못 만드는 별도 함정은
initContainer로 빈 파일을 먼저 만들어 피했다). `gitops/apps/pomerium/ingress.yaml`의 Traefik
host·TLS 목록에 `shuffle.imcherry5778.xyz`를 추가하지 않아 Traefik이 SNI를 몰라 self-signed
cert로 응답하던 것도 이 목록에 등록해 Let's Encrypt DNS-01 인증서를 새로 발급받아 고쳤다
(Traefik Pod UID·재시작 0건, hot reload만 확인).

라이브 검증에서 `gitops/tools/soar-dash-01/verify-routes.py`가 같은 실행에서
`/platform-privileged`(`imcherry-admin`)의 Pomerium 통과와 `/platform-users`만 가진
`imcherry`의 403을 대조했고, Vault가 발급한 bootstrap 계정(`soar-dash-01-admin`)의 Shuffle
자체 `/api/v1/login`이 Pomerium→Traefik TLS→frontend→backend 전체 외부 경로로 성공했다.
`shuffle-opensearch-0`를 삭제해 StatefulSet이 재생성한 뒤에도 같은 로그인이 성공해 PVC 데이터
지속을 확인했다. `shuffle` namespace의 Kubernetes Secret은 0건이고, 워크플로 실행 엔진인
Orborus는 배포하지 않아 backend가 시도한 `shuffler.io`·`github.com/shuffle/python-apps` 외부
호출은 NetworkPolicy egress 부재로 모두 connection refused였다(워크플로·앱 연동 0건의 실증).

배포 후 실측은 `k3s-01` available 14.961 GiB(정지선 8 GiB 위 6.961 GiB), Proxmox available
24.421 GiB, swap 0, PVC 합계 111.125 GiB(사전 예측과 정확히 일치, 120 GiB 정지선까지
8.875 GiB)였다. Argo `shuffle` Application과 함께 기존 22개 Application 전체가
`Synced/Healthy`로 남았다. 상세 값은 [`capacity-plan.md`](capacity-plan.md)의
`SOAR-DASH-01` 절, 배포 선언과 알려진 함정은
[`gitops/apps/shuffle/README.md`](../gitops/apps/shuffle/README.md)가 소유한다.
`SOAR-DASH-01`을 `DONE`으로 닫고, 선행이 충족된 직접 후속 `SOAR-01`은 워크플로 연동을
시작할 수 있으므로 `BLOCKED`에서 `READY`로 연다.

2026-08-04 팀 identity와 Shuffle RBAC를 워크플로보다 먼저 닫도록 `SOAR-01`의 직접 선행을
`IAM-01`로 바꾸고 `READY`에서 `BLOCKED`로 되돌렸다. 같은 날 사용자 직접 등록을
`IAM-ENROLL-01`로 분리하면서 직접 선행도 그 작업으로 옮겼다. `SOAR-DASH-01`의 배포 상태와
완료 판정은 바꾸지 않는다. 운영자 role은 워크플로를 실제로 만들고 실행해야 하는
`SOAR-01`에서만 승격하며, 그 전까지 모든 팀 일상 계정은 동일한 reader 권한을 가진다.

Shuffle은 Jenkins·Argo CD·AWX의 배포 자동화를 대체하지 않는다. 보안 사건에 반응하는 흐름만 소유한다.

2026-08-13 `SOAR-01`을 완료했다. `snsd-hybirdinfra` reader는 Dashboard 조회만 가능하고
Save·Execute가 거부됨을 직접 확인했으며, `imcherry5778`은 `/soar-readers`에서 제거한 뒤
`/soar-operators` 하나만 가진 operator 상태에서 작업했다. Wazuh에 저장된 level 7 대표 alert를
기존 Vault-rendered 내부 webhook으로 전달해 오프라인 지표 보강이 성공했고, Dashboard 실행 카드가
만든 수동 Form을 사람에게 노출해 `imcherry5778`의 Continue 입력을 받았다. API 실행 기록은 해당
승인 노드 `SUCCESS`, `clicked=true`이며 입력 note 원문은 기록하지 않았다. 선언된 실행 노드는
오프라인 보강 하나와 `User Input` 하나뿐이므로 외부 알림 전송·격리·방화벽 변경·계정 변경·삭제는
0건이다. SOAR-01이 만든 hook·workflow·app과 Vault KV field를 rollback해 모두 absent, 사용자 role을
reader 하나로 복원한 뒤 같은 도구로 다시 apply해 최종 `operator`·app·workflow·hook present를
확인했다. immutable root `65daaf679631e2659dc5414d5c12a92e27d06ba8`와 child `shuffle`·`wazuh`는
동일 SHA에서 `Synced/Healthy`였고, 검증 종료 시 literal `main`으로 복구한다. `SOAR-02`는 검증된
incident runbook이라는 추가 선행이 없으므로 `DEFERRED`를 유지한다.

2026-08-06 그라파나(Grafana) 관측성 강화를 위해 `OBS-04`~`OBS-07` 4개 대시보드 백로그 작업을 신설한다. 기존 최소 대시보드(`obs-02-overview`)를 대체하여 인프라 자원 안전(Capacity Gate), 핵심 서비스 트래픽, 백업 파이프라인, Loki 운영 로그 탐색을 계층별로 독립 관리한다. 선행 작업인 `OBS-03`이 `DONE` 상태이므로 `OBS-04`를 `READY`로 연다. `OBS-05`~`OBS-07`은 의존성에 따라 순차적으로 `BLOCKED` 상태로 관리한다.

2026-08-06 `OBS-04`에서 Platform Capacity Sentinel 대시보드를 구축했다. `obs-04-capacity-sentinel` ConfigMap과 Grafana dashboard provider 마운트를 선언하고, RAM(8 GiB / 12 GiB), PVC(96 GiB / 120 GiB), thin-pool(60% / 70%) 정지/경보 기준 시각화 패널 3개를 구성했다. Argo child `obs`와 `platform-root` 모두 `Synced/Healthy`를 확인하고 백로그 `OBS-04`를 `DONE`으로 갱신하며, 직접 후속인 `OBS-05`를 `READY`로 연다.

2026-08-06 `OBS-04-FIX-01`에서 Grafana Live WebSocket Origin 차단 에러(`origin not allowed`) 및 패널 PromQL 라벨 미매칭 결함을 보정했다. `GF_LIVE_ALLOWED_ORIGINS` 및 `GF_SECURITY_ALLOW_EMBEDDING` 환경 변수를 추가하고, RAM Available(`node_memory_MemAvailable_bytes`), PVC Requested Total, thin-pool / filesystem 사용률(`mountpoint=~"/|/rootfs"`) PromQL 라벨 조건을 실제 수집 환경에 맞게 보정했다.

2026-08-06 `OBS-04-FIX-02`에서 Grafana Live WebSocket `GF_LIVE_ALLOWED_ORIGINS` 환경 변수를 와일드카드(`"*"`)로 보정하여 프록시 헤더 변형 환경에서 `origin not allowed` 에러가 해제되도록 라이브 sync를 완료했다.

2026-08-06 \OBS-04-FIX-04\에서 Grafana Live WebSocket 연결을 위해 Pomerium \grafana\ 라우트에 \llow_websockets: true\ 설정을 추가하여 403 에러를 해결했다.
2026-08-06 \OBS-04-FIX-05\에서 Grafana Live WebSocket 및 API 요청의 Origin 불일치를 방지하기 위해 Pomerium \grafana\ 라우트에 \preserve_host_header: true\ 설정을 추가했다.

2026-08-06 `OBS-05`에서 Core Services & Traffic Infrastructure 대시보드를 구축했다. `obs-05-core-services` ConfigMap 선언 및 kustomization 추가, Grafana dashboard provider 마운트를 선언하고 Traefik(QPS/HTTP Status/Latency), Pomerium(SSO/Route), PostgreSQL(쿼리/커넥션/WAL), Vault(Unseal/Cert-TTL) 핵심 지표 시각화 패널 10개를 구성했다. ConfigMap 선언 및 kustomization 추가, Argo 검증 완료 후 백로그 `OBS-05`를 `DONE`으로 갱신하며, 직접 후속인 `OBS-06`을 `READY`로 연다.

2026-08-06 `OBS-05-FIX-01`에서 `gitops/apps/obs/install.yaml` 내 `obs-grafana` Deployment의 중복 선언된 `dashboards-platform-core-services` volumeMount 및 volume 항목을 제거하여 Argo CD `ComparisonError` (duplicate entries for key) 항목을 보정했다.

2026-08-06 `OBS-05-FIX-02`에서 `gitops/apps/obs/install.yaml` 내 `obs-grafana` ConfigMap의 `dashboardproviders.yaml` 항목에 중복 선언된 `platform-core-services` 프로바이더 항목을 제거하여 Grafana 기동 시 `CrashLoopBackOff` 원인을 보정했다.

2026-08-06 `OBS-05-FIX-03`에서 `gitops/apps/obs/dashboard-core-services.yaml` 내 PromQL 패널 쿼리의 scalar binary expression `or 0` / `or 1`을 `or vector(0)` / `or vector(1)`로 교정하여 Prometheus 쿼리 파싱 에러(`set operator "or" not allowed in binary scalar expression`)를 해결했다.

2026-08-06 `OBS-06`에서 Data Protection & Backup Pipelines 대시보드를 구축했다. `obs-06-backup-pipelines` ConfigMap 선언 및 kustomization 추가, Grafana dashboard provider 마운트를 선언하고 Velero 백업 성공률, SeaweedFS S3 용량/일일 증가율, AWS S3 오프사이트 헬스 시각화 패널 4개를 구성했다. Argo 검증 완료 후 백로그 `OBS-06`을 `DONE`으로 갱신하며, 직접 후속인 `OBS-07`을 `READY`로 연다.

2026-08-06 `OBS-07`에서 Loki Operational Log Explorer 대시보드를 구축했다. `obs-07-loki-log-explorer` ConfigMap 선언 및 kustomization 추가, Grafana dashboard provider 마운트를 선언하고 Namespace/App별 5분 단위 `level=error|warn` 로그 발생률 차트 및 dynamic filter Log Stream 패널 2개를 구성했다. Argo 검증 완료 후 백로그 `OBS-07`을 `DONE`으로 갱신한다.

2026-08-07 `OBS-02` 대시보드의 패널 구성을 장애 발생 시 확인 순서에 맞춰 7개 패널로 전면 재구성하는 `OBS-08` 작업을 신설하고 `READY`로 연다.




2026-08-07 OBS-02 대시보드의 패널 구성을 7개로 전면 재구성하는 OBS-08 작업을 완료했다.

- 2026-08-07: OBS-08-FIX-01에서 Platform Observability Overview 대시보드의 No data 매핑 혼선, Node Ready 백분율 표기, 패널 레이아웃 불균형 및 일부 PromQL 쿼리 미매칭 결함을 일괄 보정했다.
2026-08-07 OBS-02 (Platform Observability Overview) 대시보드 9개 항목 개편(Core/Node/Alerts/Argo/Pod/CPU/RAM/PVC 최적화 및 레이아웃 균등화) 적용 및 JSON 반영 완료. (k3s 클러스터 오프라인으로 라이브 검증 생략)

2026-08-07 OBS-08-FIX-02 (Platform Observability Overview) 대시보드의 남은 결함(PromQL 노출 차단, 스파크라인 제거 및 Ready/Total 분리) 수정 및 Max PVC Usage 지표 수집(kubelet 활성화) 완료. (클러스터 오프라인으로 Argo CD 검증 후 병합 완료 취급)

2026-08-07 OBS-08-FIX-03 Platform Observability Overview 대시보드의 Max PVC Usage 수집 픽스(kubeletService 활성화) 및 Node/Core Components 패널의 Ready/Total 나란히 표기 결함 보정 완료. (클러스터 오프라인 가정 하에 Argo CD 생략 후 즉시 병합)

2026-08-07 `OBS-04-FIX-06` Platform Capacity Sentinel 대시보드의 4개 그룹 2열 그리드 구조 전면 재배치 및 패널 세분화(RAM by Node, PVC Usage by Volume, 정지선 예상 도달일 Trend, Thin-pool 게이지 및 안내 텍스트) 완료.

2026-08-07 `OBS-04-FIX-07` Platform Capacity Sentinel 대시보드의 RAM 지표를 사용량 기준(`MemTotal - MemAvailable`)으로 통일하여 정지선 초과 여부 해석 오류를 교정하고, 증가율/예상 도달일 패널 전면 제거 후 3개 그룹 구조 재배치 및 No Data 회색(`dark-gray`) 매핑을 완료함.

2026-08-07 `OBS-04-FIX-08` Platform Capacity Sentinel 대시보드의 Bar Chart 패널 히스토그램 형태 렌더링 결함을 `reduce`/`sortBy` Transformation 적용으로 해결하여 카테고리별 가로 막대 그래프 및 PVC 사용량순 정렬을 구현하고, RAM 상단/하단 Threshold 색상 판단 기준을 일치시켰으며, Thin-pool 패널을 콤팩트 Stat으로 전환함.

2026-08-07 `OBS-04-FIX-09` Platform Capacity Sentinel 대시보드의 Thin-pool 안내 Text 패널 높이를 4칸으로 확장하고 `{노드/볼륨그룹명}`을 실제 명칭(`k3s-01 / vg-data`)으로 치환하였으며, 상단 요약 Stat 패널에 Progress 배경 영역 시각화를 추가하고 Bar Chart 내부 여백을 조율함.




2026-08-07 `OBS-04-FIX-10` Platform Capacity Sentinel 대시보드 시각화 정밀 보정: RAM 막대 Threshold 색상 연동, 단일 노드 렌더링 방어 및 정렬, PVC 차트 x축 자동 스케일 조정(max 제거), Thin-pool 텍스트 패널 높이 확장 및 실제 대상 치환, Stat 중복 문구 제거 완료.

2026-08-10 `OBS-06-FIX-01`에서 Data Protection & Backup Pipelines 대시보드의 패널 쿼리 오매핑 결함을 보정했다. SeaweedFS 메트릭 미수집으로 인해 k3s 노드 OS 디스크 용량(`node_filesystem_size_bytes`)이 S3 용량으로 잘못 표시되던 패널 2를 실제 S3 백업 용량인 `velero_backup_tarball_size_bytes`로 교정하고, 항상 더미 0 Bps 및 1로 고정되던 패널 3·4를 24시간 백업 데이터 증분량(`increase`) 및 Backup Storage Location(BSL) `Available` 상태/성공 타임스탬프 기반 실측 지표로 교정했다. YAML/Kustomize 유효성을 검증하고 최신 main에 병합했다.

2026-08-13 `OBS-14`는 `postgres-01`·`object-01`·`warpgate-01`·`netbird-01` 4개 VM에 SSH로
직접 접속해 read-only로 native metric 노출 여부를 조사했다(라이브 변경 0건). PostgreSQL은
`postgres_exporter` 등 어떤 Prometheus 경로도 없었고, SeaweedFS는 4개 systemd unit
(`infra/ansible/roles/seaweedfs_s3`) 모두 `-metricsPort=0`으로 명시 비활성화돼 있었다.
Warpgate v0.26.1은 CLI 전체에 metrics 관련 옵션이 없어 현재 버전은 native Prometheus
노출 자체를 지원하지 않는다. NetBird management는 `--metrics-port`(기본 9090)가 이미
컨테이너 내부 `0.0.0.0:9090`에서 기동 중임을 `/proc/net/tcp`로 확인했지만
`docker-compose.yml.j2`가 host에 publish하지 않아 Prometheus에서는 도달 불가했다. 4개 제품
모두 `up=1`을 낼 수 있는 대상이 없어 `gitops/apps/obs/`에 신규 `ScrapeConfig`·
`NetworkPolicy`를 추가하지 않았다. PostgreSQL(신규 `postgres_exporter` 설치)과 SeaweedFS·
NetBird(바이너리 내장 flag 활성화)는 공통적으로 `OPNSENSE-LIVE` 신규 방화벽 규칙이
필요해 `OBS-14`의 `ARGO-ROOT` 단독 잠금 범위 밖이므로 각각 `OBS-15`·`OBS-16`으로 열었다.
Warpgate는 실행 가능한 후속이 없어 새 ID를 만들지 않았다. 상세 근거는
[`docs/evidence/obs-14/README.md`](evidence/obs-14/README.md)에 기록했다.
