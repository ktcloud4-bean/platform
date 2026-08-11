# Warpgate PostgreSQL native session 운영

- 작업: `WG-04`
- 결정: [ADR-0024](../adr/0024-warpgate-native-postgresql-sessions.md)
- 대상: `warpgate-01`과 `postgres-01`
- 상태: live 선언·방화벽 적용 완료; 사람의 SSO/MFA 승인 session 증거 대기

## 목적과 경계

이 경로는 PostgreSQL 운영 조회 session을 Warpgate가 중계·기록하게 한다. OS SSH나
`postgres` superuser를 공유하는 경로가 아니다. 사용자 인증과 DB 권한을 다음처럼 분리한다.

```text
Warpgate password → platform-privileged → Keycloak SSO/MFA browser approval
  → postgres-ops target → TLS verify → warpgate_pg_ops (pg_monitor only)
```

`warpgate_pg_ops`는 `postgres` database에만 접속하며 `pg_monitor`만 상속한다. 서비스
database, 데이터 read/write, DDL, role/database 생성, backend signalling, superuser는 모두
허용하지 않는다. 데이터 수정·migration은 해당 서비스의 전용 role과 승인된 배포 경로가
소유한다. host 장애 복구는 기존 Warpgate SSH 후 local peer 경로를 별도로 사용한다.

login role은 `NOINHERIT`이므로 접속 직후 identity 확인에는 `current_user`가
`warpgate_pg_ops`로 보인다. `pg_monitor` catalog/statistics view가 필요한 명시적 조회 전에만
`SET ROLE pg_monitor;`를 실행하고, 끝나면 `RESET ROLE;`로 원래 login role로 돌아간다.

## 네트워크와 TLS 계약

- OPNsense ACCESS ingress에는 `warpgate-01/32 → postgres-01/32`, TCP `5432` 하나만
  추가한다. sequence는 기존 SSH rule 뒤, non-public block 앞이며 이 runbook 외의
  ACCESS/DATA source·port·NAT·public DNS는 바꾸지 않는다.
- PostgreSQL HBA는 같은 source 한 대, database `postgres`, role `warpgate_pg_ops`의
  `hostssl` 한 줄만 추가한다. `hostnossl` reject는 그대로 둔다.
- Warpgate는 TCP `55432`에서 PostgreSQL TLS를 제공한다. listener 인증서는 기존
  `warpgate.imcherry5778.xyz` 공인 내부 service certificate를 재사용한다.
- Warpgate가 upstream으로 접속할 때 `postgres-01`의 public bootstrap **CA**를 host trust
  store에 설치하고, CA:FALSE server leaf의 실제 hostname·expiry chain을 검증한다.
  `verify: false`, IP 기반 hostname 우회, plaintext PostgreSQL은 허용하지 않는다.
- 외부 NetBird 사용자의 native DB port 공개는 이 작업 범위가 아니다. 현재 관리 경로에서
  listener 도달 여부만 검증하며, 원격 peer를 추가해야 하면 별도 NetBird policy 작업으로
  exact source·TCP `55432`를 설계한다.

## 비밀과 실행

`warpgate-postgres-session.yml`은 upstream login password를 Git·명령 인자·환경 변수에
두지 않는다. 기본 path인 저장소 밖
`/home/imcherry/secrets/wg-04/pg-warpgate-ops-password`는 symlink가 아닌 mode `0600`
regular file이어야 한다.

첫 적용에서만 아래 flag를 명시하면 playbook이 48자 임의값을 생성하고 그 파일에 한 번
기록한다. 이후 실행은 기존 값을 읽기만 하며 자동 회전·덮어쓰기를 하지 않는다.

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 authenticated known_hosts> -o PasswordAuthentication=no"
ansible-playbook -i <저장소 밖 inventory> -e "@<기존 Warpgate secret vars>" playbooks/warpgate-postgres-session.yml --syntax-check
ansible-playbook -i <저장소 밖 inventory> -e "@<기존 Warpgate secret vars>" playbooks/warpgate-postgres-session.yml --check --diff
# 첫 적용에서만 wg04_create_pg_ops_password=true를 더한다.
ansible-playbook -i <저장소 밖 inventory> -e "@<기존 Warpgate secret vars>" -e wg04_create_pg_ops_password=true playbooks/warpgate-postgres-session.yml
ansible-playbook -i <저장소 밖 inventory> -e "@<기존 Warpgate secret vars>" playbooks/warpgate-postgres-session-verify.yml
```

## 운영자가 여는 session

1. 브라우저에서 `https://warpgate.imcherry5778.xyz:8888`에 특권 Keycloak ID로 로그인해
   MFA를 완료한다. 처음 native client를 쓸 때는 우측 상단 자신의 사용자 메뉴에서
   Warpgate 전용 password를 설정한다. 이 password는 Keycloak password와 다르며 password
   manager에만 저장한다.
