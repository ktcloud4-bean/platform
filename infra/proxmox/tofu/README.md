# Proxmox VM · OpenTofu

검증일: 2026-07-31 (`VM-01` 라이브 적용). 선택 이유·대안·재검토 조건은 [ADR-0008](../../../docs/adr/0008-opentofu-provider-and-state-boundary.md)이 소유한다.

## 지금 이 구성이 소유하는 것

`VM-01`이 2026-07-31에 VM 5대를 한 번의 apply로 만들었다. state에는 리소스 5개가 있고 `tofu plan`은 무변경이다.

gate 값은 저장소 밖 변수 파일로 주입한다. gate를 비우고 `tofu plan`을 돌리면 여전히 리소스 0개와 `blocked_by`가 나온다. 이것이 선행 조건을 잃었을 때의 정상 동작이다.

```sh
tofu plan                       # gate 값 없이: 리소스 0개 + blocked_by
tofu plan -var-file=<저장소 밖>  # 현재 운영 상태: No changes
```

라이브에서 확정한 gate 값은 다음과 같다. 값 자체는 `terraform.tfvars.example`이 형식만 보여 주고, 실제 파일은 저장소 밖에 mode `0600`으로 둔다.

| 변수 | 값 | 라이브 확인 근거 |
|---|---|---|
| `vm_template_id` | `9000` | `qm config 9000`의 `template: 1` |
| `vlan_trunk_ready` | `true` | `vmbr0` VLAN-aware·`bridge-vids 10 20 30 40 50`, OPNsense VLAN gateway와 `NET-03` PF 24개 |
| `vm_bios` / `vm_machine` | `seabios` / `pc` | template은 두 필드를 생략한다. 설치본 `QemuServer.pm`의 `bios` 기본값이 `seabios`, `qm showcmd 9000`의 실측 machine이 `pc+pve0`(i440fx) |
| `cloud_init_interface` | `ide2` | `qm config 9000`의 `ide2: local-lvm:vm-9000-cloudinit` |
| `agent_enabled` | `true` | `qm config 9000`의 `agent: enabled=1`, 게스트 `qemu-guest-agent` active/enabled |
| `proxmox_insecure` | `false` | 8006 strict TLS 검증 성공(`ssl_verify_result=0`) |

생략된 template 필드를 기본값이라고 단정하지 않는다. 설치 버전의 schema 기본값과 `qm showcmd`의 실행 계약을 매번 다시 확인한다.

## 도구와 버전

| 항목 | 값 | 고정 위치 |
|---|---|---|
| OpenTofu | 1.12 계열 (1.12.5로 검증) | `versions.tf`의 `required_version` |
| provider | `bpg/proxmox` 0.111.1 | `versions.tf`의 `required_providers` |
| 대상 | Proxmox VE 9.x | provider가 명시 지원 |

버전은 범위가 아니라 정확한 값으로 고정한다. 갱신은 사람이 릴리스 노트를 읽고 plan을 확인한 뒤 올린다.

루트 `.gitignore`가 `.terraform.lock.hcl`을 제외하므로 provider 바이너리 해시는 고정되지 않는다. 버전 재현성의 근거는 `required_providers`의 한 줄뿐이다.

## 자격증명

토큰 값을 **커밋하지 않는다.** 채팅·이슈·커밋 메시지·plan·state·`*.tfvars`·명령 인자에도 남기지 않는다.

값은 `~/secrets/ktcloud4-bean/proxmox/env`에 두고 mode `0600`으로 유지한다. 저장소 안에는 두지 않는다. `.gitignore`는 커밋만 막을 뿐이고 `git clean -xfd`와 worktree 정리는 저장소 안 파일을 지운다. `infra/proxmox/acme`와 같은 규약이다.

```sh
mkdir -p ~/secrets/ktcloud4-bean/proxmox
cp infra/proxmox/.env.example ~/secrets/ktcloud4-bean/proxmox/env
chmod 600 ~/secrets/ktcloud4-bean/proxmox/env
# PROXMOX_VE_API_TOKEN=<user>@<realm>!<token-id>=<uuid> 한 줄만 채운다
```

