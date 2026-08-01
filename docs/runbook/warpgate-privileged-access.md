# Warpgate 특권 세션 기준선 (`WG-01`)

- 검증일: 2026-07-31 (`WG-01` 라이브 검증 통과)
- 대상 VM: `warpgate-01` (VMID 130, Rocky Linux 9.8) — 주소는 [`ip-plan.md`](../ip-plan.md)가 소유한다
- 소유 범위: `warpgate-01` 안의 Warpgate 설치·서비스 계정·설정·systemd unit 과 제품 DB 의 role/target/user/known-host 선언
- 선언 위치: [`infra/ansible/roles/warpgate_baseline`](../../infra/ansible/roles/warpgate_baseline), [`infra/ansible/playbooks/warpgate-baseline.yml`](../../infra/ansible/playbooks/warpgate-baseline.yml)
- 잠금: 없음. OPNsense·Proxmox·OpenTofu state 를 변경하지 않는다

이 작업은 특권 세션 중계 기준선만 만든다. Keycloak SSO 연동과 역할·세션 정책은
`WG-02`, VLAN 경계 최소화는 `NET-04`, 공개 진입 경로는 `EDGE-01` 범위다.

## 1. 전제조건과 접근 권한

| 항목 | 요구 |
|---|---|
| 선행 | `VM-01` `DONE` |
| 관리 경로 | Proxmox strict host key SSH, `warpgate-01` strict host key SSH |
| 게스트 상태 | SELinux Enforcing, swap 0, failed unit 0, chronyd 동기화, QGA active |
| 자원 | [`capacity-plan.md`](../capacity-plan.md)의 `warpgate-01` 배정(2 vCPU · 2 GiB · 40 GiB) |

적용 전에 main 과 live 의 VMID·hostname·IP·VLAN·OS·CPU·메모리·디스크가 일치하는지,
기존 Warpgate 흔적·계정·listener 가 없는지 확인한다. 전제가 다르면 적용하지 않고 보고한다.

## 2. 게스트 SSH 신뢰 부트스트랩

`accept-new` 나 `ssh-keyscan` 단독으로 신뢰를 확정하지 않는다. 절차는
[VM-01 runbook](proxmox-opentofu-vm-creation.md)의 "게스트 SSH 신뢰 부트스트랩"과 같다.

Rocky GenericCloud 의 qemu-guest-agent 는 `guest-exec` 와 파일 명령을 차단하므로
`guest-info` 로 사용 가능한 명령을 먼저 확인한다. `guest-set-user-password` 가 열려 있으면
QGA 로 임시 password 를 설정하고 `/var/run/qemu-server/130.serial0` 콘솔에서
`/etc/ssh/ssh_host_*_key.pub` 를 읽은 뒤, 즉시 `passwd -d` + `passwd -l` 로 되돌리고
`passwd -S` 가 `LK` 인지 확인한다.

읽은 host key 는 이름과 IP 양쪽에 대응하도록 저장소 밖 mode `0600` `known_hosts` 에 넣는다.
강제 여부는 **위조 key 로 실패하는지**까지 확인해야 증명된다. 이때 SSH 연결 다중화를
끄지 않으면 기존 control socket 을 재사용해 검증을 건너뛴다.

콘솔 자동화에서 `Last login: ` 문자열은 `login: ` 을 포함한다. 로그인 성공 판정을
`login: ` 부재로 하면 성공을 실패로 오인한다. 셸 프롬프트로 판정한다.

## 3. 버전 선정과 공급망

