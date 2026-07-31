# NetBird Self-Hosted Control/Relay 운영 런북

대상 VM: `netbird-01` (VMID 140, Rocky Linux 9.8, IP `10.10.40.10`)  
공개 URL: `https://netbird.imcherry5778.xyz`  
배포 버전: netbird-server v0.73.0, dashboard v2.90.8, Traefik v3.7.9  
기준일: 2026-07-31

---

## 서비스 구성

```
netbird-01 (10.10.40.10)
  └── systemd: netbird-compose.service
        ├── netbird-traefik   (Traefik v3.7.9)  — TCP 80/443 (→ WAN NAT)
        ├── netbird-server    (v0.73.0)          — UDP 3478 STUN/TURN, HTTP 8080
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
| NetBird 서버 설정 | `/etc/netbird/config.yaml` |
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
sudo docker logs netbird-server --tail 20
sudo docker logs netbird-dashboard --tail 20

# STUN/TURN UDP 포트
sudo ss -ulnp | grep 3478
```

**외부에서 HTTPS 확인**

```bash
curl -sI https://netbird.imcherry5778.xyz           # HTTP/2 200 이어야 정상
curl -sk https://netbird.imcherry5778.xyz/oauth2/.well-known/openid-configuration | head -5
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
- Docker Compose, config.yaml, Traefik 설정
- SQLite DB 3개 (store.db, idp.db, events.db)
- TLS 인증서·개인키
- systemd 유닛 파일

> **주의**: `config.yaml`에는 authSecret, encryptionKey가 포함된다. 백업 파일은 외부로 반출 시 암호화한다.

---

## 5. 복원

```bash
# 격리 환경(또는 새 VM)에서 복원
BACKUP_FILE="nb01-backup-YYYYMMDD_HHMMSS.tar.gz"

# 파일 복원
sudo tar xzf "$BACKUP_FILE" -C /

# Ansible로 Docker 환경 재구성
ansible-playbook -i inventory playbooks/netbird-server.yml

# 서비스 재시작
sudo systemctl daemon-reload
sudo systemctl enable --now netbird-compose.service

# 검증
curl -sk -o /dev/null -w "%{http_code}" https://netbird.imcherry5778.xyz/api/accounts
# → 401
curl -sk https://netbird.imcherry5778.xyz/oauth2/.well-known/openid-configuration | head -5
```

---

## 6. Owner 계정 비밀번호 재설정

Owner 계정 비밀번호는 Dex IdP (idp.db)에 bcrypt hash로 저장된다.  
비밀번호를 분실하거나 변경해야 할 경우:

```bash
ssh rocky@10.10.40.10
sudo pip3 install bcrypt -q
NEW_PASS="새로운비밀번호"
NEW_HASH=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b\"${NEW_PASS}\", bcrypt.gensalt(rounds=10)).decode())")
sudo sqlite3 /var/lib/netbird/idp.db \
  "UPDATE password SET hash=\"$NEW_HASH\" WHERE email=\"admin@imcherry5778.xyz\";"
echo "비밀번호 업데이트 완료"
```

> **중요**: 비밀번호 변경 후 서비스 재시작은 불필요하다. Dex가 요청 시 DB를 조회한다.

---

## 7. 로그 및 이벤트 조회

```bash
# 실시간 netbird-server 로그
sudo docker logs -f netbird-server

# Traefik 접근 로그 (실시간)
sudo docker logs -f netbird-traefik

# NetBird 이벤트 DB 조회
sudo sqlite3 /var/lib/netbird/events.db "SELECT * FROM events ORDER BY timestamp DESC LIMIT 20;"

# Peer 및 계정 정보 (Management API 사용 - PAT 발급 필요)
# Dashboard → Settings → Personal Access Tokens에서 PAT 발급 후:
# curl -H "Authorization: Token <PAT>" https://netbird.imcherry5778.xyz/api/peers
```

---

## 8. 선언형 재배포 (Ansible)

설정 변경 또는 이미지 업데이트 시:

```bash
cd /home/imcherry/projects/ktcloud4-bean/platform
git checkout task/nb-01
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/imcherry/.ssh/known_hosts_nb01"
ansible-playbook -i /tmp/inventory_nb01 playbooks/netbird-server.yml
```

멱등성 확인: `ok=33 changed=0 failed=0 skipped=1`이면 정상.

---

## 9. 이미지 버전 고정값

| 컨테이너 | 이미지 | SHA256 digest (앞 12자) |
|---|---|---|
| netbird-server | `netbirdio/netbird-server:v0.73.0` | `8d7fe3f415a3...` |
| netbird-dashboard | `netbirdio/dashboard:v2.90.8` | `6b3df5d07cbc...` |
| netbird-traefik | `traefik:v3.7.9` | `652929a140a3...` |

이미지 업데이트 시 `infra/ansible/roles/netbird_server/defaults/main.yml`의 digest를 갱신한다.

---

## 10. 알려진 제약

| 항목 | 내용 |
|---|---|
| TLS 자동 갱신 | Traefik ACME DNS-01 (Cloudflare zone 미인식 오류)로 실패. OPNsense ACME 와일드카드 수동 배포로 대체 |
| ISP 제약 | KT ISP 환경에서 외부 TCP 80 inbound에 타임아웃 발생. ACME HTTP-01 challenge 불가 |
| IPv6 | AAAA 레코드 미생성. IPv6 경로 미검증 |
| Keycloak 연동 | NB-02 작업 범위. 현재는 embedded Dex IdP (로컬 owner) 사용 |
| 외부 peer 라이브 검증 | 랩 외부 peer를 통한 direct/relay 경로 검증은 NB-02 이후 외부 클라이언트 환경 확보 시 수행 |
