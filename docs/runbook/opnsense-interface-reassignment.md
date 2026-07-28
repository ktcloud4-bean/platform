# OPNsense 물리 인터페이스 재할당

## 목적과 범위

OPNsense 의 논리 LAN·HOME 을 `docs/ip-plan.md` 에 정의된 물리 장치로 옮긴다. IP 주소, DHCP 범위, 방화벽 정책과 VLAN 은 이 작업에서 바꾸지 않는다.

## 전제조건

- 목표 할당은 `docs/ip-plan.md` 에 먼저 기록한다.
- 현장 작업자가 케이블을 즉시 옮길 수 있어야 한다.
- 로컬 콘솔 또는 기존 LAN 직접 접속을 복구 경로로 확보한다.
- `System → Configuration → Backups` 에서 원본 설정을 내려받아 저장소 밖에 권한 `0600`으로 보관한다.
- `infra/opnsense/README.md` 의 링크 상태 확인 명령으로 실제 포트를 식별한다.

## 예상 영향

할당을 적용하면 인터페이스 주소·라우트·필터가 새 장치로 즉시 재구성된다. HOME 케이블을 옮길 때까지 다운스트림 인터넷·DNS·오버레이 경로가 중단되고 기존 상태 연결은 끊어진다.

## 실행 순서

1. `Interfaces → Assignments` 에서 HOME 과 LAN 의 Device 를 `docs/ip-plan.md` 의 목표값으로 저장한다.
2. 두 pending 변경이 정확한지 다시 확인한다.
3. Apply 를 한 번만 실행한다.
4. HOME 케이블을 새 HOME 포트로 옮기고 링크가 올라올 때까지 기다린다.
5. HOME 경로 검증이 끝나기 전에는 새 LAN 포트에 다른 장비를 연결하지 않는다.
6. HOME 검증 후 새 LAN 포트에 테스트 노트북 또는 Proxmox 를 연결한다.

## 성공 판정

- Assignments 에서 LAN·HOME 장치가 `docs/ip-plan.md` 와 일치한다.
- 새 HOME 은 `active`, 장비가 없는 LAN 은 `no carrier` 로 표시된다.
- 직접 연결 라우트가 각각 새 장치를 사용한다.
- 논리 LAN·HOME 방화벽 규칙이 각각 새 물리 장치로 컴파일된다.
- 내부 DNS, 오버레이 경로, 인증서를 검증하는 HTTPS 요청이 성공한다.
- `infra/opnsense/scripts/check-drift.sh --update` 후 재실행 결과가 `드리프트 없음`이다.

## 실패 시 복구

1. 추가 변경을 중단한다.
2. 로컬 콘솔의 `Assign interfaces`에서 `docs/ip-plan.md`의 직전 정상 할당으로 되돌린다.
3. 케이블도 직전 포트로 되돌린다.
4. GUI 접근까지 손상됐다면 콘솔의 `Set interface IP address`에서 Web GUI 접근 기본값을 복구한다.
5. 그래도 복구되지 않으면 변경 전 원본 설정을 복원한다.

## 시크릿 취급

원본 설정 백업에는 계정 키·API 토큰·인증서 개인키가 들어 있다. 내용을 출력하거나 Git 에 추가하지 않으며, 작업 종료 후 안전하게 삭제한다. Git 에는 `normalize.py`를 거친 `infra/opnsense/config.xml`만 둔다.
