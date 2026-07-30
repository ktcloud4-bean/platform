# OPNsense – Proxmox tagged-only trunk 전환 절차

최초 전환 기록일은 2026-07-31이고, `NET-02R` 영속성 보정·재검증일도 2026-07-31이다. 현재 상태는 **검증 완료**다. 주소·VLAN·장치 역할은 [`docs/ip-plan.md`](../ip-plan.md), 자동화 경계는 [ADR-0008](../adr/0008-opentofu-provider-and-state-boundary.md)을 따른다.

> **역사적 주의:** `NET-02` 당시 런타임 전환은 성공했지만, 이후 읽기 전용 재점검에서 OPNsense 저장 설정과 자동 backup 이력 어디에도 목표 논리 할당이 없었다. 정확히 어떤 호출이 빠졌는지는 남은 증거로 단정할 수 없다. 따라서 최초 절차의 직접 PHP 변경과 일회성 `ifconfig` 삭제는 영속 완료 증거로 인정하지 않으며, 아래에는 `NET-02R`에서 실제 검증한 절차만 둔다.

## 1. 목적과 완료 상태

OPNsense의 Proxmox 직결 부모 포트를 무주소로 유지하고 VLAN 10·20·30·40·50만 통과시키는 tagged-only trunk를 만든다. Proxmox 관리는 tagged 관리 인터페이스를 사용하고, VLAN gateway와 VLAN 간 라우팅은 OPNsense가 담당한다.

`NET-02R`은 정상인 Proxmox 설정을 바꾸지 않고 OPNsense 저장 설정만 보정했다. 방화벽 기본 deny와 bootstrap 허용은 후속 `NET-03`의 범위다.

### 1.1 `NET-02R` 완료 증거

| 계층 | 2026-07-31 확인 결과 |
|---|---|
| 저장 설정 | LAN은 VLAN 10 논리 장치에 연결되고 VLAN 20~50 논리 인터페이스와 gateway가 저장됨; pending assignment 없음 |
| OPNsense 런타임 | 부모 포트 IPv4 없음; VLAN 10~50 및 HOME 주소와 직접 연결 route가 저장 설정과 일치 |
| L2 | 격리된 Proxmox namespace에서 untagged VLAN 10은 ARP neighbor 미생성, tagged VLAN 10~50은 모두 gateway `lladdr` 학습 |
| 관리 경로 | OPNsense·Proxmox strict host key SSH, 각 관리 HTTPS strict TLS, 내부 정방향 DNS 정상 |
| 서비스·정책 경계 | PF enabled, Dnsmasq running, VLAN 20~50의 `NET-03` 사용자 규칙은 추가하지 않음 |
| 재부팅 | OPNsense 26.7.1_1 새 부팅 후 저장 설정·주소·route·관리 경로·L2를 다시 확인 |
| Proxmox 대조군 | `/etc/network/interfaces` 작업 전후 해시 동일, tagged 관리 주소·route 유지, 임시 namespace/veth 제거 확인 |
| 복구 증거 | PiKVM 정상, OPNsense 자동 revision에서 작업 직전 논리 할당을 의미값·해시로 식별, 저장소 밖 `0700/0600` 원본 사본 검증 |
| Git 경계 | 정당한 라이브 차이만 마스킹 snapshot으로 승인한 뒤 일반 drift 검사 `드리프트 없음` |

## 2. 전제조건과 접근 권한

- `docs/backlog.md`에서 선행 작업과 `PVE-LIVE`, `OPNSENSE-LIVE` 잠금을 확인한다.
- OPNsense와 Proxmox 모두 로컬 `known_hosts`를 사용한 strict host key 검증과 공개키 SSH가 성공해야 한다.
- Bitwarden SSH agent는 로컬에서 서명한다. 서버에는 공개키와 서명 증명만 전달되며 private key를 호스트, 명령 인자, 저장소로 복사하지 않는다.
- OPNsense API 입력은 권한이 제한된 `infra/opnsense/.env`에서 읽고, 원문 credential을 출력하지 않는다.
- PiKVM에서 현재 OPNsense 화면과 콘솔 입력을 확인하고 로컬 복구 로그인이 가능해야 한다.
- 작업 전 원본은 저장소 밖 임의 디렉터리에 보관한다. 디렉터리는 `0700`, OPNsense 원본 설정과 Proxmox 네트워크 사본은 `0600`이어야 한다.
- 정확한 주소와 VLAN 값은 `docs/ip-plan.md`에서 읽는다. 이 runbook의 과거 값이나 셸 기록을 단일 원본으로 사용하지 않는다.

## 3. 예상 영향과 공유 잠금

