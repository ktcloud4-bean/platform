# Proxmox 서비스 VM 생성 (OpenTofu)

- 검증일: 2026-07-31
- 작업: `VM-01`
- 상태: 적용·게스트 검증·재부팅·무변경 재계획 완료

## 목적과 경계

`OS-01`의 cloud-init template에서 서비스 VM 5대를 한 번의 OpenTofu apply로 만들고, cloud-init·공통 Ansible baseline·VLAN bootstrap 네트워크·재부팅 영속성을 라이브에서 판정한다.

주소·VM 사양·VM 계약은 이 문서가 소유하지 않는다. [`docs/ip-plan.md`](../ip-plan.md), [`docs/capacity-plan.md`](../capacity-plan.md), [`infra/proxmox/tofu/README.md`](../../infra/proxmox/tofu/README.md)를 따른다.

다음은 범위가 아니다.

- Proxmox 노드·datastore·bridge·VLAN 인터페이스·ACME·인증서를 resource로 선언하거나 import
- template VMID 9000 수정·삭제·재작성
- `/etc/network/interfaces`, `vmbr0`, `vmbr0.10` 변경
- OPNsense PF·alias·DHCP·DNS·NAT·interface·gateway 변경
- k3s·PostgreSQL·MinIO·NetBird·Warpgate 서비스 설치
- 서비스 포트·공개 DNS·NAT·VPN·Suricata·`NET-04` 정책 추가

## 전제와 중단 조건

1. `docs/backlog.md`에서 선행 완료와 `TOFU-STATE`·`PVE-LIVE` 잠금을 확인한다. 두 잠금은 plan부터 최종 검증까지 한 작업자가 소유한다.
2. 작업 ID 전용 branch를 쓰고 `main` 작업 트리가 깨끗한지 확인한다.
3. Proxmox strict SSH와 8006 strict TLS, 인증된 API 읽기가 모두 성공해야 한다.
4. 대상 VMID와 이름이 부재해야 한다.
5. `capacity-plan.md`의 어떤 지표도 정지 구간이면 안 된다.

다음이면 apply하지 않는다.

- 다른 세션이 같은 state 또는 `PVE-LIVE`를 사용 중
- 저장된 binary plan의 SHA-256이 바뀜
- 대상 IP가 ARP에 응답하거나 대상 VMID가 출현
- 라이브 상태가 문서 전제와 다름

## 자격증명

API token은 전용 최소권한 주체를 쓴다. 주체·권한·폐기 절차는 [`infra/proxmox/tofu/README.md`](../../infra/proxmox/tofu/README.md)가 소유한다.

권한은 provider 문서의 role 예시를 그대로 쓰지 않고 설치본 소스에서 확인한다. 두 곳을 봐야 한다.

| 확인 위치 | 결정하는 것 |
|---|---|
| `PVE/API2/Qemu.pm`의 `$check_vm_modify_config_perm` | 설정 항목별 `VM.Config.*`. `startup`만 추가로 `/`의 `Sys.Modify`를 요구한다 |
| `PVE/QemuServer.pm`의 `check_bridge_access` → `PVE/GuestHelpers.pm`의 `check_vnet_access` | bridge 접근. `/sdn/zones/localnetwork/<bridge>` 및 tag가 있으면 `/<tag>`에 `SDN.Use` |

**config 권한만 보고 role을 만들면 clone 단계에서 403으로 실패한다.** clone은 원본 template의 config로 검사하므로, template의 `net0`에 tag가 없으면 bridge 전체 경로 권한이 필요하다. 이후 VLAN tag를 넣는 설정 변경은 tag별 경로를 추가로 요구한다.

`SDN.Use`는 bridge 경로에 `propagate=0`으로 주고 실제 사용할 VLAN tag 경로만 개별 부여한다. 그러면 이 token은 관리 VLAN에 VM을 붙일 수 없다.

## backup과 rollback 준비

