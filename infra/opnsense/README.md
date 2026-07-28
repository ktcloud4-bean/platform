# OPNsense

경계 방화벽 · 라우터. 랩 네트워크의 게이트웨이이자 인터넷으로 나가는 유일한 문.

## 이 디렉터리의 성격

**OPNsense 는 Git 이 바꿀 수 없다.** 설정은 웹 UI 로만 가능하고, 여기 있는 `config.xml` 은 **명령이 아니라 기록**이다.

```
사람이 UI 에서 변경
      ↓
config.xml 내보내기 → 마스킹 → 커밋
      ↓
주기적으로 현재 상태와 diff → 차이가 나면 알림
      ↓
정당한 변경이면 커밋해 승인 / 아니면 UI 에서 되돌림
```

이 장치의 실질적 가치는 **"임시" 라고 적어 둔 방화벽 규칙이 몇 년씩 열려 있는 것을 막는 것**이다. 드리프트 탐지가 없으면 그런 규칙은 반드시 영구가 된다.

## 설정을 내보내는 법

`System → Configuration → Backups → Download`

- **Do not backup RRD data** — 체크. 그래프 데이터를 빼서 파일을 작게 유지한다
- **Encrypt this configuration file** — 체크하지 않는다. 암호화하면 diff 를 볼 수 없어 드리프트 탐지가 무력화된다

⚠️ **받은 파일을 그대로 커밋하지 말 것.** `config.xml` 에는 다음이 평문으로 들어 있다.

| 위치 | 내용 |
|---|---|
| `<system><user><password>` | 비밀번호 해시 |
| `<cert><prv>` | **TLS 개인키** (base64, 약 4KB) |
| `<system><user><apikeys>` | API 키 |
| `<revision>` | 저장할 때마다 바뀌는 타임스탬프 — 매일 거짓 diff 를 만든다 |

`.gitignore` 가 `*.raw.xml` 을 막고 있다. 원본은 `config.raw.xml` 로 두고, 마스킹한 버전만 `config.xml` 로 커밋한다.

## 현재 구성

| 항목 | 값 |
|---|---|
| 호스트명 | `fw01.imcherry5778.xyz` |
| **WAN** (`igc1`) | ISP DHCP — 공인 IP |
| **LAN** (`igc0`) | `10.10.10.1/24` — 랩 네트워크 |
| **HOME** (`igc2`) | `10.10.60.1/24` — 다운스트림 (프로젝트 범위 외) |
| `igc3` | 미할당 |
| DNS | Unbound (Override DNS 해제, DNSSEC 활성) |
| DHCP | **Dnsmasq** — ISC DHCP 는 26.7 에서 폐기됨 |

인터페이스 배정 확인은 콘솔의 `1) Assign interfaces`, 물리 포트 대응은 케이블을 뽑았다 꽂아 `status: no carrier` 로 바뀌는 쪽을 보면 된다.

```sh
for i in igc0 igc1 igc2 igc3; do printf "%-6s " $i; ifconfig $i | grep -o 'status:.*'; done
```

## 알아둘 것

### 파일시스템을 직접 고치면 덮어써진다

OPNsense 는 `config.xml` 에서 설정 파일을 매번 생성한다. `/usr/local/etc/` 를 손으로 고쳐도 서비스 재시작 때 원래대로 돌아간다.

**`ssh-copy-id` 가 동작하지 않는 이유도 같다.** `/root/.ssh/authorized_keys` 에 키를 넣어도, GUI 에서 아무 설정이나 저장하는 순간 config.xml 기준으로 덮어써진다.

SSH 공개키는 반드시 **`System → Access → Users → root → Authorized keys`** 에 등록한다.

### 플러그인은 config 에 기록되지만 pkg 는 아니다

| 행위 | 기록 | 결과 |
|---|---|---|
| 플러그인 설치 (GUI) | ✅ `<firmware><plugins>` | 안전 |
| `pkg install` (셸) | ❌ | 펌웨어 업그레이드 시 사라짐 |
| `/usr/local/etc/` 직접 수정 | ❌ | 서비스 재시작 시 덮어써짐 |

필요한 기능이 있으면 플러그인을 찾는다. 없으면 그 기능을 OPNsense 에서 하지 않는 것이 맞다.

### 내장 설정 이력

`System → Configuration → History` 에 변경 이력이 diff 와 함께 보관된다. 원클릭 롤백도 된다.

다만 **장비 안에만** 있어서 디스크가 죽으면 같이 사라진다. Git 과 보완 관계다. `Backups → Backup Count` 를 넉넉히(50 정도) 잡아두면 원격 작업 중 실수했을 때 안전망이 된다.

## 하지 말 것

- **Keycloak SSO 를 붙이지 않는다.** Keycloak 이 죽으면 방화벽에 들어갈 수 없게 된다. 로컬 계정이 break-glass 다.
- **Warpgate 대상에 넣지 않는다.** 같은 이유 — Warpgate·Keycloak 이 죽었을 때 고쳐야 할 장비다.
- **오버레이(NetBird) 에이전트를 설치하지 않는다.** 오버레이가 죽으면 복구 경로가 사라진다.
- **원격에서 LAN IP·인터페이스 배정·방화벽 기본 정책을 바꾸지 않는다.** 되돌릴 수 없다.

## 보안 점검 항목

| 항목 | 상태 |
|---|---|
| SSH `Permit password login` | 해제 (공개키만) |
| SSH `Listen Interfaces` | **LAN 으로 제한 필요** ← 현재 `All` |
| 웹 GUI `Listen Interfaces` | **LAN 으로 제한 필요** ← 현재 `All` |
| WAN `Block private networks` | 활성 |
| WAN `Block bogon networks` | 활성 |

WAN 이 공인 IP 이므로 `Listen Interfaces: All` 은 관리 포트가 인터넷 쪽에서도 listen 한다는 뜻이다. 기본 WAN 방화벽 규칙이 차단하고 있으나, 규칙 하나에만 의존하지 않도록 인터페이스를 제한해야 한다.
