# NetBird Self-Hosted Control/Relay 운영 런북

대상 VM: `netbird-01` (VMID 140, Rocky Linux 9.8, IP `10.10.40.10`)  
공개 URL: `https://netbird.imcherry5778.xyz`  
배포 버전: management·signal·relay v0.73.0, dashboard v2.90.8, Traefik v3.7.9
기준일: 2026-08-01

---

## 서비스 구성

```
netbird-01 (10.10.40.10)
  └── systemd: netbird-compose.service
        ├── netbird-traefik   (Traefik v3.7.9)  — TCP 80/443 (→ WAN NAT)
        ├── netbird-management (v0.73.0)          — OIDC Management API, HTTP 8080
        ├── netbird-signal     (v0.73.0)          — Signal gRPC/WebSocket, HTTP 10000
        ├── netbird-relay      (v0.73.0)          — Relay WebSocket, UDP 3478 STUN
        └── netbird-dashboard (v2.90.8)          — HTTP 80 (Traefik 경유)
```

**포트 매핑 (OPNsense WAN → netbird-01)**

| WAN 포트 | 프로토콜 | 목적 |
|---|---|---|
| 80/tcp | HTTP | HTTPS 리다이렉트 |
| 443/tcp | HTTPS | Dashboard, Management API, gRPC, OAuth2 |
| 3478/udp | STUN/TURN | Peer NAT 통과 및 릴레이 |

**파일 위치**

| 파일 | 경로 |
|---|---|
| Docker Compose | `/etc/netbird/docker-compose.yml` |
| NetBird Management 설정 | `/etc/netbird/management.json` |
| Traefik TLS 동적 설정 | `/etc/netbird/traefik-dynamic.yml` |
| TLS 인증서 (풀체인) | `/var/lib/netbird/letsencrypt/fullchain.pem` |
| TLS 개인키 | `/var/lib/netbird/letsencrypt/privkey.pem` |
| 관리 DB | `/var/lib/netbird/store.db` |
| IdP DB (Dex) | `/var/lib/netbird/idp.db` |
| 이벤트 DB | `/var/lib/netbird/events.db` |
| 백업 디렉터리 | `/var/backups/netbird/` |

---

## 1. 상태 확인

```bash
ssh rocky@10.10.40.10
# systemd
sudo systemctl status netbird-compose.service

# 컨테이너
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# 로그
sudo docker logs netbird-traefik --tail 20
sudo docker logs netbird-management --tail 20
sudo docker logs netbird-signal --tail 20
sudo docker logs netbird-relay --tail 20
sudo docker logs netbird-dashboard --tail 20

# STUN/TURN UDP 포트
sudo ss -ulnp | grep 3478
```

**외부에서 HTTPS 확인**

```bash
curl -sI https://netbird.imcherry5778.xyz           # HTTP/2 200 이어야 정상
curl -sk -o /dev/null -w "%{http_code}" https://netbird.imcherry5778.xyz/api/accounts
# → 401 이어야 정상 (인증 없이 접근 거부)
```

---

## 2. 서비스 재시작

```bash
sudo systemctl restart netbird-compose.service
# 또는 개별 컨테이너
sudo docker compose -f /etc/netbird/docker-compose.yml restart
```

---

## 3. TLS 인증서 갱신

TLS 인증서는 OPNsense ACME 클라이언트가 발급한 와일드카드 (`*.imcherry5778.xyz`)를 사용한다.  
OPNsense에서 자동 갱신 후 아래 절차로 netbird-01에 배포한다.

