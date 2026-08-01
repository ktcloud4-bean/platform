# Proxmox VE ACME DNS-01 관리 TLS 운용

검증일: 2026-08-01 (`PVE-ACME-FIX-01`, 전용 token 교체·재발급 재검증). 최초 구축 검증일은 2026-07-30 (`PVE-ACME-01`). 선택 이유·대안·재검토 조건은 [ADR-0009](../adr/0009-proxmox-native-acme-management-tls.md), 주소는 `docs/ip-plan.md`가 소유한다.

저장된 plugin 자격증명은 발급 성공만으로 검증되지 않는다. 인증서가 유효한 동안에는 잘못된 token이 저장돼 있어도 드러나지 않고, 만료 30일 전 자동 갱신 시점에야 실패한다. token을 바꾼 뒤에는 반드시 저장값 해시를 확인하고 staging 발급으로 DNS-01 왕복을 실증한다.

---

## 목적

Proxmox VE 내장 ACME 기능과 Cloudflare DNS-01 API를 이용해 `proxmox-01.imcherry5778.xyz` canonical FQDN 단일 명의의 Let's Encrypt 공인 TLS 인증서를 발급·자동 갱신하도록 구성하고, strict TLS 검증 환경을 확립한다.

---

## 전제조건 및 공유 잠금

- **공유 잠금**: `PVE-LIVE`, `PUBLIC-DNS`, `TOFU-STATE`
- **전제조건**:
  - `PVE-01` (Proxmox 기본 설치), `DNS-01` (내부 DNS 등록), `AUTO-01` (자동설치 PoC), `IAC-01` (OpenTofu 기준선) 완료
  - Cloudflare Zone: `imcherry5778.xyz`
  - Cloudflare API Token: Proxmox 전용 `proxmox-acme-imcherry5778-xyz`, `Zone.DNS` (Edit) 최소 권한 스코프 부여. 같은 zone을 쓰는 OPNsense·k3s Traefik·Warpgate 토큰을 재사용하지 않는다

---

## 시크릿 입력 및 저장 경계

1. **저장 위치**:
   - `infra/proxmox/acme/.env` (또는 저장소 루트 `.env`) 파일에 mode `0600` (`chmod 600 .env`)으로 보관한다.
   - 셸 환경으로 `source` 하지 않으며, 스크립트를 통해 마스킹된 Key-Value 파싱으로만 접근한다.
2. **Proxmox 저장 경계**:
   - Proxmox 노드의 보호된 ACME 플러그인 구성(`/etc/pve/priv/acme/plugins.cfg`)에 자동 갱신용으로 보관된다.
3. **노출 금지**:
   - API 토큰, ACME account private key, certificate private key는 Git, CLI 인자(argv), 셸 기록, 프로세스 목록, 로그에 남기지 않는다.

---

## 구축 및 검증 순서

### 1. 회귀 및 정적 검사
```bash
./infra/proxmox/acme/scripts/test-acme.sh
```

### 2. Let's Encrypt Staging 계정 검증
```bash
./infra/proxmox/acme/scripts/setup-acme.sh staging
```
- ACME Account `le-staging` 등록 및 `cf-dns` 플러그인 구성
- domain `proxmox-01.imcherry5778.xyz` 노드 연결 후 staging 주문
- DNS-01 `_acme-challenge` TXT 생성 및 발급 직후 자동 삭제 확인

### 3. 기본 인증서 복원 (Rollback Drill)
```bash
./infra/proxmox/acme/scripts/setup-acme.sh rollback
```
- `pvenode cert delete --restart 1` 실행으로 PVE Cluster Manager CA 기본 자체 서명 인증서로 복구
- `pveproxy` 서비스 자동 재시작 및 HTTPS 8006 접속 유지 확인

### 4. Let's Encrypt Production 인증서 발급
```bash
./infra/proxmox/acme/scripts/setup-acme.sh production
```
- ACME Account `le-production` 등록 및 production 주문 (rate limit 방지를 위해 1회만 진행)
- 인증서 발급 완료 후 `/etc/pve/nodes/proxmox-01/pveproxy-ssl.pem` 적용 및 `pveproxy` 재시작 확인