- 작업자는 계획부터 적용·재부팅·drift 승인까지 두 라이브 잠금을 계속 소유한다.
- OPNsense LAN 논리 장치 재연결 시 SSH·HTTPS가 끊길 수 있다. API timeout은 성공이나 실패 판정이 아니다.
- `NET-02R`에서는 Proxmox 영속 설정을 변경하지 않는다. 읽기 검증과 제거 가능한 namespace/veth 기반 L2 시험만 수행한다.
- WAN, HOME, 방화벽 사용자 정책, DHCP 범위, DNS record는 변경하지 않는다.
- OPNsense 원본 backup에는 사용자 hash, TOTP, API credential, DNS token과 TLS private key가 있다고 가정한다.

## 4. 검증된 실행 순서

### 4.1 적용 전 기준선과 backup

1. 두 호스트의 strict SSH와 관리 HTTPS strict TLS를 확인한다.
2. OPNsense 일반 drift 검사와 `docs/ip-plan.md` 목표 대조를 **별도로** 수행한다. drift 없음은 저장 설정과 Git snapshot의 일치만 뜻한다.
3. OPNsense 원본 설정과 Proxmox `/etc/network/interfaces`를 저장소 밖에 복사하고 mode·SHA-256을 기록한다. 원문은 터미널에 출력하지 않는다.
4. OPNsense 저장 설정, interface 주소, 직접 연결 route와 pending assignment를 읽기 전용으로 확인한다.
5. Proxmox 영속 설정 해시, VLAN-aware bridge, tagged 관리 인터페이스와 route를 대조군으로 기록한다.
6. 설치된 `OPNsense/Interfaces/Api/AssignmentController.php`에서 현재 버전의 `add_item`, `set_item`, `reconfigure` 동작을 확인한다. 다른 버전의 API 동작을 추정하지 않는다.

### 4.2 VLAN 20~50 논리 인터페이스와 gateway 저장

1. VLAN 장치 자체가 이미 부모 포트와 올바른 tag로 저장돼 있는지 먼저 확인한다. 다르면 이 절차를 중단하고 영향 범위를 다시 계획한다.
2. `POST /api/interfaces/assignment/add_item`으로 필요한 논리 인터페이스를 하나씩 추가한다. 응답에서 실제 생성된 식별자를 확인한 뒤 다음 단계로 간다.
3. Assignment API는 논리 장치 연결만 소유하므로 static IPv4 필드는 설치본의 config library로 저장한다.
   - `config.inc`와 `util.inc`를 모두 include한다.
   - 현재 장치·주소·prefix가 예상 precondition과 맞을 때만 `enable`, `ipaddr`, `subnet`을 변경한다.
   - 허용한 필드 외에는 건드리지 않고 `write_config()`로 revision을 남긴다.
   - `config.inc`만 include하면 `write_config()` 경로에서 `shell_safe()`가 없어 저장 전에 실패할 수 있다. 이 실패를 재시도 성공으로 추정하지 말고 저장 설정을 다시 읽는다.
4. 각 논리 인터페이스에 `configctl interface reconfigure <식별자>`를 실행한 뒤 주소와 직접 연결 route를 독립적으로 확인한다.
5. PF를 reload하고 기존 관리 규칙이 유지됐으며 VLAN 20~50 사용자 정책이 추가되지 않았는지 확인한다.

### 4.3 LAN을 VLAN 10으로 영속 재연결

1. `POST /api/interfaces/assignment/set_item/lan`으로 목표 장치를 stage한다.
2. `/tmp/.interfaces.todo`에서 `lan`의 `pending_action=relink`와 목표 장치를 확인한다. 이 시점은 아직 영속 완료가 아니다.
3. `POST /api/interfaces/assignment/reconfigure`를 한 번 호출한다. 설치본 controller는 interface apply 성공 후 저장 설정을 갱신하고 pending 목록을 지운 다음 PF reload를 예약한다.
4. API 응답과 무관하게 아래를 다시 읽는다.
   - 저장된 LAN 장치와 주소
   - pending assignment가 비어 있는지
   - 부모 포트가 무주소인지
   - VLAN 주소와 직접 연결 route

일회성 `ifconfig ... delete`는 런타임 응급 조치일 뿐 저장 증거가 아니다. 저장 설정이 부모 포트를 가리키는 상태에서 이를 완료 절차로 사용하지 않는다.

### 4.4 관리·정책·L2 검증

1. OPNsense와 Proxmox SSH, 관리 HTTPS strict TLS, canonical hostname DNS를 확인한다.
2. PF enabled와 Dnsmasq running을 확인한다. PF의 기존 사용자 규칙이 LAN/HOME 범위에만 있고 `NET-03` 정책이 섞이지 않았는지 확인한다.
3. Proxmox 영속 설정 해시와 tagged 관리 interface·route가 적용 전과 같은지 확인한다.
4. 격리 namespace와 고유한 veth 이름을 만들기 전에 같은 이름의 기존 자원이 없는지 확인한다.
5. host 쪽 veth를 VLAN-aware bridge에 연결하고 시험할 VLAN membership만 명시한다. namespace 안에서 `docs/ip-plan.md`의 실험·이전용 주소를 일시 사용한다.
6. `ping`으로 ARP resolution을 유도한 뒤 `ip neigh`의 `lladdr` 존재 여부를 판정한다.
   - untagged 관리망: `lladdr`가 생기면 실패다.
   - tagged VLAN 10~50: 각 gateway의 `lladdr`가 모두 생겨야 한다. VLAN 20~50은 아직 PF 허용 규칙이 없으므로 ICMP 응답 여부가 아니라 L2 neighbor를 본다.
