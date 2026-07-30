# Ansible 공통 Baseline (`infra/ansible`)

이 디렉터리는 Proxmox cloud-init template 기반으로 생성되는 모든 Rocky Linux 9 VM에 적용되는 공통 baseline 플레이북과 구성을 소유한다.

검증일: 2026-07-30  
상태: `DONE` (작업 `OS-01`)

## 소유 범위 및 항목

- **cloud-init 및 qemu-guest-agent**: 게스트 에이전트 및 cloud-init 패키지 설치·활성화
- **시간 동기화**: `chronyd` 활성화 및 타임존 `Asia/Seoul` 확인
- **패키지 저장소**: 공식 Rocky Linux 9 저장소 (`baseos`, `appstream`) 접근·활성 상태 검증
- **SSH 접속**: cloud-init을 통해 주입된 `rocky` 사용자 SSH 공개키 기반 접속 및 authorized_keys 검증
- **Swap 비활성화**: 게스트 swap 비활성화 (`swapoff -a` 및 `/etc/fstab` 주석 처리) - k3s 요구사항 및 `capacity-plan.md` 준수
- **시스템 상태**: `systemctl --failed`로 실패한 systemd 유닛 0개 확인

 서비스별 방화벽, Kubernetes, PostgreSQL, MinIO 등의 특정 설정이나 임의의 자동 업데이트/CIS hardening은 이 공통 baseline에 넣지 않는다.

## 파일 구조

```text
infra/ansible/
├── ansible.cfg              # 기본 설정 (host_key_checking, remote_user 등)
├── inventory/
│   └── hosts.example        # 비밀 없는 인벤토리 예시 (Git 추적)
├── playbooks/
│   └── baseline.yml         # 공통 baseline 엔트리 플레이북
└── roles/
    └── common_baseline/     # 공통 baseline 검증 및 태스크
        └── tasks/
            └── main.yml
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
