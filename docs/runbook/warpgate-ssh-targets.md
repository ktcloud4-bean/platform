# Warpgate 실제 운영 SSH 대상 (`WG-03`)

## 범위

`WG-03`은 이미 `WG-02`가 만든 Keycloak SSO와 `NET-04`가 만든 ACCESS source의 TCP 22
경계를 사용해 다음 네 운영 VM만 Warpgate SSH target으로 등록한다.

| Warpgate target | 원격 계정 | 허용 Warpgate role | 목적 |
|---|---|---|---|
| `k3s-01` | `rocky` | `platform-privileged` | k3s node break/fix 운영 |
| `postgres-01` | `rocky` | `platform-privileged` | PostgreSQL host 운영 |
| `object-01` | `rocky` | `platform-privileged` | 로컬 object storage host 운영 |
| `netbird-01` | `rocky` | `platform-privileged` | NetBird control-plane host 운영 |

주소·VLAN은 [IP 계획](../ip-plan.md)이, TCP 22 alias와 PF rule은
[NET-04 runbook](opnsense-vlan-firewall-hardening.md)이 소유한다. 이 작업은 OPNsense,
Proxmox, OpenTofu state, Keycloak membership과 public DNS를 변경하지 않는다. OPNsense와
Proxmox 자체의 관리 SSH는 기존 독립 복구 경계에 남기며 Warpgate target에 넣지 않는다.

일상 `/platform-users`는 target을 하나도 받지 않는다. Keycloak의
`/platform-privileged`가 Warpgate의 동명 role로 동기화되고, 네 target은 그 role 하나만
허용한다. 따라서 사용자는 일상 계정이 아닌 분리된 특권 계정으로 SSO해야 한다. Keycloak
장애 때의 Warpgate 로컬 `admin`은 기존 break-glass 경로로 유지한다.

## 신뢰와 원격 인증

Warpgate가 생성한 **현재 ed25519 client public key**만 각 기존
`/home/rocky/.ssh/authorized_keys`에 한 줄로 넣는다. 그 줄은 Warpgate inventory의 source
IP로 `from=`을 제한하고 port/agent/X11 forwarding을 금지한다. 사용자·sudo·`sshd_config`와
기존 key 행은 바꾸지 않는다.

대상 host key는 Warpgate가 처음 만났을 때 물어보게 두지 않는다. 저장소 밖 mode `0600`
trusted `known_hosts`에서 인증 경로로 확인된 ed25519 key를 읽어 product DB에 미리
등록한다. `object-01`은 현 canonical FQDN을 직접 신뢰하지 않고, 기존 신뢰 IP key와 live
ed25519 fingerprint 일치를 먼저 확인한 뒤 같은 key를 FQDN에 등록한다. `ssh-keyscan`,
`accept-new`, Warpgate `auto_accept`는 사용하지 않는다.

Warpgate `v0.26.1`의 `GET /ssh/own-keys`는 이름과 달리 **대상 접속용 client key**를
반환한다. listener host key pinning의 신뢰 원천으로 쓰면 안 된다. listener `:2222` key는
strict 관리 SSH로 인증된 `warpgate-01`에서 systemd main PID와 socket ownership을 대조한
뒤 loopback으로 읽고, 독립 외부 listener scan과 일치할 때만 전용 known_hosts에 고정한다.

## 실행

실제 inventory에는 `warpgate_nodes` 한 대와 정확히 `k3s-01`, `postgres-01`,
`object-01`, `netbird-01`의 `warpgate_ssh_targets` group만 둔다. `object-01`의 SSH
HostKeyAlias는 인증된 기존 IP entry를 사용한다. inventory와 known_hosts는 저장소 밖
mode `0600` 파일이다.

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<trusted-known-hosts> -o GlobalKnownHostsFile=/dev/null -o PasswordAuthentication=no -o ControlMaster=no -o ControlPath=none"

ansible-playbook -i <outside-inventory> \
  -e "@<WG-01 admin secret vars>" \
  -e "warpgate_trusted_known_hosts_file=<trusted-known-hosts>" \
  playbooks/warpgate-ssh-targets.yml --syntax-check

ansible-playbook -i <outside-inventory> \
  -e "@<WG-01 admin secret vars>" \
  -e "warpgate_trusted_known_hosts_file=<trusted-known-hosts>" \
  playbooks/warpgate-ssh-targets.yml --check --diff

