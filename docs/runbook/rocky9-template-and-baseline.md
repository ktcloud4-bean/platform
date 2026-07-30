# Rocky Linux 9 Cloud-Init Template 및 Ansible Baseline 검증

검증일: 2026-07-30  
소유 작업: `OS-01`

## 1. 목적

Proxmox VE (10.10.10.10) 상에 Rocky Linux 9 GenericCloud 공식 기반 최소 템플릿(VMID `9000`)을 생성하고, 임시 full clone을 통해 SSH key 주입, 시간 동기화(Asia/Seoul, chrony), 공식 저장소 접근, qemu-guest-agent, swap 비활성화, 재부팅 후 유지 및 Ansible 멱등성(idempotency)을 실물 검증한 후 임시 clone을 안전하게 폐기하는 절차를 소유한다.

## 2. 전제조건 및 접근 권한

- Proxmox VE SSH root 접근 권한 (`10.10.10.10`)
- 공유 잠금 `PVE-LIVE` 단독 소유
- Proxmox 스토리지 `local` 및 `local-lvm` 정상 동작 (`pvesm status`)
- Proxmox 호스트의 인터넷 아웃바운드 연결 (`dl.rockylinux.org` 접속 가능)
- DHCP 주소 할당이 가능한 네트워크 (Phase 1 LAN `10.10.10.0/24`)

## 3. 예상 영향 및 공유 잠금

- **공유 잠금**: `PVE-LIVE`
- **영향 범위**: 신규 VMID `9000` (Template) 및 임시 검증 VMID `9999` (Full Clone). 기존 VM/스토리지/네트워크/OPNsense는 일체 수정하지 않는다.
- **물리 호스트 영향**: 물리 호스트 및 `vmbr0`를 리부트하거나 변경하지 않는다.

## 4. 실행 순서

### 4.1. Template 생성 (VMID 9000)

Proxmox 호스트 상에서 이미지 검증 및 Template 생성 스크립트를 실행한다.

```bash
ssh root@10.10.10.10 'bash -s' < infra/proxmox/template/create-rocky9-template.sh
```

- 스크립트 내부에서 GPG 서명(`CHECKSUM.asc`) 및 SHA256 Checksum 검증을 거친다.
- 실패 시(Checksum 불일치 등) 즉시 중단된다.

### 4.2. 폐기용 Full Clone 생성 및 검증 환경 설정 (VMID 9999)

```bash
# 1. 임시 SSH 키 생성 (저장소 밖 /tmp)
ssh-keygen -t ed25519 -N "" -f /tmp/os01_test_key

# 2. Template 9000에서 Full Clone 생성
ssh root@10.10.10.10 '
  qm clone 9000 9999 --name os01-verify-clone --full
  qm set 9999 --ipconfig0 ip=dhcp
'

# 3. 임시 SSH 공개키 주입
ssh root@10.10.10.10 "qm set 9999 --sshkeys -" < /tmp/os01_test_key.pub

# 4. 검증 VM 시작
ssh root@10.10.10.10 'qm start 9999'
```

### 4.3. 게스트 OS 라이브 검증 및 Ansible 적용

1. **IP 및 Guest Agent 확인**:
   ```bash
   ssh root@10.10.10.10 'qm guest cmd 9999 network-get-interfaces'
   ```
2. **SSH 접속 및 기본 검사**:
   ```bash
   SSH_IP=$(ssh root@10.10.10.10 'qm guest cmd 9999 network-get-interfaces' | grep -oE '10\.10\.10\.[0-9]+' | head -n 1)
   ssh -i /tmp/os01_test_key rocky@$SSH_IP '
     cloud-init status --wait
     timedatectl
     chronyc tracking
     dnf repolist
     systemctl is-active qemu-guest-agent
     systemctl list-units --failed
   '
   ```
3. **Ansible Baseline 적용 & 멱등성 검증**:
   - `inventory/hosts.local` 생성 (`ansible_host=$SSH_IP ansible_user=rocky ansible_ssh_private_key_file=/tmp/os01_test_key`)
   - 1차 실행: `ansible-playbook -i inventory/hosts.local playbooks/baseline.yml`
   - 2차 실행: `ansible-playbook -i inventory/hosts.local playbooks/baseline.yml` (`changed=0` 검증)

4. **게스트 재부팅 및 재검증**:
   ```bash
   ssh root@10.10.10.10 'qm reboot 9999'
   # 부팅 완료 후 동일 SSH, NTP, qemu-agent, failed units 검사 대조
   ```

### 4.4. 검증 완료 후 cleanup

```bash
# 검증용 Full Clone만 삭제 (Template 9000은 보존)
ssh root@10.10.10.10 'qm stop 9999 && qm destroy 9999'
rm -f /tmp/os01_test_key /tmp/os01_test_key.pub
```

## 5. 성공 판정 기준

- [x] GPG 및 SHA256 Checksum 검증 통과 후 VMID `9000` Template 생성 완료
- [x] Full Clone(VMID 9999)에 주입된 SSH 공개키로 `rocky` 계정 로그인 성공
- [x] secret이 Git 및 인벤토리에 노출되지 않음
- [x] 타임존 `Asia/Seoul`, `chronyd` NTP 동기화 완료
- [x] 공식 dnf repo (`baseos`, `appstream`) 정상 조회
- [x] `qemu-guest-agent` active/enabled 및 Proxmox `qm guest cmd` 응답 정상
- [x] `systemctl --failed` 0개
- [x] 게스트 재부팅 후에도 위 항목 모두 정상 유지
- [x] Ansible 1차 성공 및 2차 멱등성(`changed=0`) 확인
- [x] 검증 clone (VMID 9999) 안전하게 제거 완료

## 6. 실패 시 중단 및 복구 (Rollback)

- **GPG/Checksum 실패 시**: 스크립트 자동 종료되며 템플릿 미생성. 임시 빌드 디렉터리 자동 삭제됨.
- **Proxmox/게스트 검증 실패 시**:
  ```bash
  ssh root@10.10.10.10 'qm stop 9999 2>/dev/null; qm destroy 9999 2>/dev/null'
  ```
  실패 로그 분석 후 `create-rocky9-template.sh` 또는 Ansible 태스크를 수정하고 재시도한다.

## 7. 시크릿 및 출력 보안

- 테스트용 SSH private key `/tmp/os01_test_key`는 저장소 밖에 생성하며 검증 후 즉시 파기한다.
- `hosts.local` 등 실제 IP/자격증명이 든 파일은 `.gitignore`에 의해 커밋 대상에서 자동 제외된다.
