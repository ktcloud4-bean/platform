# PostgreSQL 16 기준선 및 런북 (`docs/runbook/postgres-baseline.md`)

- 검증일: 2026-07-31 (`PG-01` 라이브 검증 통과)
- 대상 VM: `postgres-01` (`10.10.50.10` / VMID 150 / Rocky Linux 9.8)

## 1. 버전 및 패키지 공급망

- **PostgreSQL 버전**: `16.14` (`postgresql-server-16.14-1.module+el9.8.0+40212+d6f50005.x86_64`)
- **저장소**: Rocky Linux 9 Official `appstream` 모듈 (`@postgresql:16` stream)
- **GPG 서명**: Rocky Release Key ID `702d426d350d275d` (RPM GPG 서명 검증)
- **패키지 구성**: `postgresql-server`, `postgresql-contrib`, `python3-psycopg2`, `openssl`

## 2. 보안 및 액세스 통제

- **listen_addresses**: `127.0.0.1,10.10.50.10` (DATA VLAN 전용 인터페이스 및 loopback)
- **원격 인증**: `hostssl` 필수, auth method `scram-sha-256`
  - `hostnossl 0.0.0.0/0 reject` 명시적 차단
  - `trust` 전면 금지, 광범위 `0.0.0.0/0` 금지
- **TLS 부트스트랩**: host-specific leaf 인증서 (`CN=postgres-01.imcherry5778.xyz`, SAN: `DNS:postgres-01.imcherry5778.xyz, IP:10.10.50.10`)
  - 공개 leaf 사본: `/etc/pki/tls/certs/postgres-01-bootstrap.crt` (`0644`)
  - 클라이언트 필수 검증: `sslmode=verify-full`
- **최소 권한 서비스 역할**:
  - `keycloak_user`: NOSUPERUSER, NOCREATEDB, NOCREATEROLE, NOREPLICATION, `keycloak` DB 전용
  - `verify_user`: NOSUPERUSER, NOCREATEDB, NOCREATEROLE, NOREPLICATION, `verify_db` DB 전용
  - `PUBLIC` 스키마 접근 회수: `REVOKE ALL ON SCHEMA public FROM PUBLIC;`

## 3. Ansible 플레이북 실행 및 멱등성 검증

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 known_hosts> -o PasswordAuthentication=no"

# Syntax check
ansible-playbook -i <저장소 밖 inventory> playbooks/postgres-baseline.yml --syntax-check

# Check mode & diff
ansible-playbook -i <저장소 밖 inventory> playbooks/postgres-baseline.yml --check --diff

# Apply
ansible-playbook -i <저장소 밖 inventory> playbooks/postgres-baseline.yml

# Idempotency re-run (expect changed=0, failed=0)
ansible-playbook -i <저장소 밖 inventory> playbooks/postgres-baseline.yml
```

## 4. 라이브 검증 및 회귀 시험

1. **서비스 및 RPM 서명**: `systemctl is-active postgresql` 및 `rpm -qi postgresql-server`
2. **verify-full TLS 연결**:
   ```bash
   PGSSLMODE=verify-full PGSSLROOTCERT=/etc/pki/tls/certs/postgres-01-bootstrap.crt psql -h postgres-01.imcherry5778.xyz -U verify_user -d verify_db -c "SELECT pid, ssl, version, cipher FROM pg_stat_ssl WHERE pid = pg_backend_pid();"
   ```
3. **sslmode=disable 차단 확인**: `PGSSLMODE=disable psql -h postgres-01.imcherry5778.xyz -U verify_user -d verify_db` (접속 거부 확인)
4. **외부 VLAN 차단 확인**: `netbird-01`(VLAN 40) 및 `warpgate-01`(VLAN 30)에서 `timeout 3 bash -c '</dev/tcp/10.10.50.10/5432'` 차단 입증
5. **기본 논리 복구 시험**:
   ```bash
   sudo -u postgres pg_dump -F c -b -f /var/lib/pgsql/verify_db.dump verify_db
   sudo -u postgres psql -c "CREATE DATABASE recovery_db OWNER verify_user;"
   sudo -u postgres pg_restore -d recovery_db /var/lib/pgsql/verify_db.dump
   sudo -u postgres psql -c "DROP DATABASE recovery_db;"
   ```

## 5. 복구 및 롤백 절차

- **롤백 수단**: `postgres-01` 게스트 내 패키지 및 서비스 롤백 (`dnf remove postgresql-server postgresql-contrib`, `rm -rf /var/lib/pgsql/data`).
- **금지 사항**: OpenTofu state 변경, VM 디스크 삭제/재생성, OPNsense 방화벽 규칙 변경, Proxmox 가상화 설정 변경 금지.