### 5. Strict TLS 및 성공 판정
```bash
./infra/proxmox/acme/scripts/setup-acme.sh verify
```

판정 기준:
- **SAN**: `proxmox-01.imcherry5778.xyz` 정확히 일치 (wildcard 및 내부 IP 미포함)
- **Issuer**: Let's Encrypt 서명 체인 확인
- **Strict TLS**: `curl https://proxmox-01.imcherry5778.xyz:8006/` HTTP 200 OK (insecure 옵션 및 CA 지정 우회 없이 성공)
- **DNS TXT 잔여물**: `_acme-challenge` TXT 레코드 비어 있음
- **OpenTofu**: `infra/proxmox/tofu/variables.tf`의 `proxmox_insecure` 기본값이 `false`인 상태에서 `tofu plan` 성공

---

## 자동 갱신 확인 범위

- **Timer**: `pve-daily-update.timer` 가 `active (waiting)` 상태로 하루 한 번 갱신 여부 체크
- **설정 연결**: `pvenode config get` 조회 시 `acme: account=le-production` 및 `acmedomain0: domain=proxmox-01.imcherry5778.xyz,plugin=cf-dns` 정상 연결 유지

---

## 인증서·DNS·pveproxy 장애 시 Rollback 절차

발급 실패나 pveproxy 장애 발생 시 즉시 PVE 기본 인증서로 복구한다.

```bash
# Proxmox 노드 또는 SSH에서 실행
pvenode cert delete --restart 1
systemctl restart pveproxy
```

---

## Token Rotation 및 폐기 절차

1. **토큰 회전 (Rotation)**:
   - Cloudflare 대시보드에서 `proxmox-acme-imcherry5778-xyz` 규약의 새 `Zone.DNS` (Edit) 토큰 발급
   - `.env` 파일의 `CLOUDFLARE_API_TOKEN` 수정
   - `./infra/proxmox/acme/scripts/setup-acme.sh plugin` 실행하여 `cf-dns` plugin data만 갱신 (`production`은 인증서를 재발급해 rate limit을 소모하므로 회전 전용으로 쓰지 않는다)
   - `staging`으로 새 토큰의 DNS-01 성공을 확인한 뒤 `production`으로 공인 인증서 복귀
   - Cloudflare 대시보드에서 새 토큰 `Last used` 갱신 확인 후 기존 토큰 Revoke. 다른 서비스가 같은 토큰을 참조하지 않는지 먼저 확인한다
2. **토큰 및 인증서 폐기 (Revocation)**:
   - `pvenode acme cert revoke` 명령으로 인증서 폐기 요청
   - Cloudflare 대시보드에서 해당 토큰 폐기(Revoke)
   - `pvenode acme plugin remove cf-dns` 명령으로 플러그인 제거

---

## 보존하면 안 되는 출력

- `.env` 파일 내용 및 API Token 원문
- ACME 계정 private key 및 인증서 private key 원문
- Proxmox task log 중 시크릿이 포함될 수 있는 raw dump
- `pvenode acme plugin list` 출력. `data` 컬럼이 `CF_Token` 값을 평문으로 표시한다. 어떤 토큰이 저장돼 있는지 확인할 때는 이 명령을 쓰지 말고, 값 대신 길이와 해시만 비교한다:

  ```bash
  ssh root@<pve> "awk '/^[[:space:]]*data[[:space:]]/{print \$2}' /etc/pve/priv/acme/plugins.cfg \
    | base64 -d | sed -n 's/^CF_Token=//p' | tr -d '\r\n' > /tmp/.t
    printf 'len=%s sha=%s\n' \"\$(wc -c < /tmp/.t)\" \"\$(sha256sum /tmp/.t | cut -c1-12)\"; rm -f /tmp/.t"
  ```
