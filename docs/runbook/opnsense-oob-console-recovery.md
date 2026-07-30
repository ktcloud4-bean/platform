# OPNsense OOB 콘솔 복구

검증일: 2026-07-30. 장치와 주소는 `docs/ip-plan.md`가 소유한다.

## 목적

네트워크 관리 경로(GUI·SSH·API)를 잃었을 때 OOB 콘솔로 OPNsense를 복구한다. 인터페이스·VLAN·방화벽을 바꾸는 작업은 이 경로가 살아 있음을 확인한 뒤에 시작한다.

## 전제와 접근 권한

- OOB 콘솔이 OPNsense와 Proxmox에 물리 연결돼 있고 채널을 원격 전환할 수 있다. 접속 주소와 채널 매핑은 운영자가 저장소 밖에 보관한다.
- OPNsense root 비밀번호를 알고 있다. `disableconsolemenu`가 켜져 있어 콘솔 메뉴 앞에 로그인이 있다.
- OOB는 HOME 네트워크에 있으며 랩 VLAN 밖이다.
- 변경 전 원본 설정을 저장소 밖에 `0600`으로 보관한다.

## 예상 영향과 공유 잠금

- `OPNSENSE-LIVE`를 단독으로 소유한다.
- drill 중 랩 관리 접근(OPNsense GUI·API, Proxmox)이 끊긴다. LAN이 게이트웨이를 잃기 때문이다.
- WAN과 HOME을 건드리지 않으므로 인터넷과 OOB 접근은 유지된다.
- **OOB가 HOME 뒤에 있으므로 WAN·HOME·라우팅이 손상되면 원격 OOB도 함께 끊긴다.** 그 경우는 현장 접근이 필요하다.

## 콘솔 접근

1. KVM 채널을 OPNsense로 전환한다.
2. `login:`에 root로 로그인한다.
3. 콘솔 메뉴가 표시된다. root의 로그인 셸이 `/usr/local/sbin/opnsense-shell`이므로 재부팅 후에도 같다.
4. `8) Shell`로 셸에 들어가고 `exit`으로 메뉴에 돌아온다.

메뉴에서 쓸 수 있는 복구 수단은 다음과 같다.

| 옵션 | 용도 |
|---|---|
| `1) Assign interfaces` | 물리 할당 되돌리기 |
| `2) Set interface IP address` | 관리 주소 복구 |
| `8) Shell` | 메뉴에 없는 조작 |
| `11) Reload all services` | 런타임 재적용 |
| `13) Restore a backup` | 작업 전 설정 복원 |

`2) Set interface IP address`는 진행 중 DHCP 범위·IPv6 tracking·GUI 프로토콜을 연달아 묻는다. 되돌리기가 목적일 때는 답을 하나 잘못 넣어도 `config.xml`이 바뀌므로, 런타임만 되돌리면 되는 상황에서는 셸을 쓴다.

## drill 실행 순서

1. 원본 설정을 백업하고 드리프트가 없음을 확인한다.
2. baseline을 기록한다. 관리 경로와 OOB 도달을 모두 확인한다.
3. 콘솔 셸에서 LAN의 런타임 주소를 제거한다.
   `ifconfig <LAN 장치> inet <LAN 주소> delete`
4. 관리 경로 상실과 OOB 생존을 같은 시점에 관측한다.
5. 콘솔 셸에서 복구한다.
   `configctl interface reconfigure lan`
6. 관리 경로 복구와 드리프트 없음을 확인한다.

3단계는 런타임만 바꾸므로 `config.xml`은 변하지 않는다. 5단계가 실패해도 재부팅하면 설정값으로 복원된다.

중단 조건: 4단계에서 OOB 접근까지 끊기면 추가 조작을 멈추고 즉시 복구로 넘어간다.

## 성공 판정

- 3단계 뒤 관리 경로 도달이 실제로 실패한다. 실패가 관측되지 않으면 lockout이 재현되지 않은 것이다.
- 같은 시점에 OOB 콘솔은 응답한다.
- 5단계 뒤 관리 경로가 복구되고 인터페이스 주소가 원래 값이다.
- 드리프트가 없다.
- WAN과 HOME은 전 과정에서 영향받지 않는다.

## 실패 시 원상복구

순서대로 시도한다.

1. `configctl interface reconfigure lan`
2. `ifconfig <LAN 장치> inet <LAN 주소>/<prefix> alias`
3. 콘솔 메뉴 `11) Reload all services`
4. 콘솔 메뉴 `6) Reboot system` — 런타임 변경은 재부팅으로 복원된다
5. 콘솔 메뉴 `13) Restore a backup` — 작업 전 원본 백업을 복원한다

## 시크릿과 보존하면 안 되는 출력

- root 비밀번호, OOB 자격증명, API key/secret을 기록·공유·커밋하지 않는다.
- 원본 백업에는 비밀번호 해시, TOTP 시드, API 키와 인증서 개인키가 들어 있다. 저장소 밖에 `0600`으로 두고 작업 후 폐기한다.
- 콘솔 화면에는 SSH 호스트키 지문과 WAN 공인 주소가 표시된다. 화면을 공유할 때 유의한다.

## 알려진 제약

- OOB는 HOME 네트워크 뒤에 있다. 인터넷·WAN·HOME이 끊기면 원격 OOB도 끊기므로 현장 접근이 최종 수단이다.
- `igc0`은 미할당이며 carrier가 없다. 물리 RECOVERY 포트는 만들지 않았다.
- `igc0`에 이전 할당의 stale description이 런타임에 남아 있다. `config.xml`에는 없다. 포트를 식별할 때는 description이 아니라 carrier 변화로 확인한다.
