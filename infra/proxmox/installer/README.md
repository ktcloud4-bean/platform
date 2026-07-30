# Proxmox VE 무인 설치 ISO

공식 Proxmox `answer.toml` schema와 `proxmox-auto-install-assistant`로 재생성 가능한 설치 ISO를 만든다. 이 디렉터리는 비밀 없는 template, 고정한 원본과 도구 manifest, 생성·검증 코드만 소유한다. 실제 `answer.toml`, 생성 ISO, SSH key와 설치 디스크는 저장소 밖의 폐기 가능한 디렉터리에만 둔다.

이 절차의 PoC 대상은 로컬 QEMU/KVM의 단일 qcow2다. 현재 물리 Proxmox, 그 NVMe, Proxmox API/SSH와 `PVE-LIVE` 자산에는 접근하지 않는다. PoC 통과도 물리 노드 재설치 승인이 아니다.

## 공식 기준과 고정 버전

2026-07-30에 다음 공식 자료를 다시 확인했다.

- [Proxmox VE 9.2 ISO Installer](https://www.proxmox.com/en/downloads/proxmox-virtual-environment/iso/proxmox-ve-9-2-iso-installer)
- [Automated Installation](https://pve.proxmox.com/wiki/Automated_Installation)
- [Proxmox VE Administration Guide](https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf)의 Unattended Installation
- [공식 pve-installer source](https://git.proxmox.com/?p=pve-installer.git;a=summary)

ISO URL·파일명·버전·크기·SHA256, release key fingerprint, assistant 패키지 버전·SHA256과 실행 image digest의 단일 원본은 [`sources.lock`](sources.lock)이다. ISO는 PVE `9.2-1`, assistant는 `9.2.7`로 고정했다. assistant 패키지 checksum은 Proxmox Trixie 저장소의 release key로 서명된 package index와 대조했다.

공식 schema는 수동 설치 runbook의 선택을 다음처럼 표현한다.

| 수동 기준 | answer 표현 |
|---|---|
| `ext4`, LVM 자동 배분 | `[disk-setup] filesystem = "ext4"`; `lvm.*` 생략 |
| `Asia/Seoul`, US keyboard | `[global]`의 고정 비밀 아닌 값 |
| FQDN·주소·gateway·DNS | 저장소 밖 입력으로 `from-answer` 렌더링 |
| root 인증 | 평문 대신 외부 `root-password-hash`와 SSH 공개키 |
| NIC pinning | 고유 MAC filter + `interface-name-pinning.enabled = true` |
| 설치 디스크 | 고유 `ID_SERIAL_SHORT` exact filter |

공식 문서상 `disk-list`는 “후보 목록”이며 목록의 장치가 없어도 filesystem에 충분한 다른 장치가 있으면 계속할 수 있다. 따라서 이 구현은 `disk-list`에 안전성을 의존하지 않는다. PoC에서는 QEMU NVMe serial의 exact filter를 쓰고, launcher가 regular qcow2 하나만 target disk로 전달하며, 설치 후에도 guest disk 수와 serial을 검증한다.

## 파일

| 파일 | 역할 |
|---|---|
| `answer.toml.template` | TOML 문법을 유지한 비밀 없는 placeholder template |
| `sources.lock` | 공식 ISO·release key·assistant·container 고정값 |
| `Containerfile.assistant` | Fedora 호스트를 바꾸지 않고 공식 Debian 패키지를 실행하는 환경 |
| `scripts/fetch-sources.sh` | 원본을 외부 cache에 받고 즉시 검증 |
| `scripts/verify-sources.sh` | ISO SHA256·크기·이중 서명, assistant SHA256 검증 |
| `scripts/render-answer.sh` | 한 줄 입력 파일을 검증하고 실제 answer를 외부에 mode `0600`으로 생성 |
| `scripts/assistant.sh` | 공식 answer 검증, ISO 생성, 민감 필드를 출력하지 않는 ISO 점검 |
| `scripts/poc.sh` | 외부 PoC 준비, headless QEMU 시작, 설치·재부팅 판정, 제한된 정리 |
| `scripts/self-test.sh` | shell/TOML/실패 경로/ignore 정적 회귀 검사 |

## 전제와 중단 조건

필수 명령은 `curl`, `gpg`, `gpgv`, `sha256sum`, `podman`, `qemu-system-x86_64`, `qemu-img`, `xorriso`, `ssh`, `openssl`이다. PoC에는 쓰기 가능한 `/dev/kvm`, OVMF, 최소 8 GiB RAM과 충분한 외부 파일시스템 여유가 필요하다.

다음이면 즉시 멈춘다.

- `AUTO-01` 또는 선행 `PVE-01` 상태가 바뀌었다.
- checksum·ISO signature·release key fingerprint 중 하나가 다르다.
- 실제 answer의 공식 `validate-answer`가 실패한다.
- 출력 또는 입력 디렉터리가 저장소 안이거나 심볼릭 링크다.
- target이 regular qcow2가 아니거나 block device다.
- QEMU 명령행에 host `/dev/sd*`, `/dev/nvme*`, `/dev/vd*`, `/dev/xvd*`가 있다.
- 고유 disk/NIC filter가 실제 장치 속성과 일치하는지 증명할 수 없다.
- 로컬 KVM 검증이 불가능하다. 이 경우 물리 Proxmox나 그 위 nested VM으로 대체하지 않는다.

## 원본과 공식 assistant 준비

저장소 밖의 cache를 명시한다. 기존 파일은 덮어쓰지 않으며, 검증된 원본 ISO와 official assistant package는 재사용 가능한 비민감 cache로 보존한다.

```sh
AUTO01_INSTALLER_DIR="$PWD/infra/proxmox/installer"
AUTO01_CACHE_DIR=/home/imcherry/.cache/proxmox

"$AUTO01_INSTALLER_DIR/scripts/fetch-sources.sh" "$AUTO01_CACHE_DIR"
"$AUTO01_INSTALLER_DIR/scripts/build-assistant-image.sh" "$AUTO01_CACHE_DIR"
```

`fetch-sources.sh`는 ISO SHA256과 byte size를 먼저 확인하고, Trixie·Bookworm 공식 release key 양쪽으로 detached signature를 검증한다. assistant `.deb`도 manifest SHA256과 일치해야 한다. 컨테이너는 설치된 호스트 패키지를 바꾸지 않으며, ISO를 만들 때 network를 차단한다.

## 운영용 answer와 ISO 생성

정확한 FQDN·주소·gateway·DNS는 [`docs/ip-plan.md`](../../../docs/ip-plan.md)를 그 시점에 읽어 저장소 밖 입력으로 만든다. 값 자체를 이 문서나 template에 복제하지 않는다. `input-dir`에는 아래 이름의 한 줄 regular file 아홉 개가 필요하다.

```text
fqdn
mailto
root-password-hash
root-ssh-key
cidr
gateway
dns
nic-mac
disk-serial
```

`root-password-hash`는 저장소 밖에서 `openssl passwd -6`처럼 비밀번호를 명령 인자에 넣지 않는 대화형 방식으로 만든다. `root-ssh-key`에는 공개키 한 줄만 둔다. 운영 email, hash, private key를 shell 인자·환경변수·로그에 넣지 않는다. `disk-serial`과 `nic-mac`은 설치 대상의 공식 `device-info` 결과에서 고유성이 확인된 값만 쓴다.

```sh
AUTO01_INPUT_DIR="$(mktemp -d /home/imcherry/auto-01-input.XXXXXX)"
AUTO01_OUTPUT_DIR="$(mktemp -d /home/imcherry/auto-01-output.XXXXXX)"
chmod 700 "$AUTO01_INPUT_DIR" "$AUTO01_OUTPUT_DIR"

# 운영자가 docs/ip-plan.md와 대상 장치 속성을 읽어 위 아홉 파일을 안전하게 작성한다.
"$AUTO01_INSTALLER_DIR/scripts/render-answer.sh" \
  "$AUTO01_INPUT_DIR" "$AUTO01_OUTPUT_DIR/answer.toml"
"$AUTO01_INSTALLER_DIR/scripts/assistant.sh" validate \
  "$AUTO01_OUTPUT_DIR/answer.toml"
"$AUTO01_INSTALLER_DIR/scripts/assistant.sh" prepare \
  "$AUTO01_CACHE_DIR/iso/proxmox-ve_9.2-1.iso" \
  "$AUTO01_OUTPUT_DIR/answer.toml" \
  "$AUTO01_OUTPUT_DIR/proxmox-auto.iso"
```

실제 answer와 생성 ISO는 둘 다 민감하며 mode `0600`이다. 공식 assistant만 ISO를 변경한다. 원본 ISO를 직접 풀어 편집하거나 생성 ISO를 Git에 추가하지 않는다.

## 격리 QEMU/KVM PoC

아래 PoC fixture는 RFC 5737 문서용 대역과 `example.invalid`만 사용한다. QEMU user network는 `restrict=on`이고 host loopback의 임시 SSH/HTTPS forward만 연다. 값은 운영 IP 계획이 아니다.

```sh
AUTO01_POC_DIR="$(mktemp -d /home/imcherry/auto-01-poc.XXXXXX)"
chmod 700 "$AUTO01_POC_DIR"

"$AUTO01_INSTALLER_DIR/scripts/poc.sh" prepare \
  "$AUTO01_POC_DIR" \
  "$AUTO01_CACHE_DIR/iso/proxmox-ve_9.2-1.iso" \
  22221 28061
"$AUTO01_INSTALLER_DIR/scripts/poc.sh" start "$AUTO01_POC_DIR"
"$AUTO01_INSTALLER_DIR/scripts/poc.sh" verify "$AUTO01_POC_DIR"
```

`prepare`는 임시 root password hash와 SSH key, 실제 answer, 공식 assistant가 만든 ISO, 96 GiB sparse qcow2를 모두 PoC 디렉터리에 만든다. `start`는 target이 regular file이며 block device가 아님을 다시 확인하고, exact NVMe serial을 붙인 target 하나만 전달한다. VM은 `-display none`으로 시작하므로 설치 화면에 사람이 값을 입력할 경로가 없다. CD는 첫 부팅 한 번만 우선하고, installer의 성공 재부팅부터 qcow2를 부팅한다.

`verify`는 설치된 시스템에 SSH가 열릴 때까지 기다린 뒤 다음을 판정한다.

- FQDN과 PVE 9.2 설치 버전
- `/`의 `ext4`와 `/dev/mapper/pve-root`
- `local`, `local-lvm` active
- `pve-cluster`, `pvedaemon`, `pveproxy`, `pvestatd`, SSH active/enabled
- `Asia/Seoul`, UEFI boot, failed unit 없음
- guest disk가 정확히 하나이고 `ID_SERIAL_SHORT`가 fixture와 일치
- loopback forward를 통한 SSH와 HTTPS `200`
- `systemctl reboot` 전후 SSH down/up과 서로 다른 boot ID, 재부팅 후 같은 판정

판정 증거는 정리 전까지 `$AUTO01_POC_DIR/evidence/`에 mode `0600`으로만 남는다. answer 내용과 root hash는 출력하지 않는다.

## 정리와 실패 복구

검증 성공 또는 중단 후 exact PoC 경로를 다시 읽고 정리한다.

```sh
"$AUTO01_INSTALLER_DIR/scripts/poc.sh" cleanup "$AUTO01_POC_DIR"
```

`cleanup`은 다음 조건을 모두 확인해야 동작한다.

1. 실제 경로가 저장소 밖이며 basename이 `auto-01-poc.*`다.
2. 전용 marker 내용이 일치한다.
3. PID가 살아 있으면 QEMU 이름·target qcow2 경로가 모두 일치한다.

그 뒤 guest poweroff를 먼저 시도하고 QEMU 종료를 확인한 다음 PoC 디렉터리 하나를 삭제한다. 삭제 대상에는 VM firmware state, qcow2, 실제 answer, 생성 ISO, SSH key와 evidence가 포함되며 복구할 수 없지만 모두 manifest와 template에서 재생성할 수 있다. checksum을 통과한 원본 ISO와 official assistant cache, container image는 보존한다.

설치가 실패하면 `DONE`이나 merge로 진행하지 않는다. QEMU가 종료됐는지 확인하고, 정리 전 `qemu-launch.log`, `serial.log`, official assistant 오류와 어느 성공 판정이 실패했는지만 기록한다. 로그 전체에는 answer 정보가 섞일 수 있으므로 Git에 넣지 않는다.

## 개발 검증

```sh
"$AUTO01_INSTALLER_DIR/scripts/self-test.sh"
git status --short --ignored infra/proxmox/installer
git ls-files infra/proxmox/installer
```

`self-test.sh`는 모든 script의 `bash -n`·`shellcheck`, template의 Python `tomllib` parse, 잘못된 checksum과 누락 입력의 안전한 실패, scoped ignore를 확인한다. 완료 전에는 official `validate-answer`, 생성 ISO의 safe inspect, 실제 headless 설치와 재부팅, fresh clone에서 위 생성 절차도 별도로 통과해야 한다.

## AUTO-01 검증 기록

검증일은 2026-07-30이다. Fedora workstation의 QEMU 10.2.2, writable `/dev/kvm`, OVMF와 496 GiB의 사전 여유 공간을 확인했다. VM에는 4 vCPU, 8 GiB RAM, 96 GiB sparse qcow2 하나와 virtio NIC 하나를 주고 `-display none`으로 시작했다. QEMU monitor에서도 writable install target은 해당 qcow2 하나였고 host block device 인자는 없었다.

공식 PVE 9.2-1 ISO는 고정 SHA256·byte size와 Trixie/Bookworm release key 서명을 모두 통과했다. 공식 assistant 9.2.7은 렌더링한 answer를 오류 없이 검증했고, 생성 ISO를 `Proxmox VE 9.2-1`, automated installation enabled, fetch mode `iso`로 판정했다.

사람의 설치값 입력 없이 ISO 부팅부터 디스크 부팅까지 완료됐다. 설치 결과는 `pve-manager/9.2.2`, kernel `7.0.2-6-pve`, `/dev/mapper/pve-root`의 `ext4`, `local`과 `local-lvm` active였다. `pve-cluster`, `pvedaemon`, `pveproxy`, `pvestatd`, SSH는 active/enabled였고 failed unit은 없었다. timezone은 `Asia/Seoul`, guest disk는 한 개였으며 NVMe `ID_SERIAL_SHORT`가 exact filter와 일치했다. 격리 network의 loopback forward로 SSH key 로그인과 PVE HTTPS `200`을 확인했다.

그 뒤 guest에서 `systemctl reboot`를 실행해 SSH 실제 명령 실패와 복귀를 관찰했다. reboot 전후 boot ID가 달랐고, 재부팅 후 위 filesystem·storage·service·timezone·disk·SSH·HTTPS 판정을 모두 반복 통과했다.

PoC QEMU PID를 소유 경로와 대조한 뒤 guest poweroff로 종료했다. `/home/imcherry/auto-01-poc.v8XcmD`의 qcow2, 실제 answer, 생성 ISO, OVMF state, 임시 SSH key와 evidence를 삭제했고 PID·host forward·경로 부재를 확인했다. 비민감 원본 ISO와 assistant cache만 보존했으며 정리 후 원본 ISO checksum도 다시 통과했다. 물리 Proxmox와 그 NVMe, Proxmox API/SSH에는 접근하지 않았다.

마지막으로 `--no-local` 새 clone에서 README 순서대로 정적 검사, source 서명/checksum 검증, assistant 버전 확인, 외부 answer 렌더링·공식 검증과 ISO 생성을 다시 수행했다. clone worktree는 무변경이었고, `/home/imcherry/auto-01-poc.0isxb5`의 재현 산출물과 `/home/imcherry/auto-01-fresh.42Mija` clone을 모두 삭제했다.

merge 전 최신 `main`의 OS-01 완료 변경을 작업 브랜치에 통합한 뒤 전체 PoC를 다시 실행했다. `/home/imcherry/auto-01-poc.5rmxYi`의 단일 regular qcow2만 대상으로 공식 answer 검증·자동설치 ISO 생성·headless 무인 설치·디스크 부팅을 반복했고, 위 hostname·PVE 버전·filesystem·storage·service·timezone·단일 disk·SSH·HTTPS 판정을 모두 통과했다. 실제 SSH 명령의 실패와 복귀를 관찰한 재부팅 전후 boot ID는 서로 달랐으며, 재부팅 후 같은 판정을 다시 통과했다. QEMU PID와 경로를 대조해 종료한 뒤 qcow2, 실제 answer, 생성 ISO, OVMF state, 임시 SSH key와 evidence가 든 해당 디렉터리를 삭제했다. PID·host forward·경로 부재 및 보존한 원본 ISO checksum을 다시 확인했다.