| 항목 | 값 |
|---|---|
| 제품 | [Warpgate](https://github.com/warp-tech/warpgate) (Apache-2.0) |
| 채택 버전 | `v0.26.1` — 작업 시점의 최신 **안정** 릴리스 |
| 채택하지 않은 것 | `v0.27.0-beta.*` (prerelease) |
| 아티팩트 | `warpgate-v0.26.1-x86_64-linux` (단일 정적 바이너리) |
| 무결성 | GitHub Release asset digest 의 SHA-256 을 `get_url` 의 `checksum` 으로 강제 |
| SBOM | 같은 릴리스의 CycloneDX `*.cdx.xml` 을 checksum 검증 후 게스트에 보관 |

`floating latest`, 미검증 설치 스크립트, `curl | sh` 는 쓰지 않는다. 정확한 버전·checksum 값은
[`roles/warpgate_baseline/defaults/main.yml`](../../infra/ansible/roles/warpgate_baseline/defaults/main.yml)이 소유한다.

### v0.23.4 를 쓰지 않은 이유

작업 지시의 참고값 `v0.23.4`(2026-05-11)는 그 뒤 공개된 보안 자문의 영향 범위 안에 있다.

| 자문 | 심각도 | 영향 범위 | 요지 |
|---|---|---|---|
| `GHSA-2q37-6vxr-26jr` / `CVE-2026-63330` | high | `< 0.25.6` | live recording stream WebSocket 에 admin 인가 누락. 인증된 아무 사용자나 터미널 세션 도청 가능 |
| `GHSA-862h-v6cc-9757` / `CVE-2026-63329` | medium | `< 0.25.6` | `x-warpgate-username` 헤더 미제거로 WebSocket backend 대상에 신원 위조 가능 |
| `GHSA-3c3w-75j2-7h74` / `CVE-2026-58491` | critical | `v0.25.4` | SSO return endpoint 의 `next` 파라미터를 통한 reflected XSS |

특히 `CVE-2026-63330` 은 이 작업의 완료 증거인 **세션 기록**을 직접 훼손한다.
`v0.26.1` 은 위 세 자문의 영향 범위 밖이다.

## 4. 선언한 구성

| 항목 | 값 | 이유 |
|---|---|---|
| 실행 계정 | 전용 system 계정 `warpgate`, `/sbin/nologin`, password lock | 비-root 실행 |
| 바이너리 | `/usr/local/bin/warpgate-<버전>` + `warpgate` symlink | 이 경로의 기본 SELinux file context 가 `bin_t` 라 `semanage` 규칙 없이 올바른 label 을 얻는다 |
| 설정 | `/etc/warpgate.yaml`, `0600 warpgate:warpgate` | Ansible template 이 소유. 수동 편집은 다음 실행에서 덮어써진다 |
| 데이터 | `/var/lib/warpgate` `0700 warpgate:warpgate` (`db`, `ssh-keys`, `recordings`, TLS) | `/var/lib` 아래라 `var_lib_t` 상속 |
| 프로토콜 | SSH·HTTP 만 활성. MySQL·PostgreSQL·Kubernetes 는 `enable: false` | 필요하지 않은 진입면을 열지 않는다 |
| 세션 기록 | `recordings.enable: true` | `WG-01` 완료 증거 |
| 보존 | `log.retention` 7days, `log.audit_retention` 90days | 세션 기록은 용량이 아니라 보존기간으로 통제한다 |
| 대상 host key | `host_key_verification: prompt` + 검증한 key 를 선언 | `auto_accept` 는 TOFU 이므로 기본값으로 쓰지 않는다 |

`warpgate unattended-setup` 이 설정 파일, SQLite DB, SSH host/client key, 자체서명 TLS 와
로컬 `admin` 사용자를 한 번에 만든다. 설정 파일 존재로 멱등성을 보장하고 그 뒤의 설정은
role 의 template 이 소유한다. template 은 `warpgate ... check` 로 `validate` 한 뒤에만 쓴다.

### systemd hardening

`ProtectSystem=strict`, `ReadWritePaths=/var/lib/warpgate`, `ProtectHome`, `PrivateTmp`,
`PrivateDevices`, `NoNewPrivileges`, 빈 `CapabilityBoundingSet`/`AmbientCapabilities`,
`ProtectKernelTunables/Modules/Logs`, `ProtectControlGroups/Clock/Hostname`,
`ProtectProc=invisible`, `ProcSubset=pid`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX`,
`RestrictNamespaces/Realtime/SUIDSGID`, `LockPersonality`, `RemoveIPC`,
`SystemCallArchitectures=native`, `SystemCallFilter=@system-service` + `~@privileged @resources @obsolete`,
`UMask=0077`.

SSH·HTTP 를 1024 미만 포트에 두지 않으므로 `CAP_NET_BIND_SERVICE` 가 필요 없다.
이 조합에서 제품이 정상 기동·재기동함을 라이브에서 확인했다.

### role / target / user 선언

Warpgate 는 role·target·user 를 설정 파일이 아니라 제품 DB 에 둔다. role 의
`provision.yml` 이 loopback 관리 API 로 선언을 반영한다. 모든 호출은 `127.0.0.1` 로만 나가고
공개 경로나 방화벽을 만들지 않는다.

관리 API 의 union discriminator 는 serde 의 rename 이 아니라 **Rust variant 이름**을 쓴다.
`{"kind": "Ssh", ..., "auth": {"kind": "PublicKey"}}` 이며 `ssh`/`publickey` 는 400 이다.
`port` 는 정수여야 하므로 body 를 하나의 Jinja 식으로 만들어 native 형을 유지한다.

setup 이 만든 TLS 인증서는 `warpgate.local`/`localhost` 자체서명이다. loopback 관리
API는 service alias와 SAN이 달라 인증서 검증을 끈다. 브라우저 SSO callback에 쓰는
`warpgate.imcherry5778.xyz` 단일-host DNS-01 인증서와 갱신은 `WG-02`가 소유하며
[`warpgate-keycloak-sso.md`](warpgate-keycloak-sso.md)를 따른다. public A/AAAA·NAT와
공개 진입은 계속 `EDGE-01` 범위다.

## 5. 로컬 복구(break-glass) 계정

[ADR-0004](../adr/0004-zero-trust-identity-and-management-access.md)대로 IdP 장애용
로컬 복구 계정을 유지한다. 제품 내장 `admin` 사용자와 `admin` role 이 그 경로다.

- 비밀번호는 **저장소 밖에서 생성·보관**한다. 저장소의 `warpgate_admin_password` 기본값은 빈 문자열이며,
  role 은 12자 미만이면 적용을 거부한다.
- 실행할 때 저장소 밖 mode `0600` vars 파일이나 `--extra-vars` 로만 주입한다.
- 자격증명 회전은 이 role 이 소유하지 않는다. password credential 은 없을 때만 만든다.
- 사용자를 잊었을 때는 게스트에서 `warpgate --config /etc/warpgate.yaml recover-access` 를 쓴다.

## 6. 실행 순서

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 known_hosts> -o GlobalKnownHostsFile=/dev/null -o PasswordAuthentication=no -o ControlMaster=no -o ControlPath=none"

ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 secrets.yml>" playbooks/warpgate-baseline.yml --syntax-check
ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 secrets.yml>" playbooks/warpgate-baseline.yml --check --diff
# 명시적 승인 뒤에만 실제 적용
ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 secrets.yml>" playbooks/warpgate-baseline.yml
# 2차 적용은 changed=0, failed=0 이어야 한다
```

### 중단 조건

- OS·아키텍처, SELinux Enforcing, 관리자 비밀번호 주입 assert 중 하나라도 실패
- `warpgate ... check` 의 config validate 실패
- 적용 후 failed unit 발생, SELinux AVC 발생, listener 미기동

### 최초 적용 전 check mode 의 한계

부트스트랩 role 이라 **아직 없는 산출물**을 check mode 가 조회할 수 없다. 첫 적용 전에는
`unattended-setup` 이 skip 되고, 그 뒤 systemd unit 조회에서 멈춘다. 그때까지의 diff 는
바뀔 내용 전부를 보여주므로 승인 근거로 쓰되, **적용 후와 재부팅 후 check mode 가
`changed=0` 으로 통과하는 것**을 최종 판정으로 삼는다.

## 7. 라이브 검증

### 검증 자원

이 세션 전용으로 만들고 끝나면 제거한다.

| 자원 | 내용 |
|---|---|
| OS 계정 | `wg-selftest-target` — 비특권, sudo 없음, password lock, authorized_keys 에 Warpgate client key 만 |
| Warpgate role | `wg-selftest-role` |
| Warpgate target | `wg-selftest-loopback` → SSH `127.0.0.1:22` as `wg-selftest-target`, 허용 role 은 `wg-selftest-role` 하나 |
| Warpgate user | `wg-verify` (role 보유), `wg-denied` (role 없음) |
| known-host | 콘솔에서 확인한 `warpgate-01` sshd ed25519 host key |

Warpgate 자체 SSH host key 는 개인키에서 공개키를 도출해 listener 가 제시하는 값과
대조한 뒤 client `known_hosts` 에 넣는다. `ssh-keyscan` 단독으로 확정하지 않는다.

### 판정 항목

1. **세션 중계**: `wg-verify:wg-selftest-loopback@<warpgate>` 로 접속해 고유 marker 명령 실행 → marker 출력과 `exit 0`
2. **대상별 역할 제한**: 같은 대상에 `wg-denied` 접속 → `Permission denied`, 로그에 `Target ... not authorized for user ...`
3. **자격증명 실패**: `wg-verify` + 잘못된 비밀번호 → 거부
4. **감사 구분**: `UserAuthenticated1` / `UserAuthenticationFailed1 ... reason=invalid credential` /
   `TargetSessionStarted1` / `TargetSessionEnded1` 가 각각 남는다
5. **세션 기록**: `recordings/<session>/<recording>` 파일 생성, `0600 warpgate:warpgate`, `var_lib_t`
6. **제품에서의 조회**: 관리 API `sessions` 목록과 `sessions/<id>/recordings` 에 `Terminal` 항목
7. **로컬 복구 로그인**: 정상 자격증명 `201`, 잘못된 자격증명 `401`

세션 원문은 보고·로그에 남기지 않는다. marker 문자열과 상태 코드만 판정에 쓴다.

### 검증 범위의 한계

**이 검증은 `warpgate-01` 자기 자신의 loopback 대상에 한정된다.** 실제 운영 대상에 대한
cross-VLAN 접근 증거가 아니다. `ACCESS`(VLAN 30)에서 관리·플랫폼·데이터 대상으로 나가는
경로는 `NET-03` 의 임시 bootstrap 경계 아래에서 열려 있지 않으며, 실제 통신표로 최소화하는
작업은 `NET-04`(`OPNSENSE-LIVE` 잠금) 범위다. 이 작업은 OPNsense 를 변경하지 않았다.

## 8. 재부팅

재부팅 직전에 VMID 130, hostname, IP, 영향 서비스와 복구 경로(Proxmox 직렬 콘솔·QGA)를
다시 확인하고 **정확히 `warpgate-01` 만** 재부팅한다.

재부팅 후 판정: boot ID 변경, SSH 복귀, failed unit 0, SELinux Enforcing, AVC 없음,
`warpgate` enabled/active 와 비-root 실행, listener 복귀, 세션 기록 파일 SHA-256 불변,
로컬 복구 로그인·역할 제한 재통과, 기존 감사·세션 기록 유지, check mode `changed=0`.

SSH 가 돌아왔다는 것만으로 재부팅을 확인하지 않는다. **boot ID 가 바뀔 때까지 기다린다.**
지연 재부팅을 걸고 바로 접속하면 재부팅 전 시스템을 관측하게 된다.

## 9. 백업과 복원

| 대상 | 방식 |
|---|---|
| 제품 DB | SQLite 온라인 backup API (`sqlite3.Connection.backup`). 실행 중 파일을 그대로 복사하지 않는다 |
| 설정 | `/etc/warpgate.yaml` |
| 키·기록 | `recordings`, `ssh-keys`, TLS 인증서·키 |

백업은 저장소 밖 mode `0700` 임시 위치에 만들고 `integrity_check` 로 확인한다.

복원 검증은 **운영 데이터를 덮어쓰지 않는다.** 별도 data directory 와 별도 port 를 쓰는
격리 인스턴스를 띄워 로컬 관리자 로그인과 기록 metadata 복원을 확인한 뒤 인스턴스와
임시 백업을 제거한다. 복원 설정은 `warpgate` 사용자가 읽을 수 있는 위치에 둔다.
`/root` 아래에 두면 비-root 인스턴스가 설정을 열지 못한다.

`MINIO-01` 이 아직 없으므로 **이 절차는 원격 백업이 아니다.** 오프사이트 착지점과
보존 정책은 [ADR-0005](../adr/0005-backup-and-offsite-recovery.md)대로 `BKP-*` 범위이며,
`NetBird·Warpgate` 제품 DB·구성 백업의 정기 실행은 아직 구현되지 않았다.

## 10. 실패 시 원상복구

변경 전 패키지 목록, 활성 unit, 설정 파일 유무, DB 위치, listener 를 먼저 기록한다.
rollback 은 이 작업이 만든 리소스만 정확히 대상으로 한다.

```bash
systemctl disable --now warpgate.service
rm -f /etc/systemd/system/warpgate.service && systemctl daemon-reload
rm -f /etc/warpgate.yaml
rm -rf /var/lib/warpgate
rm -f /usr/local/bin/warpgate /usr/local/bin/warpgate-<버전> /usr/local/share/warpgate-<버전>-*.cdx.xml
userdel warpgate && groupdel warpgate
```

wildcard 삭제, VM 재생성, 광범위한 `rm`/`chcon`, SELinux 완화, `chmod 777`,
무제한 privileged 실행은 하지 않는다. Proxmox VM 정의·OpenTofu state·디스크·네트워크와
OPNsense 정책은 이 작업의 rollback 대상이 아니다.

## 11. 시크릿과 보존하면 안 되는 출력

- 로컬 복구 관리자 비밀번호, 검증용 사용자 비밀번호, 세션 원문, 쿠키, SSH 개인키,
  백업 원문을 Git·채팅·일반 로그에 남기지 않는다.
- 저장소 밖 `known_hosts`, inventory, vars 파일은 mode `0600`, 디렉터리는 `0700` 으로 둔다.
- 비밀번호를 다루는 Ansible task 는 `no_log: true` 를 쓴다.
- Warpgate 의 SSH host/client 개인키와 TLS 개인키는 게스트 밖으로 복사하지 않는다.
