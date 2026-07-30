# ADR-0008: OpenTofu provider와 state 경계

- 상태: `Accepted`
- 날짜: 2026-07-30
- 관련 작업: `IAC-01`, `VM-01`, `OS-01`, `NET-03`, `NETBOX-03`

## 배경

Proxmox VM 계층은 OpenTofu가 소유하기로 이미 정해져 있다([ADR-0001](0001-proxmox-bootstrap-reproducibility.md)). 남은 것은 그 소유를 어떻게 구현하느냐다. provider 선택, 인증 방식, state 보관 위치와 "state가 어디까지 소유하는가"는 나중에 바꾸기 비싼 결정이다.

특히 위험한 것은 경계다. Proxmox 노드, datastore, bridge는 OpenTofu가 만들지 않았는데도 provider가 다룰 수 있는 자원이다. 이것을 state에 넣으면 `destroy` 한 번이 유일한 물리 노드의 스토리지나 관리 경로를 지운다. 반대로 state에 아무 경계도 문서화하지 않으면 다음 작업자가 같은 실수를 반복한다.

또 VM 생성은 아직 불가능하다. OS-01의 template과 NET-03의 VLAN이 없다. 구성만 만들어 두고 "준비됐다"고 표시하면 실제로는 apply가 실패하거나, 더 나쁘게는 VLAN이 동작하지 않는 VM 5대가 생긴다.

## 결정

**provider는 `bpg/proxmox`를 쓰고 패치 버전까지 정확히 고정한다.** 이 provider만 Proxmox VE 9.x를 명시적으로 지원 대상으로 선언하며, 안정 릴리스를 낸다. 0.x 계열이라 minor 갱신에 호환성 파괴가 들어갈 수 있으므로 범위 지정(`~>`)을 쓰지 않는다.

**인증은 API token을 환경변수로만 주입한다.** 토큰 값, 비밀번호, ticket, SSH private key는 저장소·state·plan 파일 어디에도 두지 않는다. provider의 `ssh` 블록은 두지 않는다. snippet 업로드와 로컬 파일 import를 쓰지 않으면 SSH가 필요 없고, 열지 않으면 provider가 Proxmox 호스트 파일시스템에 접근할 수 없다.

**state는 로컬 backend를 쓰고 저장소 밖에 백업한다.** 원격 backend의 후보인 MinIO는 아직 존재하지 않고, 그 MinIO를 만드는 것이 이 state가 만들 VM이다. 순환 의존을 만들지 않는다.

**state는 자신이 만든 VM만 소유한다.** 노드, datastore, bridge, VLAN 인터페이스, OS-01 template과 OPNsense의 모든 자원은 변수로 참조만 하고 `resource`로 선언하지도 `import`하지도 않는다. 이 자원들의 수명주기는 각각 PVE-01, NET-02, OS-01, OPNsense 작업이 소유한다.

**선행 조건이 충족되지 않으면 VM을 아예 선언하지 않는다.** template VMID와 VLAN 준비 여부를 gate 변수로 두고, 하나라도 닫혀 있으면 리소스를 0개 계획한다. 존재하지 않는 자원을 있는 것처럼 꾸미는 대신 무엇이 막고 있는지를 plan 출력으로 드러낸다.

## 검토한 대안

- **`Telmate/proxmox` provider:** 오래되고 널리 쓰이지만 최근 릴리스가 release candidate에 머물러 있다. 유일한 물리 노드를 다루는 계층에 rc를 고정하지 않는다.
- **provider 버전을 `~>`로 열어 두기:** 보안 패치를 자동으로 받지만, 0.x provider에서는 minor 갱신이 schema를 바꿔 계획하지 않은 VM 재생성을 만들 수 있다. 갱신은 사람이 plan을 보고 올린다.
- **username·password 인증:** 설정이 가장 간단하지만 개별 폐기가 불가능하고 권한을 좁힐 수 없다. 다만 일부 API가 `root@pam`을 요구하므로 예외적으로 필요한 순간이 올 수 있고, 그때는 그 작업만 한시적으로 password 인증을 쓴다.
- **처음부터 원격 state backend:** 잠금과 공유에는 유리하지만 착지점인 MinIO가 이 state의 산출물이다. 부트스트랩 순환을 만든다.
- **기존 노드·datastore·bridge를 import해 전부 선언형으로:** 드리프트를 더 많이 잡을 수 있지만, 유일한 물리 노드의 스토리지와 관리 경로를 `tofu destroy` 사정권에 넣는다. 이 저장소는 베어메탈을 자동 교정하지 않기로 이미 정했다.
- **Ansible로 VM까지 생성:** 도구 수가 줄지만 VM의 목표 상태와 드리프트를 state로 표현하지 못한다.

## 결과

- provider 갱신은 자동으로 오지 않는다. 사람이 릴리스 노트를 읽고 올린다.
- state 파일은 Git 밖에서 사람이 지켜야 한다. 유실하면 VM은 살아 있는데 소유권이 사라지고, `import`로 되찾아야 한다.
- 노드·datastore·bridge의 드리프트는 이 state가 탐지하지 못한다. 그 계층의 감시는 각 작업이 따로 소유한다.
- OS-01과 NET-03이 끝나기 전까지 이 구성은 아무것도 만들지 않는다. `VM-01`은 gate를 열기 전에 두 선행의 실제 결과값을 확인해야 한다.
- 루트 `.gitignore`가 `.terraform.lock.hcl`을 제외하므로 provider 바이너리의 해시 고정이 없다. 버전 재현성의 근거는 `required_providers`의 정확한 버전 한 줄뿐이다.

## 재검토 조건

- `MINIO-01`과 `VAULT-02`가 끝나 순환 의존 없이 원격 state와 잠금을 둘 수 있다.
- 두 번째 사람이 같은 state에 plan/apply를 실행해야 한다.
- provider가 1.0에 도달하거나 Proxmox VE의 major 버전이 올라간다.
- `NETBOX-03`이 주소·인벤토리의 단일 원본을 NetBox로 옮긴다.
- 공급망 정책(`SIGN-01`·`SCAN-01`)이 lock 파일 커밋을 요구한다.