저장소 밖에 `mktemp -d`로 작업 전용 디렉터리를 만들고 mode `0700`으로 둔다. 아래를 mode `0600`으로 보관하고 내용은 출력하지 않는다.

사전 `qm list`·`pct list`, 대상 VMID 부재 증거, template 의미값, `/etc/network/interfaces` SHA-256, bridge·storage·capacity 요약, 실제 변수 파일, binary plan과 SHA-256, apply 직후와 최종 state 사본과 SHA-256, strict `known_hosts`, 검증 plan과 결과.

raw state, binary plan 내용, API token, private key, SSH host key 원문은 Git·채팅·일반 로그·완료 보고에 남기지 않는다.

1차 rollback은 state와 라이브를 보존한 채 원인을 분석하고 새 plan으로 수렴시키는 것이다. 부분 실패 후 같은 apply를 반복하지 않고 `qm create/set/destroy`로 수동 보정하지 않는다.

파괴적 rollback이 필요하면 `tofu plan -destroy`를 별도 binary plan으로 만들고, 대상이 이번에 만든 VM 5대뿐이며 template·node·datastore·bridge가 포함되지 않음을 확인한 뒤 별도 승인을 받는다.

## 실행 순서

1. `tofu fmt -check -recursive`, `tofu init`(`-upgrade` 금지), `tofu validate`.
2. gate를 닫은 `tofu plan`으로 `blocked_by` 의미를 확인한다.
3. 저장소 밖 mode `0600` 변수 파일에 라이브에서 확인한 gate 값을 넣는다.
4. `tofu plan -out=<저장소 밖 binary plan>`. `5 to add, 0 to change, 0 to destroy`, replace 없음, check 경고 없음, 모든 대상이 `module.service_vm[...]`인지 확인한다.
5. 사람이 승인한다.
6. apply 직전에 plan SHA-256, 구성·lock 불변, 대상 VMID 부재, 정지 기준, strict TLS/SSH/API를 다시 확인한다.
7. Proxmox 영속 설정을 바꾸지 않는 임시 namespace/veth로 각 대상 IP의 L2 충돌을 확인한다. gateway ARP 응답과 대상 무응답을 함께 봐야 판정이 유효하다. 확인 후 자신이 만든 자원만 제거하고 `/etc/network/interfaces` SHA-256 불변을 확인한다.
8. `tofu apply <승인된 plan>`을 한 번만 실행한다.
9. state·Proxmox config·게스트 런타임 세 계층을 독립적으로 대조한다.
10. 게스트 SSH 신뢰를 세우고 공통 Ansible baseline을 적용한다.
11. 각 VM에서 `vlan-verify run --profile bootstrap`을 실행한다.
12. VM을 한 대씩 정상 재부팅하고 전 항목을 재검증한다.
13. `tofu plan -detailed-exitcode`가 exit `0`인지 확인한다.

## L2 충돌 검사

`arping`은 Proxmox 기본 설치에 없다. **도구 부재로 인한 무응답을 미사용 판정으로 쓰지 않는다.** 표준 라이브러리만 쓰는 ARP prober를 namespace 안에서 실행하고, 같은 실행에서 gateway 응답이 있어야 결과가 유효하다.

임시 자원 이름이 이미 있으면 삭제하지 않고 새 이름을 쓴다. source 주소는 `docs/ip-plan.md`의 실험 범위에서 고르되 해당 VLAN의 DHCP 범위와 겹치지 않는 값을 쓴다.

## 게스트 SSH 신뢰 부트스트랩

첫 SSH에서 `accept-new`나 `ssh-keyscan` 단독을 쓰지 않는다.

Rocky GenericCloud의 qemu-guest-agent는 `guest-exec`와 `guest-file-read`를 차단한다. `guest-info`로 사용 가능한 명령을 먼저 확인한다. `guest-set-user-password`가 열려 있으면 다음 경로를 쓸 수 있다.