7. namespace와 veth를 제거하고 이름 부재를 다시 확인한다. Proxmox 영속 설정 해시도 다시 확인한다.

시험 도구가 있는지 먼저 확인한다. `command not found`의 exit code를 네트워크 무응답으로 해석하지 않는다.

### 4.5 재부팅과 drift 승인

1. 이 작업에서 영속 설정을 변경한 OPNsense만 `configctl system reboot`로 재부팅한다.
2. 원격 경로가 1분 안에 돌아오지 않으면 추가 쓰기와 재부팅을 멈추고 PiKVM에서 boot 상태, interface 주소와 로그인 prompt를 확인한다.
3. 콘솔이 정상 boot와 목표 주소를 보여 주면 즉시 rollback하지 않고 원격 경로를 읽기 전용으로 다시 확인한다. `NET-02R`에서는 원격 관리 복귀가 1분을 넘었지만 PiKVM에서 정상 boot를 확인했고 이후 SSH·HTTPS가 복구됐다.
4. 새 boot time을 확인하고 4.3~4.4의 저장 설정·런타임·관리·L2 검증을 반복한다.
5. 라이브 차이가 의도한 논리 할당과 gateway뿐인지 drift diff를 검토한다. 그때만 `check-drift.sh --update`로 마스킹 snapshot을 승인하고 일반 검사를 다시 실행한다.

Proxmox 영속 설정을 바꾼 새로운 전체 trunk 전환이라면 Proxmox도 콘솔 경로를 확보한 뒤 재부팅 검증해야 한다. `NET-02R`은 Proxmox를 변경하지 않았고 해시·런타임을 전후 대조했으므로 추가 재부팅하지 않았다.

## 5. 중단 조건

- OOB 콘솔 또는 어느 한쪽 작업 전 backup이 확보되지 않음
- 저장 설정·런타임·`docs/ip-plan.md` 중 하나라도 예상 precondition과 다름
- API/CLI 응답 뒤 저장 설정을 독립적으로 재조회할 수 없음
- Proxmox 영속 설정 해시가 예상하지 않게 바뀜
- untagged에서 ARP neighbor가 생기거나 tagged VLAN 하나라도 neighbor를 만들지 못함
- 임시 namespace/veth가 제거되지 않음
- 재부팅 후 콘솔이 boot 실패, 잘못된 interface 또는 잘못된 주소를 표시함
- strict SSH/TLS, DNS, PF 또는 Dnsmasq가 복구되지 않음

중단하면 추가 변경을 하지 않는다. API timeout이나 SSH 단절만 보고 동일 요청을 반복하지 않는다.

## 6. 실패 시 원상복구

### 6.1 OPNsense

1. PiKVM 콘솔에서 현재 interface와 주소를 먼저 확인한다.
2. 관리 경로만 임시 복구해야 하면 console의 interface assignment와 address 메뉴로 LAN을 작업 전 물리 장치·주소로 되돌린다.
3. 전체 설정 rollback은 console의 configuration backup restore 기능으로 `/conf/backup`의 작업 전 revision을 선택한다. 저장소 밖 원본 backup은 관리 경로가 복구된 뒤 별도 검증·import하는 2차 복구본이다.
4. 재구성 후 저장 설정, 런타임, 관리 경로와 drift를 다시 확인한다.

### 6.2 Proxmox

`NET-02R`은 Proxmox 영속 설정을 바꾸지 않으므로 우선 임시 namespace/veth만 정확한 이름으로 제거한다. 향후 전체 전환에서 영속 파일을 바꿨다면 PiKVM에서 작업 전 사본을 복원하고 `ifreload -a` 또는 정상 reboot로 검증한다. 원격 전원 투입 경로가 없으므로 power off하지 않는다.

## 7. 시크릿과 보존하면 안 되는 출력

- Git에는 `infra/opnsense/scripts/normalize.py`로 마스킹한 `infra/opnsense/config.xml`만 둔다. 이 파일은 apply 입력이 아니다.
- 원본 OPNsense 설정, API key/secret, root credential, TOTP, DNS token, TLS private key와 Proxmox credential은 커밋하지 않는다.
- Bitwarden SSH agent의 private key를 호스트로 복사하거나 agent forwarding으로 불필요하게 노출하지 않는다.
- WAN 공인 주소와 SSH/TLS fingerprint는 완료 보고·커밋에 그대로 넣지 않는다.
- 저장소 밖 backup은 복구 필요가 끝났음을 사람이 확인한 뒤 안전하게 폐기한다.