```bash
# OPNsense에서 현재 인증서 파일 위치 확인
ssh root@10.10.10.1 'ls /var/etc/acme-client/certs/'

# 인증서를 컨트롤러에서 netbird-01로 복사
ssh root@10.10.10.1 'cat /var/etc/acme-client/certs/<CERT_ID>/fullchain.pem' > /tmp/nb_fullchain.pem
ssh root@10.10.10.1 'cat /var/etc/acme-client/keys/<CERT_ID>/private.key' > /tmp/nb_privkey.pem
scp /tmp/nb_fullchain.pem rocky@10.10.40.10:/tmp/fullchain.pem
scp /tmp/nb_privkey.pem rocky@10.10.40.10:/tmp/privkey.pem
rm -f /tmp/nb_fullchain.pem /tmp/nb_privkey.pem

ssh rocky@10.10.40.10 '
  sudo mv /tmp/fullchain.pem /var/lib/netbird/letsencrypt/fullchain.pem
  sudo mv /tmp/privkey.pem /var/lib/netbird/letsencrypt/privkey.pem
  sudo chmod 600 /var/lib/netbird/letsencrypt/*.pem
  sudo systemctl restart netbird-compose.service
'
```

> **주의**: 갱신 후 30초 대기 후 HTTPS 응답을 다시 확인한다.

---

## 4. 백업

```bash
ssh rocky@10.10.40.10 '
BACKUP_FILE="/var/backups/netbird/nb01-backup-$(date +%Y%m%d_%H%M%S).tar.gz"
sudo tar czf "$BACKUP_FILE" \
  /etc/netbird/ \
  /var/lib/netbird/store.db \
  /var/lib/netbird/events.db \
  /var/lib/netbird/idp.db \
  /var/lib/netbird/letsencrypt/ \
  /etc/systemd/system/netbird-compose.service
sudo ls -lh /var/backups/netbird/
'
```

백업 파일에는 다음이 포함된다:
- Docker Compose, Management OIDC 설정, Traefik 설정
- SQLite DB 3개 (store.db, idp.db, events.db)
- TLS 인증서·개인키
- systemd 유닛 파일

> **주의**: Management 설정에는 relay secret과 encryption key가 포함된다. 백업 파일은 외부로 반출 시 암호화한다.

---

## 5. NB-02 로컬 Owner 복구 (검증된 되돌리기)

v0.73.0은 통합 `netbird-server`의 embedded Dex와 외부 OIDC를 동시에 운용하지
않는다. 따라서 로컬 Owner 복구의 정의는 Keycloak을 병행하는 것이 아니라,
전환 직전 전체 백업을 복원하고 Dex Owner의 실제 Authorization Code 로그인을
성공시키는 것이다.

Keycloak 장애나 OIDC 설정 오류일 때만 `netbird-01`에서 사용한다. 먼저 현재
SQLite DB를 별도 보관하고 `nb02-pre-switch.tar.gz` SHA-256 및 각 SQLite
`quick_check`를 검증한다.

```bash
sudo systemctl stop netbird-compose.service
sudo tar --overwrite -xzf /var/backups/netbird/nb02-pre-switch.tar.gz -C /
sudo systemctl daemon-reload
```

복원한 당시 `idp.db`와 레거시 `config.yaml`의 Owner bcrypt hash가 손상됐던 것이
실측되었다. combined server는 시작할 때 `config.yaml`의 hash를 Dex DB에 다시 반영하므로,
복원 뒤에는 두 위치를 같은 새 bcrypt hash로 함께 보정한 뒤 시작한다. 비밀번호 원문을
명령행·Git·로그에 넣지 않는다.

```bash
# Owner password 파일은 이 VM에 mode 0600으로 안전하게 전달한 뒤 사용한다.
sudo python3 - <<'PY'
import bcrypt
import sqlite3
import re
from pathlib import Path

password = Path('/안전한/임시/owner-password').read_text().rstrip('\n').encode()
hash_value = bcrypt.hashpw(password, bcrypt.gensalt(rounds=10)).decode()
config = Path('/etc/netbird/config.yaml')
updated, count = re.subn(
    r'(?m)^(\s*password:\s*).*$',
    lambda match: match.group(1) + hash_value,
    config.read_text(),
    count=1,
)
if count != 1:
    raise SystemExit('legacy config Owner password 항목을 정확히 하나 찾지 못했습니다')
config.write_text(updated)
conn = sqlite3.connect('/var/lib/netbird/idp.db')
conn.execute(
    'UPDATE password SET hash = ? WHERE email = ?',
    (hash_value, 'admin@imcherry5778.xyz'),
)
conn.commit()
conn.close()
PY
sudo shred -u /안전한/임시/owner-password
sudo systemctl enable --now netbird-compose.service
```