1. strict SSH로 접속한 Proxmox에서 QGA로 bootstrap 사용자에게 임시 password를 설정한다.
2. `/var/run/qemu-server/<vmid>.serial0` 유닉스 소켓으로 콘솔에 로그인해 `/etc/ssh/ssh_host_*_key.pub`를 읽는다.
3. 읽은 직후 `passwd -d` + `passwd -l`로 계정을 원래대로 잠그고 `passwd -S`로 확인한다.
4. 이름과 IP 양쪽에 대응하는 `known_hosts`를 저장소 밖 mode `0600`으로 만든다. 기존 항목과 다르면 덮어쓰지 않고 중단한다.

콘솔 자동화에서 명령 에코와 출력 마커가 겹치지 않게 한다. `echo __E""E__`처럼 셸이 조립하는 마커를 쓰면 에코된 명령줄이 종료 조건으로 오인되지 않는다.

이후 모든 SSH와 Ansible은 `StrictHostKeyChecking=yes`와 이 `known_hosts`를 쓴다. 강제 여부는 **위조 키로 실패하는지**까지 확인해야 증명된다. 이때 SSH 연결 다중화를 끄지 않으면 기존 control socket을 재사용해 검증을 건너뛴다.

## 게스트 판정 항목

`cloud-init status --wait` 성공과 error 부재, hostname/FQDN, Rocky Linux 9, 예상 IPv4와 interface, 예상 default route와 VLAN gateway, 원치 않는 routed IPv6/RA 부재, DNS resolver, `qemu-guest-agent` active/enabled와 QGA 응답, root disk의 Day 1 크기 확장, swap 0, chronyd 상태와 실제 source/tracking, 공식 Rocky 저장소, failed systemd unit 0, 공개키 기반 로그인.

`cloud-init status --long`의 `recoverable_errors`에 `DEPRECATED`만 있으면 오류가 아니다. `errors: []`를 함께 본다.

## 시간 동기화

`NET-03`은 각 VLAN gateway의 UDP 123만 허용하고 공개 NTP를 차단한다. 배포판 기본 설정은 공개 pool을 쓰므로 게스트는 영원히 동기화되지 않는다.

판정은 추론이 아니라 측정으로 한다.

```sh
chronyd -Q -t 8 "server <해당 VLAN gateway> iburst"   # 응답하면 성공
chronyd -Q -t 6 "server <공개 pool> iburst"           # Timeout 이면 차단
```

gateway가 응답하면 공개 UDP 123을 열지 않는다. ad-hoc 게스트 편집도 하지 않는다. 공통 baseline에 host별 gateway를 전달하는 선언형 변경을 만든다. 주소는 tracked 파일에 고정하지 않고 게스트의 실제 default route에서 가져온다.

성공 판정은 `chronyc sources`에서 gateway가 `^*`로 선택되고 `chronyc tracking`의 Stratum이 0이 아니며 Leap status가 `Normal`, `timedatectl`의 `NTPSynchronized=yes`인 상태다.

## Ansible 주의점

`ansible.builtin.command`는 check mode를 지원하지 않는다. 읽기 전용 조회 태스크에 `check_mode: false`를 두지 않으면 `--check`에서 skip되고, 그 결과를 참조하는 `assert`가 빈 변수를 보고 실패한다. **`--check`가 실패하는 role은 승인 판단의 근거가 될 수 없다.**

같은 이유로 변경을 수행하는 `command` 태스크는 `--check`가 변경을 예고하지 못한다. timezone처럼 결과를 파일 상태로 표현할 수 있으면 `ansible.builtin.file`로 선언한다.

`timedatectl set-timezone`은 쓰지 않는다. polkit의 `org.freedesktop.timedate1.set-timezone`이 `auth_admin_keep`이라 인증 agent가 없는 비대화형 sudo에서 `Failed to set time zone: Access denied`로 실패한다. `/etc/localtime` 심볼릭 링크가 timezone의 실제 원본이며 `timedatectl`이 그 값을 읽는다.

