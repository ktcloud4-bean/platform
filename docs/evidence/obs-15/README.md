# OBS-15 PostgreSQL native metric 증거

2026-08-13에 PostgreSQL native metric 수집을 한 번 적용·검증한 결과다. Secret·DB
password·role password hash는 기록하지 않았다.

## 선언과 최소권한

- `postgres_exporter` v0.20.1 Linux AMD64 release asset은 SHA-256
  `89d4f7e7920cad48fdc3133f789556ef5253c330a9f5fdace3bdb6344c0a8b5a`로 고정했다.
- exporter HTTP endpoint는 `postgres-01` 관리 주소 `10.10.50.10:9187`만 listen한다.
  PostgreSQL TCP listener·`pg_hba.conf`·Secret은 바꾸지 않고 `/var/run/postgresql` Unix
  socket의 local peer 인증을 사용한다.
- DB role `postgres_exporter`는 passwordless `LOGIN`, `postgres` DB `CONNECT`,
  `pg_read_all_stats`만 갖는다. superuser·database/role creation·replication·BYPASSRLS·
  `pg_monitor`·`pg_read_all_data`는 없음을 Ansible assertion으로 확인했다.
- `stat_database` collector만 유지해 `pg_stat_database_xact_commit`을 노출하며 query text나
  `pg_stat_statements` 수집은 활성화하지 않았다.

## OPNsense 경계

`k3s-01`(`10.10.20.10`)에서 `postgres-01`(`10.10.50.10`) TCP 9187만 허용하는 `opt2`
ingress PASS를 disabled stage → 의미값 확인 → enable·apply 순서로 추가했다.

| UUID | sequence | PF runtime | 판정 |
|---|---:|---:|---|
| `32241b15-a17d-4214-b617-fdbc9538d046` | 1008 | `pf_rules=1` | 통과 |

rule은 기존 NET-04 비공개 목적지 BLOCK(sequence 1022)보다 앞에 있고, source·destination·
port 외 wildcard는 없다. snapshot 승인 뒤 일반 drift 검사는 무변경이었다.

## immutable GitOps 검증

| acceptance | 라이브 증거 | 판정 |
|---|---|---|
| Argo | root `b701ef681b061c9098b0e188dc1cedf2da110b81`, obs `d1b7febb60916dd858a49ed1d9d5232727b782ab`가 각각 immutable `Synced/Healthy` | 통과 |
| target | `up{instance="postgres-01.imcherry5778.xyz"}=1`, job `postgres-exporter` 한 건 | 통과 |
| 대표 시계열 | `count(pg_stat_database_xact_commit{instance="postgres-01.imcherry5778.xyz"})=9` | 통과 |
| rollback | literal `main` `4b435d8acb1aafd79f3d739d775f3a2c9f3d6570`에서 `platform-root`·`obs` 모두 `Synced/Healthy` | 통과 |

## rollback 범위

- Ansible: `postgres-exporter-rollback.yml`이 exporter systemd unit·binary/cache·OS/DB role만
  제거한다. DB `CONNECT`와 `pg_read_all_stats` membership을 먼저 회수해 PostgreSQL role
  dependency 없이 삭제한다.
- OPNsense: `gitops/tools/obs-15/apply-firewall.sh rollback <STATE_DIR>`이 생성 UUID 하나만
  disable → apply → delete → apply 순서로 제거한다.
- GitOps: `postgres-exporter` ScrapeConfig와 Prometheus egress TCP 9187 한 port만 원복한다.
  기존 PostgreSQL TCP 5432·node_exporter TCP 9100·Service/Ingress/DNS/PVC/Secret은 대상이 아니다.