파일은 셸로 `source`하지 않는다. 해당 줄만 파싱해 OpenTofu 프로세스 환경으로만 넘긴다.

```sh
PROXMOX_VE_API_TOKEN="$(grep -E '^PROXMOX_VE_API_TOKEN=' ~/secrets/ktcloud4-bean/proxmox/env | cut -d= -f2-)" \
  tofu plan
```

- `PROXMOX_VE_API_TOKEN` 하나면 된다.
- 토큰이 없으면 `plan`이 `Unable to create Proxmox VE API credentials`로 멈춘다. 이것이 정상 동작이다.
- provider에 `ssh` 블록을 두지 않았다. snippet 업로드나 로컬 파일 import를 쓰지 않으므로 SSH 경로가 필요 없고, 열지 않으면 provider가 호스트 파일시스템에 닿지 못한다.
- `.gitignore`는 커밋만 막는다. `git clean -xfd`는 이 파일을 지운다. 지웠으면 토큰을 다시 발급한다.

### 전용 주체와 최소 권한

`Administrator`나 `root@pam` 토큰을 쓰지 않는다. `VM-01`이 만든 주체는 다음과 같다.

| 항목 | 값 |
|---|---|
| role | `OpenTofuVM` (custom) |
| user | `opentofu@pve` |
| ACL | `/` → `OpenTofuVM`, propagate |
| token | `opentofu@pve!vm01`, `privsep=0` |

권한은 provider 문서의 role 예시가 아니라 이 구성이 실제로 요구하는 것만 담는다. 설치본 `PVE/API2/Qemu.pm`의 `$check_vm_modify_config_perm`에서 설정 항목별로 확인한 값이다.

```text
VM.Allocate VM.Audit VM.Clone
VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk
VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options
VM.PowerMgmt VM.GuestAgent.Audit
Datastore.Audit Datastore.AllocateSpace
Sys.Audit Sys.Modify
```

`Sys.Modify`는 `startup` 하나 때문에 필요하다. 그 항목만 `check_full($authuser, "/", ['Sys.Modify'])`를 요구한다. 이 권한은 노드 네트워크 설정까지 열어 주므로, `startup`을 포기하면 함께 뺄 수 있다는 것을 알고 남긴 선택이다.

`Permissions.Modify`·`User.Modify`·`Realm.*`·`Sys.Console`·`Sys.PowerMgmt`·`VM.Migrate`·`VM.Snapshot`·`Datastore.Allocate`는 주지 않는다.

폐기는 역순으로 한다.

```sh
pveum user token remove opentofu@pve vm01
pveum acl delete / --user opentofu@pve --role OpenTofuVM
pveum user delete opentofu@pve
pveum role delete OpenTofuVM
```

`initialization.upgrade`와 `cpu.affinity`처럼 `root@pam`만 쓸 수 있는 항목은 이 구성에서 쓰지 않거나 꺼 두었다. API token으로 apply할 수 있게 하기 위한 선택이다.

## TLS gate

`PVE-ACME-01` 완료로 `ip-plan.md`의 canonical FQDN(`proxmox-01.imcherry5778.xyz`)에 Proxmox 내장 ACME Let's Encrypt 공인 인증서가 설치되었으며, system trust store 기반으로 HTTPS 8006 strict TLS 검증이 통과되었다.

따라서 `proxmox_insecure` 기본값은 `false`로 고정되어 있으며 provider가 서버 인증서와 hostname을 엄격히 검증한다. 소유권과 대안은 [ADR-0009](../../../docs/adr/0009-proxmox-native-acme-management-tls.md)을 따른다.

## state

로컬 backend다. 파일은 `terraform.tfstate`이며 Git에서 제외된다.

- **state에는 자원 속성이 평문으로 남는다.** cloud-init 사용자 이름, SSH 공개키, 주소가 들어간다.
- **복구 지점:** `VM-01`이 2026-07-31에 처음 apply했다. 그 이후 apply마다 직후의 `terraform.tfstate`를 저장소 밖 mode `0600` 사본으로 두고 SHA-256만 작업 기록에 남긴다.
- **state를 잃으면** VM은 살아 있는데 소유권만 사라진다. 아래 import로 되찾는다.

