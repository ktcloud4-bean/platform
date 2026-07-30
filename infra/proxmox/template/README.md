# Proxmox Rocky Linux 9 Cloud-Init Template (VMID 9000)

이 디렉터리는 Proxmox VE 상에서 Rocky Linux 9 GenericCloud 공식 이미지 기반의 최소 cloud-init template을 생성하고 관리하는 표준 절차를 소유한다.

검증일: 2026-07-30  
상태: `DONE` (작업 `OS-01`)

## 사양 및 이미지 출처

| 항목 | 명세 |
|---|---|
| 배포판 | Rocky Linux 9 x86_64 GenericCloud (`Rocky-9-GenericCloud-Base-9.8-20260525.0.x86_64.qcow2`) |
| 공식 출처 | `https://dl.rockylinux.org/pub/rocky/9/images/x86_64/` |
| GPG 키 | `https://dl.rockylinux.org/pub/rocky/RPM-GPG-KEY-Rocky-9` |
| 무결성 검증 | GPG 서명된 CHECKSUM.asc 및 SHA256 Checksum 필수 검증 |

## Template 계약 (OpenTofu 대조 항목)

[`infra/proxmox/tofu/README.md`](../tofu/README.md)의 VM 계약 기준에 맞춰 다음 설정을 보장한다.

| 항목 | 설정값 | 이유 / 비고 |
|---|---|---|
| Template VMID | `9000` | 서비스 VMID 대역(120~151) 및 VLAN 번호(10~60)와 충돌하지 않는 고정 ID |
| BIOS | `seabios` | OpenTofu 기본값 (`pc` machine type) |
| Machine Type | `pc` (i440fx) | 표준 가상 하드웨어 |
| Disk Controller | `virtio-scsi-pci` | Proxmox 고성능 SCSI 컨트롤러 |
| Root Disk | `scsi0` on `local-lvm` | `discard=on,ssd=1` 옵션으로 thin provisioning 및 fstrim 보장 |
| Cloud-Init Drive | `ide2` on `local-lvm` | OpenTofu default `cloud_init_interface = "ide2"` 계약 준수 |
| Guest Agent | 활성화 (`agent: enabled=1`) | 게스트 OS 통신, IP 조회, 정상 종료/재부팅 응답 |
| Network | `net0` virtio on `vmbr0` | Phase 1 untagged 브릿지 사용 |

## 생성 절차

Proxmox 호스트(10.10.10.10)에서 `create-rocky9-template.sh` 스크립트를 실행한다.

```bash
# Proxmox 호스트 상에서 실행
./create-rocky9-template.sh
```

스크립트는 다음 동작을 자동 수행한다:
1. 임시 빌드 디렉터리 생성 (`/tmp/rocky9-template-build.XXXXXX`)
2. 공식 URL에서 qcow2 이미지, CHECKSUM, CHECKSUM.asc, GPG 키 다운로드
3. GPG 서명 검증 및 SHA256 checksum 대조 (불일치 시 즉시 실패 중단)
4. `qm create 9000`으로 기본 VM 구획 생성
5. `qm importdisk`로 `local-lvm`에 root disk 저장
6. 컨트롤러, cloud-init drive(`ide2`), qemu-guest-agent, serial console 설정 적용
7. `qm template 9000`으로 template 전환 및 임시 파일 자동 삭제

## 재작성 및 Rollback 절차

템플릿을 재생성해야 할 경우 다음 순서로 삭제 후 재실행한다.

```bash
# 1. 템플릿 기반으로 생성된 테스트/임시 VM이 없는지 확인
qm list

# 2. 템플릿 제거
qm destroy 9000

# 3. 템플릿 스크립트 재실행
./create-rocky9-template.sh
```