`ansible.cfg`의 `host_key_checking = False`는 host key 검증을 완전히 끈다. 실제 VM 작업에는 쓰지 않는다.

## VLAN 검증

`vlan-verify`의 BLOCK 판정에는 900초 이내의 다른 source `ALLOW PASS` control이 필요하다. timeout이나 connection refused만으로는 판정하지 않는다.

MGMT control은 Proxmox 호스트 자신이 아니라 VLAN 10 임시 namespace에서 만든다. 호스트 자신의 관리 주소는 로컬 route라 source 검증이 `INCONCLUSIVE`가 된다.

MGMT에서 각 VM으로 시작한 strict SSH 왕복도 확인한다. Proxmox에 운영자 private key를 복사하지 않는다. SSH agent forwarding을 쓰면 키를 옮기지 않고 MGMT 출발 연결을 만들 수 있다.

같은 VLAN 안의 통신은 OPNsense를 지나지 않으므로 OPNsense 차단 증거로 부르지 않는다.

## 재부팅

모든 초기 검증이 성공한 뒤 한 대씩 정상 재부팅한다. Proxmox 호스트는 재부팅하지 않고 5대를 동시에 재부팅하지 않는다. 정해진 시간 안에 QGA/SSH가 돌아오지 않으면 반복 재부팅하지 말고 콘솔 상태를 확인한 뒤 추가 쓰기를 중단한다.

재부팅 후 boot time 변경, SSH host key 불변, 하드웨어 config, 주소·route·DNS, cloud-init, agent, chronyd gateway 동기화, swap, disk, failed unit, Ansible 멱등성, `vlan-verify`, MGMT 연결을 다시 확인한다. **재부팅 전 성공만으로 완료 처리하지 않는다.**

## 정리

자신이 만든 임시 namespace·veth·listener·plan·스크립트만 제거한다. Proxmox와 게스트 양쪽의 작업 임시 파일을 확인한다. 전후 `/etc/network/interfaces` SHA-256과 template config 해시가 같아야 한다.

## 2026-07-31 검증 기록

- 사전 점검에서 대상 VMID 5개 부재, template `bios`/`machine` 생략 필드의 실제 계약(`seabios`/`pc`), 용량 지표 전부 정상, `NET-03` PF 24개 유지를 확인했다.
- 첫 apply는 5대 모두 `SDN.Use` 403으로 실패했다. 부분 생성·orphan 볼륨·`qmclone` task가 없고 template과 영속 네트워크가 불변임을 확인한 뒤 권한을 좁게 보정하고 새 plan으로 재승인받았다.
- 두 번째 apply에서 5대가 생성·기동됐다. state 5개, Proxmox config, 게스트 런타임 세 계층이 일치했다.
- L2 충돌 검사에서 5개 VLAN 모두 gateway ARP 응답과 대상 IP 무응답을 함께 관측했다.
- 게스트 SSH host key를 직렬 콘솔로 읽어 `known_hosts`를 만들고, 위조 키로 실패하는 것까지 확인해 strict 검증을 증명했다.
- chronyd는 적용 전 공개 pool만 보고 `Not synchronised`였고, gateway NTP는 응답, 공개 NTP는 timeout이었다. 공통 baseline 보정 후 5대 모두 gateway를 `^*`로 선택하고 `NTPSynchronized=yes`가 됐다.
- Ansible 1차 적용 후 2차·재부팅 후 3차 모두 `changed=0, failed=0`이었다.
- 실제 VM source의 `vlan-verify bootstrap`이 적용 후와 재부팅 후 각각 5대 × 18 probe 전부 PASS했다. 모든 BLOCK은 최신 MGMT ALLOW control과 대조됐다.
- 최종 `tofu plan -detailed-exitcode`가 exit `0`, `No changes`였다.
- 임시 자원을 모두 제거했고 Proxmox 영속 네트워크 해시와 template config 해시가 유지됐다.
