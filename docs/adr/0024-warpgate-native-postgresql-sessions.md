# ADR-0024: PostgreSQL 운영 세션을 Warpgate native TLS relay로 중계

- 상태: `Accepted`
- 관련 작업: `WG-04`

## 배경

현재 `postgres-01`은 서비스별 role·database, TLS와 SCRAM을 사용한다. 운영자가 SSH로
접속해 local peer `postgres`로 `psql`을 여는 경로는 break-glass에 필요하지만, 이 경로는
DB 작업을 Warpgate의 protocol-aware session 기록으로 분리하지 못한다.

## 결정

운영 DB 세션은 Warpgate의 native PostgreSQL listener를 통해 중계한다. listener는
Warpgate의 기존 공인 내부 service TLS 인증서를 사용하고, upstream `postgres-01`에는
hostname 검증을 포함한 TLS를 강제한다.

- `platform-privileged` 역할만 `postgres-ops` target을 본다.
- native PostgreSQL 연결은 사용자의 Warpgate password로 1차 인증하고, 이미 Keycloak
  SSO/MFA를 마친 브라우저의 Web approval을 2차로 추가 요구한다. Keycloak password는
  PostgreSQL client에 쓰지 않는다.
- upstream은 `warpgate_pg_ops` 전용 login role 하나다. 이 role은 `pg_monitor`와
  `postgres` database의 `CONNECT`만 받고 superuser·DDL·role/database 생성·서비스
  database 연결 권한을 받지 않는다.
- HBA와 OPNsense는 `warpgate-01` 한 대에서 `postgres-01:5432`로 가는 hostssl TCP
  경로 하나만 연다. 다른 ACCESS host, database, user, non-TLS 연결은 계속 거부한다.
- local peer `postgres`와 Warpgate SSH target은 장애 복구·host-level 작업의 독립
  break-glass로 보존하며, 일반 DB 운영 세션의 대체 수단으로 쓰지 않는다.

## 검토한 대안

1. SSH 뒤의 local `psql`: 별도 DB listener와 방화벽 변경은 없지만 DB protocol 세션
   기록·승인이 없고 원격 OS 특권이 먼저 필요하다.
2. 운영자 NetBird peer에서 PostgreSQL에 직접 연결: client마다 HBA·방화벽과 DB
   credential을 넓혀야 하며 recorder/approval 경계를 우회한다.
3. PostgreSQL superuser를 Warpgate target에 설정: audit이 있어도 권한 범위가 지나치게
   넓고 서비스 database 격리를 무너뜨린다.

## 결과

일상 운영은 SSO/MFA → target role → browser approval → Warpgate recording → 최소권한
upstream role 순서를 따른다. DB 데이터 수정이나 구조 변경이 필요한 경우에는 전용
migration/service role 또는 별도 승인된 break-glass 절차를 사용해야 한다.

## 재검토 조건

- DBA 운영에 필요한 최소 권한이 `pg_monitor`를 넘거나, 역할 분리된 read/write DB
  target이 필요해질 때
- Warpgate가 PostgreSQL session recording 또는 browser approval을 더 이상 지원하지
  않을 때
- 운영자별 JIT DB credential, PAM, 다중 PostgreSQL cluster/HA가 도입될 때