### `S3-01` 제자리 이름 전환 계약

전환 전 state 주소는 `module.service_vm["minio-01"]`였고, `S3-01` 완료 뒤 현재
주소는 `module.service_vm["object-01"]`이다. 라이브 VMID는 계속 151이며
[ADR-0010](../../../docs/adr/0010-seaweedfs-local-s3.md)의 `moved` 선언으로 새 VM을
만들거나 기존 VM·디스크를 교체하지 않았다.

`S3-01` 작업자는 `TOFU-STATE`와 `PVE-LIVE`를 함께 소유하고 변경 직전 state를
저장소 밖 mode `0600`으로 복사해 SHA-256을 기록한다. `locals.tf`의 카탈로그 키 변경과
동시에 OpenTofu `moved` 선언으로 기존 모듈 주소를 새 주소에 연결한다. refresh를 포함한
plan에서 create, destroy, replace가 하나라도 나오거나 VMID·디스크 identity가 달라지면
apply하지 않고 구성과 state 복구 사본으로 돌아간다. `tofu state rm`이나 수동 import로
정상 state를 우회하지 않는다.

2026-07-31 적용 전 state는 저장소 밖
`/home/imcherry/.local/state-backups/s3-01-20260731-7OsvqE/terraform.tfstate.pre-change`에
mode `0600`으로 보관했고 SHA-256은
`84abde409604682de797c68163f97770e6ffbecff2bf8c4fe4de6aafe4f38a51`이다. 적용은
`0 add, 1 change, 0 destroy`(VM name·description만 변경)였고, 최신 refresh plan은
다섯 VM 모두 `no-op`이다. VMID 151, MAC `BC:24:11:3C:CD:77`, VLAN 50, 주소
`10.10.50.20`, boot disk `local-lvm:vm-151-disk-0` 200 GiB는 적용 전후 불변이다.

복구가 필요하면 state 원문을 편집하거나 `state rm`·정상 state import를 쓰지 않는다.
위 사본을 별도 안전 위치에서 backend에 복원한 뒤, `moved` 선언을 유지한 refresh plan이
create/destroy/replace 0인지 먼저 확인한다. 그 뒤에만 이 전환이 만든 VM 이름·DNS·S3
리소스를 정확한 대상으로 되돌린다. 적용 후 state 주소, Proxmox VMID·disk, 게스트
주소·hostname을 대조하고 재부팅 후에도 같음을 확인했으며, 그 증거 뒤에
`ip-plan.md`와 Unbound host override를 전환했다.

## import 경계

이 state가 소유하는 것은 **자신이 만든 VM 5대와 그 VM이 만든 디스크·cloud-init 디스크뿐**이다.

소유하지 않는 것 — `resource`로 선언하지도, `import`하지도 않는다.

| 자원 | 소유자 |
|---|---|
| Proxmox 노드 | `PVE-01` |
| Proxmox ACME account·DNS plugin·관리 인증서 | `PVE-ACME-01` |
| datastore `local`·`local-lvm` | `PVE-01` |
| bridge와 VLAN 인터페이스 | `PVE-01` → `NET-02` |
| cloud-init template | `OS-01` |
| OPNsense의 모든 자원 | `REC-01`·`NET-02`·`NET-03` |

`data` source도 쓰지 않는다. 위 자원은 전부 변수로 이름만 참조한다. 그래서 이 구성은 신규 생성 plan을 API 조회 없이 계획할 수 있고, 잘못된 refresh가 기존 자산을 건드릴 여지가 없다.

state를 잃었을 때만, 그리고 **이 구성이 실제로 만들었던 VM에 한해** import한다.

```sh
tofu import 'module.service_vm["k3s-01"].proxmox_virtual_environment_vm.this' proxmox-01/120
```

import ID 형식은 `<node>/<vmid>`다. 각 VM의 값은 `module.service_vm[*].import_id` output에 있다. import 후에는 반드시 `plan`이 "no changes"인지 확인한다. 차이가 나면 import가 아니라 구성이 틀린 것이다.

