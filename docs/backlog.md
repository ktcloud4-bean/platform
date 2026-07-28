# 현재 상태 · 다음 할 일

새 세션은 이 문서부터 읽는다. 상황이 바뀌면 여기를 고친다.

`AGENTS.md` 가 어디를 읽을지 알려준다면, 이 문서는 **지금 어디까지 왔는지**다.

---

## 현재 — Phase 1

VLAN 없이 단일 LAN `10.10.10.0/24` 로 운영 중. 관리형 스위치가 들어오면 Phase 2 로 넘어간다 (`ip-plan.md` 3장).

| 계층 | 상태 |
|---|---|
| OPNsense | ✅ 엣지 전환 완료. 공인 IP 직접 수신, 2FA, 관리 포트 LAN 제한, 드리프트 탐지 |
| Proxmox | ❌ 미설치 — **다음 마일스톤** |
| k3s | ❌ |
| Keycloak · Vault · Harbor | ❌ |

---

## 미해결 — Proxmox 이전에 처리

### 1. DHCP 풀이 고정 IP 계획을 침범하고 있다 ★

| | 대역 |
|---|---|
| `ip-plan.md` 설계 | `.30~.99` 서비스 고정 / `.100~` 동적 |
| 실제 Dnsmasq | **`.41~.245`** |

`k3s-master .50`, `worker .51/.52`, `netbird .90` 이 전부 DHCP 풀 안에 들어 있다. Proxmox 가 첫 고정 IP 장비가 되므로 **그 전에** 좁힌다.

`Services → Dnsmasq DNS & DHCP → DHCP ranges` → `.100 ~ .245`

### 2. DHCP 이름 등록이 꺼져 있다

Unbound 가 기본 도메인 질의를 Dnsmasq(`127.0.0.1:53053`)로 위임해 두었으나, Dnsmasq 의 `regdhcp` · `regdhcpstatic` 이 둘 다 `0` 이라 등록되는 이름이 없다. **위임 체인만 있고 내용물이 비어 있는 상태.**

`Services → Dnsmasq DNS & DHCP → General → Register DHCP static mappings`

---

## 다음 순서

**원격에서 가능** — 방화벽·인터페이스를 건드리지 않는다

1. DHCP 범위 축소 ← Proxmox 의 전제 조건
2. DHCP 정적 매핑 이름 등록
3. ACME 플러그인 + Cloudflare DNS-01 → 와일드카드 인증서 (`ip-plan.md` 4장)
4. 위 변경을 `check-drift.sh --update` 후 커밋

**랩에 있어야 가능**

5. **Proxmox 설치** (`10.10.10.10`) — 랩의 실질적 시작
6. `infra/proxmox/` OpenTofu 구성
7. 관리형 스위치 → VLAN Phase 2

---

## 결정된 것

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