2. 자신의 trust store가 Warpgate service certificate를 검증할 수 있는 관리 client에서
   다음처럼 target을 명시한다.

   ```bash
   psql "host=warpgate.imcherry5778.xyz port=55432 dbname=postgres user=<Warpgate-username>#postgres-ops sslmode=verify-full sslrootcert=system"
   ```

3. `psql` password prompt에는 **Warpgate 전용 password**를 입력한다. 이어서 `psql`이
   notice로 표시하는 approval URL을 이미 로그인한 브라우저에서 열고 security key가 같은지
   확인한 뒤 승인한다. URL이나 session token을 채팅·티켓·shell history에 남기지 않는다.
   현재 libpq는 `verify-full`에서 개인 `~/.postgresql/root.crt`를 우선 찾을 수 있으므로
   `sslrootcert=system`을 함께 명시한다. 시스템 trust store에 없는 사설 CA를 사용할 때만
   CA file을 `sslrootcert=<path>`로 별도 지정한다.

4. 연결 후 `SELECT current_user, current_database();`의 upstream identity는
   `warpgate_pg_ops`, database는 `postgres`여야 한다.

   `pg_monitor` view가 필요하면 별도로 `SET ROLE pg_monitor;`를 실행한다. 데이터
   table이나 service database로의 read/write·DDL은 이 session에서 허용되지 않는다.

`platform-privileged`가 없거나 pre-registered Warpgate SSO user가 아닌 계정은 target
선택/approval 단계에서 거부되어야 한다. Keycloak password를 `psql` password로 넣지 않는다.

## 감사 열람 역할

`/platform-privileged`는 SSH·PostgreSQL target을 연결하는 **access role**이고, Warpgate
관리 UI를 열지 않는다. 세션 metadata·PostgreSQL query log·recording만 읽어야 하는 운영자는
Keycloak `platform` realm의 `/warpgate-auditors` group과 Warpgate
`warpgate-audit-reader` **Admin role**을 함께 받아야 한다. 이 Admin role은
`sessions_view`와 `recordings_view`만 허용하며 target·user·role·ticket·config 변경 또는
세션 종료 권한을 주지 않는다.

`imcherry5778-admin`은 최초 audit reader 멤버지만, master realm의
`imcherry-kc-recovery`와 Warpgate 로컬 `admin`은 break-glass 경계에 남기므로 이 group을
받지 않는다. OIDC group claim은 새 로그인 때 동기화되므로, 멤버십 변경 뒤에는 해당
특권 계정으로 Warpgate에서 로그아웃 후 다시 SSO 로그인한다.

기존 realm에는 bootstrap 선언만으로 새 group membership이 소급되지 않는다. 이 저장소의
수렴 도구를 **복구 계정 소유 운영자**가 다음처럼 실행한다. 도구는 `/warpgate-auditors`
top-level group 하나와 `imcherry5778-admin` membership 하나만 만들며, platform realm에
같은 이름의 recovery ID가 있고 이 group에 들어가 있으면 변경 없이 실패한다.

```bash
export KTC_SECRET_ROOT=/home/imcherry/secrets/ktcloud4-bean
export KC01_CONNECT_IP=10.10.20.10
bash gitops/tools/wg-04/manage-warpgate-auditors.sh --check
bash gitops/tools/wg-04/manage-warpgate-auditors.sh --apply
```

Warpgate의 `warpgate-audit-reader` Admin role은 별도 로컬 `admin` credential을 external
mode `0600` vars file로 전달해 `warpgate-postgres-session.yml`을 적용할 때만 생성·수정된다.
기존 값을 찾을 수 없고 승인된 경우에는 `warpgate-local-admin-recovery.yml`을 사용한다.
이 entrypoint는 현재 product SQLite의 **online backup**을 먼저 만들고 새 password credential을
추가하며, 로컬 `admin`의 HTTP 인증 정책만 Password-only로 수렴시킨다. 기존 password
credential을 삭제하지 않으며 Keycloak SSO user·target·role은 바꾸지 않는다.
recovery command는 반드시 운영 service와 같은 `warpgate` 계정·`/var/lib/warpgate` working
directory에서 실행한다. root 기본 working directory에서 실행하면 다른 SQLite path를 열 수
있으므로 허용하지 않는다.

