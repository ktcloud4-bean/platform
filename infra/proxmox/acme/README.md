# Proxmox VE 네이티브 ACME 관리 TLS (DNS-01)

이 디렉터리는 Proxmox VE 내장 ACME 기능과 Cloudflare DNS-01 API를 사용해 `docs/ip-plan.md`의 canonical 호스트 `proxmox-01.imcherry5778.xyz`에 대한 신뢰할 수 있는 공인 TLS 인증서를 발급·관리하는 입력 절차와 스크립트를 소유한다.

선택 근거, 설계 경계 및 대안 분석은 [ADR-0009](../../docs/adr/0009-proxmox-native-acme-management-tls.md)을 따른다.

---

## 1. 주요 원칙 및 경계

1. **포트 및 경로 유지**: HTTPS 8006 관리를 그대로 유지하며 public A/AAAA, Cloudflare proxy, NAT, reverse proxy 또는 443 listener를 만들지 않는다.
2. **독립된 소유권**: OPNsense wildcard 인증서 및 개인키를 공유하지 않고, Proxmox가 자체 ACME 계정과 인증서/개인키를 직접 소유한다.
3. **최소 권한 전용 토큰**: Cloudflare API Token은 `imcherry5778.xyz` zone 전용으로 `Zone - DNS - Edit` 권한만 부여한다. Global API Key나 다른 ACME client 토큰을 재사용하지 않는다.
4. **시크릿 노출 차단**: 토큰 및 개인키를 Git, 명령 인자(argv), 프로세스 목록, 셸 기록, SSH 커맨드라인, 일반 로그에 남기지 않으며, mode `0600` 입력 파일만 지원한다.

---

## 2. 파일 구성

- `.env.example`: 설정 입력을 위한 템플릿 (비밀 없는 예시 값만 선언)
- `scripts/setup-acme.sh`: Staging / Rollback / Production / Verify 실행 제어 스크립트
- `scripts/test-acme.sh`: 스크립트 구문 검사, shellcheck, 시크릿 누출 방지 및 파서 검증 스크립트

---

## 3. 시크릿 입력 및 설정 준비

`infra/proxmox/acme/.env` (또는 저장소 루트의 `.env`)에 다음 항목을 선언한다 (파일 mode `0600` 필수).

```env
CLOUDFLARE_API_TOKEN=your_scoped_cloudflare_api_token
PROXMOX_ACME_EMAIL=admin@imcherry5778.xyz
```

`.env` 파일은 셸로 `source`하지 않으며, 스크립트가 안전한 키 추출 방식을 사용하여 `CF_Token` 값만 Proxmox 보호 데이터 파라미터로 전달한다.

---

## 4. 운영 및 검증 순서

### Step 1: 회귀 테스트 및 검증
```bash
./infra/proxmox/acme/scripts/test-acme.sh
```

### Step 2: Let's Encrypt Staging 계정 발급 검증
```bash
./infra/proxmox/acme/scripts/setup-acme.sh staging
```
- Staging 계정 `le-staging` 등록 및 `cf-dns` 플러그인 생성
- node domain `proxmox-01.imcherry5778.xyz` 고정 후 cert order
- DNS `_acme-challenge` TXT 생성 및 발급 직후 정리 검증
- Staging SAN 및 발급자 일치 확인

### Step 3: PVE 기본 CA 복원 (Rollback 드릴)
```bash
./infra/proxmox/acme/scripts/setup-acme.sh rollback
```
- Custom 인증서를 삭제(`pvenode cert delete --restart 1`)하여 설치 시 PVE Cluster Manager CA 자체 서명 인증서로 복원
- `pveproxy` 서비스 정상 가동 및 8006 접속 가능 여부 확인

### Step 4: Let's Encrypt Production 인증서 발급
```bash
./infra/proxmox/acme/scripts/setup-acme.sh production
```
- Production 계정 `le-production` 등록 및 cert order (rate limit 방지를 위해 1회만 진행)
- Let's Encrypt 공인 서명 인증서 반영 및 `pveproxy` 갱신

### Step 5: Strict TLS 및 라이브 최종 검증
```bash
./infra/proxmox/acme/scripts/setup-acme.sh verify
```
- SAN이 `proxmox-01.imcherry5778.xyz`와 일치하는지 확인 (wildcard 및 내부 IP 포함되지 않음)
- 시스템 trust store 기반 `curl https://proxmox-01.imcherry5778.xyz:8006/` HTTP 200 응답 확인 (insecure 우회 옵션 금지)
- `_acme-challenge` TXT 잔여물 없음 확인
- `pve-daily-update.timer` 자동 갱신 타이머 및 account/plugin/domain 연결 확인

---

## 5. Token 회전 (Rotation) 및 폐기 (Revocation) 절차

1. **토큰 회전 (Token Rotation)**:
   - Cloudflare 대시보드에서 새 `Zone - DNS - Edit` 토큰을 발급받는다.
   - `.env` 파일의 `CLOUDFLARE_API_TOKEN` 값을 새 토큰으로 교체한다.
   - `./infra/proxmox/acme/scripts/setup-acme.sh production` 또는 `setup_plugin`을 재실행하여 Proxmox의 `cf-dns` plugin data를 갱신한다.
   - 기존 Cloudflare 토큰을 폐기한다.

2. **토큰 및 인증서 폐기 (Revocation & Cleanup)**:
   - 비상시 인증서를 폐기할 때는 `pvenode acme cert revoke` 명령을 실행한다.
   - Cloudflare 대시보드에서 해당 API 토큰을 `Revoke`하여 즉시 만료시킨다.
   - Proxmox 노드에서 ACME 플러그인 삭제: `pvenode acme plugin remove cf-dns`
