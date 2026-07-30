# Ansible 공통 Baseline (`infra/ansible`)

이 디렉터리는 Proxmox cloud-init template 기반으로 생성되는 모든 Rocky Linux 9 VM에 적용되는 공통 baseline 플레이북과 구성을 소유한다.

- 검증일: 2026-07-31 (`VM-01`에서 실제 VM 5대에 적용·재부팅 후 멱등성 확인)
- 상태: `DONE` (작업 `OS-01`, `VM-01`에서 보정)

## 소유 범위 및 항목

- **cloud-init 및 qemu-guest-agent**: 게스트 에이전트 및 cloud-init 패키지 설치·활성화
- **시간대**: `/etc/localtime` 심볼릭 링크를 `system_timezone`으로 선언
- **시간 동기화**: `chronyd` 활성화와 VLAN gateway NTP source 배치
- **패키지 저장소**: 공식 Rocky Linux 9 저장소 (`baseos`, `appstream`) 접근·활성 상태 검증
- **SSH 접속**: cloud-init을 통해 주입된 `rocky` 사용자 SSH 공개키 기반 접속 및 authorized_keys 검증
- **Swap 비활성화**: 게스트 swap 비활성화 (`swapoff -a` 및 `/etc/fstab` 주석 처리) - k3s 요구사항 및 `capacity-plan.md` 준수
- **시스템 상태**: `systemctl --failed`로 실패한 systemd 유닛 0개 확인

 서비스별 방화벽, Kubernetes, PostgreSQL, MinIO 등의 특정 설정이나 임의의 자동 업데이트/CIS hardening은 이 공통 baseline에 넣지 않는다.

## k3s 단일 노드 기준선

`playbooks/k3s-baseline.yml`과 `roles/k3s_baseline/`은 `K3S-01`의 단일 server
k3s bootstrap을 소유한다. `update.k3s.io`의 `stable` 채널이 가리킨 실제 버전을
defaults에 정확히 고정하고, 공식 release binary SHA-256과 고정 commit의 install
script SHA-256을 검증한다. RHEL 계열은 Rancher GPG key로 검증하는
`k3s-selinux` 정책을 설치하며 SELinux enforcing을 유지한다.

이미 설치된 `k3s-selinux`는 정확한 NEVRA를 먼저 검증한다. `k3s-selinux`와
`container-selinux`가 모두 있으면 DNF를 다시 실행하지 않아, 멱등 실행이 외부
mirror metadata 갱신에 불필요하게 의존하지 않는다.

설정 파일은 SQLite 기본 datastore와 CoreDNS·Traefik·ServiceLB·local-path·
metrics-server 기본 구성을 그대로 둔다. node 주소, advertise 주소와 Pod/Service
CIDR는 저장소에 고정하지 않는다. kubeconfig와 server token은 게스트 밖으로
복사하거나 출력하지 않고 존재·경로·mode만 확인한다.

실제 inventory는 저장소 밖 mode `0600` 파일을 사용한다. 첫 적용 전에는 반드시
K3S-01 설치 승인 gate를 통과해야 한다.

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 known_hosts> -o PasswordAuthentication=no"
ansible-playbook -i <저장소 밖 inventory> playbooks/k3s-baseline.yml --syntax-check
ansible-playbook -i <저장소 밖 inventory> playbooks/k3s-baseline.yml --check --diff
# 명시적 승인 뒤에만 실제 적용
ansible-playbook -i <저장소 밖 inventory> playbooks/k3s-baseline.yml
```

적용·검증·재부팅·rollback과 SELinux 환경의 local-path 삭제 helper 함정은
[`docs/runbook/k3s-single-node-baseline.md`](../../docs/runbook/k3s-single-node-baseline.md)에
기록한다.

## NTP source

`NET-03`은 각 project VLAN에서 **해당 VLAN gateway의 UDP 123만** 허용한다. Rocky 기본 설정의 공개 pool은 차단되므로 그대로 두면 게스트가 영원히 동기화되지 않는다.

baseline은 `/etc/chrony.conf`에 `sourcedir`를 보장하고, 공개 `pool` 줄을 주석 처리한 뒤, `chrony_sources_dir`에 gateway 하나만 담은 `.sources` 파일을 둔다.

주소는 이 저장소에 고정하지 않는다. `chrony_ntp_server`의 기본값이 게스트의 실제 default route gateway(`ansible_default_ipv4.gateway`)이며, 필요하면 저장소 밖 inventory에서 덮어쓴다. 주소의 단일 원본은 [`docs/ip-plan.md`](../../docs/ip-plan.md)다.

성공 판정은 `chronyc sources`에서 gateway가 `^*`로 선택되고, `chronyc tracking`의 Stratum이 0이 아니며 Leap status가 `Normal`, `timedatectl`의 `NTPSynchronized=yes`인 상태다.

## host key 검증

`ansible.cfg`의 `host_key_checking`은 `True`다. `False`는 SSH host key 검증을 완전히 끄며, 위조된 key로도 접속이 성공한다.

게스트 host key는 인증된 경로(Proxmox 직렬 콘솔 또는 QGA)로 확인해 저장소 밖 `known_hosts`에 넣고, 실행할 때 지정한다. `ssh-keyscan`이나 `accept-new`만으로 신뢰를 확정하지 않는다.

```bash
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 known_hosts> -o PasswordAuthentication=no"
```

검증이 실제로 강제되는지 확인할 때는 SSH 연결 다중화를 꺼야 한다. 켜져 있으면 기존 control socket을 재사용해 host key 검증을 건너뛴다.

## check mode

읽기 전용 조회 태스크에는 `check_mode: false`가 있다. `ansible.builtin.command`는 check mode를 지원하지 않아 조회가 skip되고, 그 결과를 참조하는 `assert`가 빈 변수를 보고 실패하기 때문이다. `--check`가 실패하는 role은 적용 승인의 근거가 될 수 없다.

같은 이유로 timezone은 `timedatectl set-timezone` 대신 `/etc/localtime` 심볼릭 링크로 선언한다. 그 명령은 polkit의 `auth_admin_keep`을 지나므로 인증 agent가 없는 비대화형 sudo에서 `Access denied`로 실패하기도 한다.

## 파일 구조

```text
infra/ansible/
├── ansible.cfg              # 기본 설정 (host_key_checking, remote_user 등)
├── inventory/
│   └── hosts.example        # 비밀 없는 인벤토리 예시 (Git 추적)
├── playbooks/
│   ├── baseline.yml         # 공통 baseline 엔트리 플레이북
│   └── k3s-baseline.yml     # K3S-01 단일 server 엔트리 플레이북
└── roles/
    ├── common_baseline/     # 공통 baseline 검증 및 태스크
    └── k3s_baseline/        # 고정 k3s·SELinux·systemd 선언
```

## 구문 검사 (Syntax Check)

```bash
ansible-playbook -i inventory/hosts.example playbooks/baseline.yml --syntax-check
```

## 실행 및 멱등성 (Idempotency) 검증

1. 임시 인벤토리 생성 (`hosts.local` 등, `.gitignore`로 보호됨):
   ```ini
   [rocky_baseline]
   target-vm ansible_host=10.10.10.X ansible_user=rocky
   ```

2. 1차 적용:
   ```bash
   ansible-playbook -i inventory/hosts.local playbooks/baseline.yml
   ```

3. 2차 적용 (멱등성 검증 - `changed=0, failed=0` 확인):
   ```bash
   ansible-playbook -i inventory/hosts.local playbooks/baseline.yml
   ```