```bash
cd infra/ansible
ansible-playbook -i <저장소 밖 inventory> \
  -e wg04_recover_local_admin=true \
  playbooks/warpgate-local-admin-recovery.yml
```

이 작업은 새 값을 `/home/imcherry/secrets/wg-04/warpgate-admin-vars.yml` mode `0600`에만
작성한다. prompt 입력은 shell history·Git·log에 남지 않는다. 로컬 admin 비밀번호를 이미
알고 있고 이 file만 없는 경우에는 다음처럼 외부 file을 만들 수 있다.

```bash
install -d -m 0700 /home/imcherry/secrets/wg-04
read -rs 'WG-04 existing local Warpgate admin password: ' WG04_WG_ADMIN
printf '\n'
printf 'warpgate_admin_password: |-\n  %s\n' "$WG04_WG_ADMIN" \
  > /home/imcherry/secrets/wg-04/warpgate-admin-vars.yml
chmod 0600 /home/imcherry/secrets/wg-04/warpgate-admin-vars.yml
unset WG04_WG_ADMIN
```

그 뒤 위 **비밀과 실행** 절의 `<기존 Warpgate secret vars>` 위치에 이 file을 전달해
playbook을 적용한다. 적용 뒤 audit reader는 Warpgate에서 로그아웃·재로그인한 다음 Admin
UI의 Sessions와 Recordings만 열 수 있어야 한다. PostgreSQL query log는 해당 native session이
열려 있는 동안 Sessions 화면에서만 확인한다.

## OPNsense 적용·rollback·증거

방화벽은 `OPNSENSE-LIVE` 단독 lock과 적용 직전 승인이 필요하다. 새 rule은 disabled로
생성해 API GET readback에서 interface, source, destination, TCP `5432`, quick/log/keep
state와 sequence를 대조한 뒤 enable하고 filter apply를 한 번 실행한다.

실패하면 새 UUID 하나만 disable → apply → delete → apply 순서로 되돌린다. Warpgate
listener·target과 PostgreSQL HBA/role은 이 경로를 닫아도 다른 서비스 database에는 영향을
주지 않는다. OPNsense snapshot은 API backup, `infra/opnsense/config.xml`은 적용 뒤
`check-drift.sh --update`로만 갱신한다.

완료 증거는 다음 하나의 session 검증으로 한정한다.

1. API/PF/HBA가 exact 경로 하나만 허용함을 확인한다.
2. `warpgate-postgres-session-verify.yml` temporary local verifier의 TLS `psql`이 `postgres-ops`를 통해 연결되고 upstream
   `warpgate_pg_ops`·`pg_monitor` 최소권한을 확인한 뒤 verifier를 제거한다.
3. target에 없는 verifier는 거부되고, session recording metadata에는 허용 session 하나가
   남는다.
4. 사람이 수행하는 Keycloak SSO/MFA Web approval은 별도 사용자 증거로만 확인하며
   자동 verifier가 사람을 가장하지 않는다.
5. 같은 playbook 두 번째 실행은 `changed=0`, OPNsense normal drift는 없음이어야 한다.

## 2026-08-11 live 적용 기록

OPNsense `opt3`에 `WG-04: Warpgate PostgreSQL TLS TCP 5432 session relay 허용` rule을
sequence `1120`, UUID `cdb5d60d-91be-4144-b4eb-e74dcd652dfb`로 disabled stage 후 API
semantic readback, enable, filter apply 순서로 적용했다. 적용 직후 `check-drift.sh --update`와
일반 `check-drift.sh`는 모두 통과했다. 뒤이은 실제 Web approval session에서 기존
PostgreSQL self-signed certificate가 `CA:TRUE`인 server leaf여서 Warpgate strict TLS가
거부함을 확인했다. 이 전환은 기존 public trust anchor를 CA로 보존하고 CA:FALSE leaf만
교체하므로 다른 `verify-full` client의 trust bundle은 바꾸지 않는다.

`warpgate.imcherry5778.xyz:8888` 관리 API의 TLS 검증과 native PostgreSQL listener
`:55432`의 TCP reachability도 확인했다. 실제 운영자가 Keycloak SSO/MFA Web approval 뒤
`warpgate_pg_ops` upstream identity로 session을 열었고, `/warpgate-auditors` membership을
받은 `imcherry5778-admin`의 새 SSO 로그인에서 Sessions·Recordings 읽기 전용 Admin role도
확인했다. `imcherry-kc-recovery`에는 이 일상 감사 group을 부여하지 않아 복구 경계를 유지한다.
