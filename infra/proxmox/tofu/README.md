# Proxmox VM · OpenTofu

검증일: 2026-07-30. 선택 이유·대안·재검토 조건은 [ADR-0008](../../../docs/adr/0008-opentofu-provider-and-state-boundary.md)이 소유한다.

## 지금 이 구성이 만드는 것

**아무것도 만들지 않는다.** 기본값으로 `tofu plan`을 돌리면 리소스가 0개다.

VM 5대는 `OS-01`의 template, `PVE-ACME-01`의 strict TLS와 `NET-02`·`NET-03`의 VLAN이 모두 끝난 뒤 `VM-01`이 한 번의 apply로 만든다. 그때까지 이 구성은 계획만 검증할 수 있다.

```sh
tofu plan            # blocked_by 출력으로 무엇이 막고 있는지 확인
```

## 도구와 버전

| 항목 | 값 | 고정 위치 |
|---|---|---|
| OpenTofu | 1.12 계열 (1.12.5로 검증) | `versions.tf`의 `required_version` |
| provider | `bpg/proxmox` 0.111.1 | `versions.tf`의 `required_providers` |
| 대상 | Proxmox VE 9.x | provider가 명시 지원 |

버전은 범위가 아니라 정확한 값으로 고정한다. 갱신은 사람이 릴리스 노트를 읽고 plan을 확인한 뒤 올린다.

루트 `.gitignore`가 `.terraform.lock.hcl`을 제외하므로 provider 바이너리 해시는 고정되지 않는다. 버전 재현성의 근거는 `required_providers`의 한 줄뿐이다.

## 자격증명

값을 이 저장소에 두지 않는다. 채팅·이슈·커밋 메시지에도 남기지 않는다.

```sh
export PROXMOX_VE_API_TOKEN='<user>@<realm>!<token-id>=<secret>'
```

- `PROXMOX_VE_API_TOKEN` 하나면 된다. `.tfvars`에 넣지 않는다.
- 토큰이 없으면 `plan`이 `Unable to create Proxmox VE API credentials`로 멈춘다. 이것이 정상 동작이다.
- provider에 `ssh` 블록을 두지 않았다. snippet 업로드나 로컬 파일 import를 쓰지 않으므로 SSH 경로가 필요 없고, 열지 않으면 provider가 호스트 파일시스템에 닿지 못한다.
- 토큰은 필요한 권한만 준다. `Administrator`나 `root@pam` 토큰을 쓰지 않는다. 필요한 권한 목록은 provider 문서의 role 예시를 그대로 쓰지 말고 실제 plan이 요구하는 것으로 좁힌다.

`initialization.upgrade`와 `cpu.affinity`처럼 `root@pam`만 쓸 수 있는 항목은 이 구성에서 쓰지 않거나 꺼 두었다. API token으로 apply할 수 있게 하기 위한 선택이다.

## TLS gate

`PVE-ACME-01` 완료로 `ip-plan.md`의 canonical FQDN(`proxmox-01.imcherry5778.xyz`)에 Proxmox 내장 ACME Let's Encrypt 공인 인증서가 설치되었으며, system trust store 기반으로 HTTPS 8006 strict TLS 검증이 통과되었다.

따라서 `proxmox_insecure` 기본값은 `false`로 고정되어 있으며 provider가 서버 인증서와 hostname을 엄격히 검증한다. 소유권과 대안은 [ADR-0009](../../../docs/adr/0009-proxmox-native-acme-management-tls.md)을 따른다.

## state

로컬 backend다. 파일은 `terraform.tfstate`이며 Git에서 제외된다.

- **state에는 자원 속성이 평문으로 남는다.** cloud-init 사용자 이름, SSH 공개키, 주소가 들어간다.
- **복구 지점:** `VM-01` 전까지 state에는 리소스가 없다. 즉 지금 잃을 것이 없고, 파일이 없는 상태가 정상이다. `VM-01`이 처음 apply한 뒤부터는 apply 직후의 `terraform.tfstate`를 저장소 밖에 사본으로 둔다.
- **state를 잃으면** VM은 살아 있는데 소유권만 사라진다. 아래 import로 되찾는다.

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
5. **VLAN trunk** — `vmbr0`가 VLAN-aware이고 목표 VLAN gateway와 기본 deny 정책이 살아 있어야 `vlan_trunk_ready = true`다. 현재 `vmbr0`는 Phase 1 untagged이므로 VLAN tag를 붙여도 통신하지 않는다.
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