ansible-playbook -i <outside-inventory> \
  -e "@<WG-01 admin secret vars>" \
  -e "warpgate_trusted_known_hosts_file=<trusted-known-hosts>" \
  playbooks/warpgate-ssh-targets.yml

# listener :2222의 공개 host key는 strict 관리 SSH로 인증된 warpgate-01의 service
# PID·socket 소유 검증 후 얻은 loopback key와 외부 listener가 일치할 때만 저장소 밖
# 전용 known_hosts에 최초 pin된다. 일반 SSO 계정을 가장하지 않고, 실행 중에만 존재하는
# `platform-privileged` 일회성 verifier로 relay·session·recording metadata를 확인하고
# 성공·실패와 관계없이 product DB에서 제거한다.
ansible-playbook -i <outside-inventory> \
  -e "@<WG-01 admin secret vars>" \
  -e "wg03_listener_known_hosts_file=<outside-listener-known-hosts>" \
  playbooks/warpgate-ssh-targets-verify.yml
```

관리 API는 loopback에서만 호출한다. `--check`는 원격 `authorized_keys` 행의 예상 diff만
보며, Warpgate HTTP API의 생성·role 부여는 실제 apply에서만 반영된다.

## 판정과 rollback

완료 판정은 다음만 사용한다.

1. OPNsense 일반 drift check가 무변경이고 Warpgate source에서 네 FQDN의 TCP 22가 모두 열린다.
2. 네 대상의 `authorized_keys`에 WG-03 marker가 정확히 하나이며 owner/mode와 SSH
   public-key 인증 전제는 그대로다.
3. product DB의 네 target은 각 ed25519 known-host와 정확히 하나씩 연결되고
   `platform-privileged`만 허용한다.
4. strict 관리 SSH로 인증된 Warpgate service PID가 소유한 loopback listener와 독립 외부
   listener scan의 ed25519 key가 같아 저장소 밖 전용 known_hosts에 pin되고,
   `platform-privileged`만 가진 일회성 local verifier의 각 target relay와 Warpgate
   session/recording metadata가 성공한다. verifier는 성공·실패와 관계없이 삭제되며,
   role API 대조에서 `platform-users`는 허용되지 않는다.
5. 두 번째 apply가 `changed=0 failed=0`이다.

rollback은 이 task가 추가한 marker 행 네 개와 네 product target·known-host entry만
삭제하고, 내용이 정확히 일치하는 경우에만 WG-03 전용 listener known_hosts 한 줄도
삭제한다. 기존 rocky key, Warpgate local `admin`, Keycloak group, OPNsense alias/rule,
Proxmox와 VM은 rollback 대상이 아니다. host key mismatch, 대상 이름 충돌, SSH source/host
key 검증 실패, role API 대조 실패에서는 추가 변경 없이 중단하고 해당 레이어를 조사한다.

## 2026-08-11 실행 증거

1. `NET-04`가 소유한 OPNsense 일반 drift check는 무변경이었고, Warpgate source에서 네
   FQDN의 TCP 22 도달성을 확인했다. 방화벽·DNS·Keycloak membership·Proxmox는 변경하지
   않았다.
2. 인증된 저장소 밖 known_hosts의 ed25519 key로 네 target을 등록했고, 네 Rocky host의
   기존 `rocky` authorized_keys에는 source IP 및 forwarding 제한을 가진 WG-03 marker가
   정확히 한 줄씩 있다.
3. strict 관리 SSH로 인증한 `warpgate-01`의 active systemd main PID가 `:2222` listener를
   소유함을 확인했다. 그 loopback ed25519 key와 외부
   `warpgate.imcherry5778.xyz:2222` scan의 SHA-256 fingerprint가 일치해, 전용 mode `0600`
   listener known_hosts에 pin했다. TOFU는 사용하지 않았다.
4. product DB에는 `k3s-01`, `postgres-01`, `object-01`, `netbird-01` target이 정확히
   하나씩 있고, 모두 `platform-privileged` role 하나만 허용한다. 즉
   `platform-users`에는 target 권한이 없다.
5. Keycloak 사용자를 가장하지 않는 일회성 local verifier에 `platform-privileged`만
   부여해 네 target relay를 모두 성공시켰다. 새 session 네 건 이상과 각 `Terminal`
   recording metadata를 확인한 뒤 verifier user·credential·role을 삭제했다.
6. 정리 뒤 `playbooks/warpgate-ssh-targets.yml`을 다시 적용한 결과는 모든 host에서
   `changed=0 failed=0`이었다.