그 뒤 내부 resolver를 쓰는 브라우저에서 `admin@imcherry5778.xyz` Dex Owner가
실제로 Authorization Code 로그인을 성공해야만 복구 성공이다. Keycloak 전환 재적용은
NB-02 Ansible role로만 수행하며, 게스트의 수동 compose 편집으로 두 IdP를 병행하지 않는다.

---

## 6. Dex 되돌리기 상태의 Owner 비밀번호 재설정

Owner 계정 비밀번호는 Dex IdP (`idp.db`)와 레거시 `config.yaml`에 같은 bcrypt hash로
저장된다. 섹션 5의 Python 절차를 사용한다. `pip install`, 셸 변수, SQLite 인라인 SQL에
비밀번호 원문을 넣지 않는다. 이 경로에서는 combined server 재시작으로 config와 DB의 일치를
검증한다.

---

## 7. Keycloak OIDC·groups 정책

일반 사용자는 Keycloak `platform` realm의 public `netbird-client`로 Authorization
Code + PKCE 또는 device authorization을 사용한다. `groups` claim의
`/platform-users`만 NetBird single account에 허용한다. 직접 NetBird 권한을
사용자에게 붙이지 않는다.

현재 Keycloak은 공개 DNS와 WAN origin 경로가 없으므로 로그인 검증 범위는 내부 resolver로
`sso.imcherry5778.xyz`를 [`ip-plan.md`](../ip-plan.md)의 내부 alias 대상으로 해석하는 클라이언트다.
`EDGE-02`가 [공개 사용자 프런트엔드 런북](keycloak-public-frontchannel.md)의 외부 OIDC 경계를
완료하기 전에는 이 범위를 외부 peer 대화형 로그인 증거로 승격하지 않는다. `EDGE-02` 뒤
일반 사용자 device group·split DNS·exact route는 `NB-ENROLL-01`이 별도로 소유한다.

Management의 Keycloak discovery·JWKS·userinfo/Admin API 경로는 OPNsense `opt4`의
NB-02 rule만 사용한다: `10.10.40.10 → 10.10.20.10`, TCP 443, RFC1918 BLOCK보다
앞선 sequence 1216, logging enabled. 상세는 `opnsense-netbird-keycloak-path.md`를 따른다.
Management는 Docker bridge `172.18.0.0/16`의 Traefik만 reverse-proxy header 신뢰 대상으로
한정한다.

### 2026-08-01 NB-02 완료 증거

- 전환 전 `/var/backups/netbird/nb02-pre-switch.tar.gz`의 SHA-256은
  `60d779277f9540f741f286cf017bc4bca9fca56d4ea248ef16b1b96786ef8bb3`이며,
  전환·두 재부팅 뒤에도 일치했다. 압축본의 `store.db`·`events.db`·`idp.db`는 모두
  `PRAGMA quick_check=ok`다.
- Keycloak `netbird-client` public client와 `netbird-backend` service client만 Admin API로
  선언했다. realm bootstrap과 기존 `kc-verify`·복구 client·그룹·사용자는 수정하지 않았다.
  dashboard의 실제 `/nb-auth` callback으로 Authorization Code + PKCE + TOTP code 교환을
  완료했고 `/platform-users` token은 Management API 200, 그룹이 없는 특권 ID token은 401이었다.
  MFA 미입력 로그인은 거부되고 TOTP 입력은 성공했다.
- Management v0.73.0은 Keycloak discovery·JWKS와 device authorization·PKCE endpoint를 실제로
  로드했다. 무자격 token과 수명 300초가 지난 실제 Keycloak token은 모두 401이었다.
- v0.73.0 client를 일회성·사용 한도 1·ephemeral setup key로 등록해 Management·Signal·Relay와
  연결하고 overlay IP를 받은 뒤, 임시 peer·setup key·client state를 삭제했다. 최종 peer와
  setup key는 각각 0건이다.
