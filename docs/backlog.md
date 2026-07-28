# 현재 상태 · 다음 할 일

새 세션은 이 문서부터 읽는다. 상황이 바뀌면 여기를 고친다.

`AGENTS.md` 가 어디를 읽을지 알려준다면, 이 문서는 **지금 어디까지 왔는지**다.

---

## 현재 — Phase 1

VLAN 없이 단일 LAN `10.10.10.0/24` 로 운영 중. Proxmox 설치 후 OPNsense 와 Proxmox 를 직결한 802.1Q 트렁크로 Phase 2 로 넘어간다 (`ip-plan.md` 3장).

| 계층 | 상태 |
|---|---|
| OPNsense | ✅ 엣지 전환 완료. 공인 IP 직접 수신, 2FA, 인터페이스 재배치, 드리프트 탐지 |
| Proxmox | ❌ 미설치 — **다음 마일스톤** |
| k3s | ❌ |
| Keycloak · Vault · Harbor | ❌ |

---

## 다음 순서

**원격에서 가능** — 방화벽·인터페이스를 건드리지 않는다

1. ~~DHCP 범위 축소~~ ✅ 라이브 적용 · 런타임 검증 · Git 사본 반영 완료
2. ~~ACME 플러그인 + Cloudflare DNS-01 → 와일드카드 인증서~~ ✅ (`ip-plan.md` 4장)
   - ✅ 노출된 ACME 계정 키 교체 · 인증서 재발급 · GUI 적용 완료
   - ✅ 자동 갱신 설정과 실제 cron 등록 검증 완료
   - ✅ ACME DNS 자격증명 · 계정 개인키 마스킹과 회귀 테스트 추가
3. ~~위 변경을 `infra/opnsense/scripts/check-drift.sh --update` 후 커밋~~ ✅ 스냅샷 갱신 · 드리프트 없음 확인

**랩에 있어야 가능**

4. ~~HOME·LAN 물리 인터페이스 재배치~~ ✅ 링크 · 라우트 · DNS · Tailscale · HTTPS 검증 완료
5. **Proxmox 설치** (`10.10.10.10`) — 랩의 실질적 시작
6. `igc0` RECOVERY 인터페이스 설계 · 현장 검증
7. HOME 광범위 허용 규칙을 목적지·포트 기준 최소 권한으로 교체
8. `infra/proxmox/` OpenTofu 구성
9. OPNsense–Proxmox 직결 802.1Q tagged-only 트렁크 → VLAN Phase 2

---

## 결정된 것

### 관리형 스위치는 현재 계획에서 제외한다

프로젝트에 연결되는 물리 노드는 Proxmox 한 대뿐이다. OPNsense `igc2` 와 Proxmox 물리 NIC 를 직접 연결하고, 이 링크에서 관리(10)·플랫폼(20)·DMZ(40) VLAN 을 802.1Q 로 전달한다. 관리형 스위치는 VLAN 의 필수 조건이 아니다.

두 번째 Proxmox, 프로젝트용 NAS, VLAN 대응 AP 같은 물리 장비가 추가될 때만 도입을 다시 판단한다. 최종 트렁크에는 untagged 네트워크를 섞지 않으며, RECOVERY 또는 OOB 접근을 확보한 뒤 관리(10)를 tagged 로 전환하고 플랫폼(20) → DMZ(40) 순서로 검증한다.

### DNS 는 OPNsense Unbound 가 담당한다. k3s 에 올리지 않는다

Unbound 는 재귀 해석기로 동작하고(`forwarding=0` — 루트부터 직접 질의) DNSSEC 검증을 한다.

AdGuard Home 은 **대체재가 아니다.** 스스로 재귀하지 않고 업스트림에 넘기는 필터링 프록시라, 쓴다면 Unbound 앞단에 겹치는 것이지 바꿔 끼우는 게 아니다. 그리고 랩에서는 필요가 없다 — 서버는 광고를 보지 않고, 차단이 필요하면 Unbound 에 DNSBL 이 내장돼 있다.

**k3s 에 DNS 를 두면 순환 의존이 생긴다.** k3s 부팅 → 이미지 pull → 레지스트리 이름 해석 → DNS. 그 DNS 가 클러스터 안에 있으면 클러스터가 죽었을 때 되살릴 수단까지 같이 죽는다. `infra/opnsense/README.md` 의 "하지 말 것" 과 같은 원칙이다 — **복구 경로가 복구 대상에 의존하면 안 된다.**

쿼리 로그가 필요해지면 순서는:

1. Unbound `logqueries` 켜고 syslog 외부 전송 (현재 `0`)
2. 그래도 대시보드가 필요하면 **Proxmox LXC** 에 두고 Unbound 를 업스트림으로
3. k3s 에는 끝까지 두지 않는다

---

## 후속 ADR 대상

Notion `Zero Trust - Bean / 결정 & 리스크 로그` 에 기록한다.

- Keycloak 그룹 · 역할 모델
- Cosign 서명 방식
- Vault 인증 경로 · unseal 전략
- 레포 분리 기준
- VLAN 간 방화벽 정책
- 온프레미스 ↔ AWS 연결