## VM 계약의 출처

이 디렉터리는 값을 소유하지 않는다. 전부 문서에서 온다.

| 값 | 단일 원본 |
|---|---|
| vCPU · RAM · 디스크 크기, 공통 VM 옵션 | [`docs/capacity-plan.md`](../../../docs/capacity-plan.md) |
| canonical 이름 · VLAN · 주소 · gateway · 도메인 | [`docs/ip-plan.md`](../../../docs/ip-plan.md) |
| VM 분리 근거와 역할 | [`docs/architecture.md`](../../../docs/architecture.md) |

구현은 `locals.tf`의 `vm_catalog` 한 곳에 모여 있다. 문서 값이 바뀌면 그 블록을 고치고 plan으로 차이를 본다.

`main.tf`의 `check` 블록이 카탈로그를 문서 기준과 대조한다. VMID 중복·규칙 위반, VLAN과 주소 불일치, capacity 경고선 초과를 plan에서 경고로 드러낸다.

### 디스크 크기 단위

provider 문서는 `size`를 "gigabytes"라고 쓰지만 Proxmox는 이 값을 GiB로 다룬다. `size = 200`은 200 GiB이며 `capacity-plan.md`의 값과 그대로 대응한다.

### VMID 규칙

`100 + VLAN ID + 해당 VLAN 안의 순번`. VMID만 보고 VM의 신뢰 경계를 알 수 있게 한 것이며 주소 규칙과는 별개다. VLAN당 10대까지만 유효하다.

## `VM-01`이 gate를 열기 전에 확인할 것

두 생성 gate를 열면 5대가 즉시 생성 대상이 된다. 열기 전에 다음을 실제 값으로 확인한다.

1. **관리 API TLS** — `PVE-ACME-01 DONE`, canonical FQDN의 인증서 검증 성공, `proxmox_insecure=false`를 확인한다.
2. **`OS-01` template VMID** — Proxmox에서 실제 template의 VMID를 읽어 `vm_template_id`에 넣는다. 추측하지 않는다.
3. **template의 `bios`·`machine`·cloud-init drive 위치** — `vm_bios`·`vm_machine`·`cloud_init_interface`가 template과 다르면 clone이 template 설정을 덮어쓴다. 기본값은 `seabios`·`pc`·`ide2`다.
4. **template의 qemu-guest-agent** — 부팅 시 자동 기동하지 않으면 `agent_enabled = false`로 둔다. agent 없이 `true`이면 생성·refresh·shutdown이 전부 timeout된다.
5. **VLAN trunk** — `vmbr0`가 VLAN-aware이고 목표 VLAN gateway와 기본 deny 정책이 살아 있어야 `vlan_trunk_ready = true`다. `NET-02R`·`NET-03` 완료로 현재는 tagged-only trunk이며 `bridge-vids`에 VLAN 10·20·30·40·50이 있다.
6. **capacity 정지 기준** — `capacity-plan.md`의 재측정 절차를 돌려 어떤 지표도 정지 구간이 아닌지 확인한다.
7. **SSH 공개키** — `ssh_public_keys`가 비면 생성 후 게스트에 들어갈 방법이 없다. 모듈이 이를 `precondition`으로 막는다.

## 검증 절차

```sh
tofu fmt -check -recursive
tofu init
tofu validate
tofu plan                      # gate 닫힘: 0개 리소스와 blocked_by
```

계약만 확인하고 싶을 때는 gate를 임시로 연 plan을 쓸 수 있다. **이 plan은 대조 전용이며 apply하면 안 된다.** template VMID가 실재하지 않으면 clone 단계에서 실패한다.

```sh
tofu plan \
  -var 'vm_template_id=<실재하지 않는 자리표시자>' \
  -var 'vlan_trunk_ready=true' \
  -var 'ssh_public_keys=["ssh-ed25519 AAAA... placeholder"]'
```

plan 파일(`*.tfplan`)과 `*.tfvars`는 이 디렉터리의 `.gitignore`가 막는다. plan 파일에는 변수값이 그대로 들어가므로 공유하지 않는다.