- Dex 복구는 전환 백업 복원, `config.yaml`·`idp.db` Owner bcrypt 동시 보정, combined server
  기동과 `admin@imcherry5778.xyz`의 실제 Authorization Code 로그인까지 두 차례 성공했다.
  최종 상태는 Ansible role로 Keycloak OIDC를 다시 적용한 상태다.
- `netbird-01` 재부팅 뒤 새 boot ID에서 unit은 enabled+active이고 management·signal·relay·
  dashboard·Traefik이 자동 시작했다. 그룹 허용 200·비그룹 401을 다시 확인했으며 Ansible
  2회차는 `changed=0 failed=0`이다.
- OPNsense 최소 rule과 재부팅 증거는
  [전용 경로 런북](opnsense-netbird-keycloak-path.md)이 소유한다. 검증 범위는 내부 resolver를
  쓰는 클라이언트이며, 이 2026-08-01 완료 증거는 외부 peer 대화형 OIDC 로그인을 검증하지 않았다.

## 8. 로그 및 이벤트 조회

```bash
# 실시간 Management 로그
sudo docker logs -f netbird-management

# Traefik 접근 로그 (실시간)
sudo docker logs -f netbird-traefik

# NetBird 이벤트 DB 조회
sudo sqlite3 /var/lib/netbird/events.db "SELECT * FROM events ORDER BY timestamp DESC LIMIT 20;"

# Peer 및 계정 정보 (Management API 사용 - PAT 발급 필요)
# Dashboard → Settings → Personal Access Tokens에서 PAT 발급 후:
# curl -H "Authorization: Token <PAT>" https://netbird.imcherry5778.xyz/api/peers
```

---

## 9. 선언형 재배포 (Ansible)

설정 변경 또는 이미지 업데이트 시:

```bash
cd /home/imcherry/projects/ktcloud4-bean/platform
ANSIBLE_ROLES_PATH="$PWD/infra/ansible/roles" ansible-playbook \
  -i /경로/밖/nb-02/inventory.yml infra/ansible/playbooks/netbird-server.yml \
  -e netbird_secret_vars_file=/경로/밖/netbird/nb-02-vars.yml
```

비밀 경로는 모두 저장소 밖 mode 0600 파일을 사용한다. 두 번째 실행에서
`changed=0 failed=0`이면 정상이다.

---

## 10. 이미지 버전 고정값

| 컨테이너 | 이미지 | SHA256 digest (앞 12자) |
|---|---|---|
| management | `netbirdio/management:v0.73.0` | `9a9d86443f63...` |
| signal | `netbirdio/signal:v0.73.0` | `d75f0613432...` |
| relay | `netbirdio/relay:v0.73.0` | `2fc6ac6106b...` |
| netbird-dashboard | `netbirdio/dashboard:v2.90.8` | `6b3df5d07cbc...` |
| netbird-traefik | `traefik:v3.7.9` | `652929a140a3...` |

이미지 업데이트 시 `infra/ansible/roles/netbird_server/defaults/main.yml`의 digest를 갱신한다.

---

## 11. 알려진 제약

| 항목 | 내용 |
|---|---|
| TLS 자동 갱신 | Traefik ACME DNS-01 (Cloudflare zone 미인식 오류)로 실패. OPNsense ACME 와일드카드 수동 배포로 대체 |
| ISP 제약 | KT ISP 환경에서 외부 TCP 80 inbound에 타임아웃 발생. ACME HTTP-01 challenge 불가 |
| IPv6 | AAAA 레코드 미생성. IPv6 경로 미검증 |
| 로컬 Owner | Keycloak과 Dex 동시 운용 불가. `nb02-pre-switch.tar.gz` 복원과 실제 Dex Owner 로그인으로만 복구 증명 |
| 외부 peer OIDC 로그인 | 현재 `sso` 공개 origin이 없어 랩 밖 브라우저는 미검증. `EDGE-02`가 제한된 사용자 프런트엔드를, `NB-ENROLL-01`이 일반 장치 경로를 완료하기 전까지 내부 검증과 구분 |
| OPNsense 재부팅 | k3s의 유일한 upstream DNS가 일시 중단돼 Keycloak readiness가 약 10분 지연됐다. 설정·Pod 재시작 없이 자동 복구됨 |
