# OBS-14 앱 native metric 조사 증거

2026-08-13에 PostgreSQL(`postgres-01`)·SeaweedFS(`object-01`)·Warpgate(`warpgate-01`)·
NetBird(`netbird-01`) 4개 VM에 SSH로 직접 접속해 read-only로 확인했다. 설정 파일 변경,
서비스 재시작, 방화벽·NetworkPolicy·ScrapeConfig 추가 등 라이브 변경은 0건이다.

## 제품별 확인 결과

| 제품 | 호스트 | 확인 방법 | 결과 | 판정 |
|---|---|---|---|---|
| PostgreSQL 16 | `postgres-01` (`10.10.50.10`) | `sudo ss -tlnp`, `infra/ansible/roles/postgres_baseline` 검토 | `5432`(PostgreSQL 자신)·`9100`(`OBS-11` node_exporter)·`111`(rpcbind)만 LISTEN. `postgres_exporter`·`pg_stat_statements` 등 Prometheus 노출 경로가 role에 없고 라이브에도 없음 | 미노출 |
| SeaweedFS master/volume/filer/s3 | `object-01` (`10.10.50.20`) | `sudo ss -tlnp`, `infra/ansible/roles/seaweedfs_s3/templates/seaweedfs-{master,volume,filer,s3}.service.j2` 검토 | 4개 systemd unit `ExecStart` 모두 `-metricsPort=0`으로 명시 비활성. 라이브 LISTEN도 `8333`/`18333`(s3)·`8080`/`18080`(volume)·`8888`/`18888`(filer)·`9333`/`19333`(master, 전부 loopback)뿐이며 metrics 포트 0건 | 미노출(바이너리 내장 flag는 존재하나 이 배포에서 명시적으로 꺼져 있음) |
| Warpgate v0.26.1 | `warpgate-01` (`10.10.30.10`) | `warpgate --help`/`warpgate run --help`(전체 subcommand·flag 나열), `curl -sk -L -o /dev/null -w '%{http_code} %{url_effective}' https://localhost:8888/metrics`와 `/api/health` | CLI 어디에도 metrics/prometheus 관련 옵션 없음(`setup`·`run`·`check`·`create-user`·`recover-access`·`migrate-database`·`healthcheck`뿐). `/metrics`·`/api/health` 모두 HTTP 200이지만 `url_effective`가 `https://localhost:8888/@warpgate#/login?next=...`로 바뀌어 있어 SPA 프런트엔드 catch-all 라우트로 fallback된 것이지 실제 엔드포인트가 아님 | 미노출(현재 버전에 기능 자체가 없음) |
| NetBird management | `netbird-01` (`10.10.40.10`) | `docker exec netbird-management ... management --help`, `docker exec netbird-management cat /proc/net/tcp` | `--metrics-port int`(기본 9090, "Metrics are accessible under host:metrics-port/metrics") 옵션이 존재하고 `docker-compose.yml.j2`의 `command:`가 이를 끄지 않아 기본값으로 이미 기동돼 있다. `/proc/net/tcp`의 `local_address 00000000:2382`(리틀엔디안 `0.0.0.0:9090`, `st=0A`=LISTEN)로 컨테이너 내부에서 실제 바인딩을 확인 | 컨테이너 내부에는 이미 노출되어 있으나 `docker-compose.yml.j2`가 `9090`을 host에 publish하지 않고 Traefik dynamic route도 없어 Prometheus(k3s-01, cross-VLAN)에서는 도달 불가 |

세부 raw 출력(마스킹 없음, credential·개인정보 없음)은 아래 "명령 기록"에 남긴다.

## 판단

`docs/backlog.md`의 `OBS-14` 완료 기준은 "실제 노출을 확인한 제품만 checksum 고정 scrape를
추가"이며, 각 대상은 `up=1`과 대표 시계열 최소 1개를 실제로 확인해야 한다. 4개 제품 모두
지금 시점에 Prometheus(k3s-01)에서 실제로 도달 가능한 metrics 경로가 없어 `up=1`을 낼 수 있는
대상이 하나도 없다. 따라서 이번 작업에서는 `gitops/apps/obs/`에 신규 `ScrapeConfig`·
`NetworkPolicy`를 추가하지 않았다.

NetBird는 "이미 노출 중"과 "노출하지 않음"의 경계 사례다: 바이너리는 이미 `0.0.0.0:9090`에
metrics를 내보내고 있지만, 이를 Prometheus가 스크래프하려면 (a) `docker-compose.yml.j2`가
`9090`을 `netbird-01`의 관리 주소에만 publish하도록 바꾸고 컨테이너를 재기동해야 하고,
(b) `k3s-01`(`10.10.20.10`) → `netbird-01`(`10.10.40.10`) TCP 9090 exact PASS 규칙을
OPNsense에 신규로 추가해야 한다. `OBS-14`의 잠금은 `ARGO-ROOT` 하나뿐이고 `OPNSENSE-LIVE`가
없어 이 세션의 선언된 범위 밖이므로, 라이브 config는 그대로 두고 후속 작업으로 연다.
SeaweedFS도 같은 이유(내장 flag 활성화 + 서비스 재시작 + OPNsense 신규 규칙 필요)로
동일하게 후속으로 연다. PostgreSQL은 `postgres_exporter`라는 새 컴포넌트 설치 자체가
필요해 백로그 원문이 이미 이번 작업 범위 밖으로 명시했다. Warpgate는 v0.26.1 CLI에
metrics 관련 기능이 전혀 없어 실행 가능한 후속이 없다(upstream이 지원을 추가하기 전까지
보류, 새 백로그 ID 없음).

## 후속 작업

- `OBS-15`: PostgreSQL native metric 수집 — `postgres_exporter` 신규 설치, `OPNSENSE-LIVE` 필요
- `OBS-16`: SeaweedFS `-metricsPort` 활성화·NetBird `--metrics-port` publish — 기존 바이너리
  내장 flag를 켜는 작업이지만 서비스 재구성과 `OPNSENSE-LIVE` 신규 방화벽 규칙이 모두
  필요해 이번 작업 범위 밖
- Warpgate: 새 백로그 ID 없음(현재 버전에 실행 가능한 경로가 없음)

## 명령 기록

```
# postgres-01
$ sudo ss -tlnp
LISTEN 0 200        127.0.0.1:5432  users:(("postgres",...))
LISTEN 0 4096         0.0.0.0:111   users:(("rpcbind",...))
LISTEN 0 128           0.0.0.0:22   users:(("sshd",...))
LISTEN 0 200      10.10.50.10:5432  users:(("postgres",...))
LISTEN 0 4096     10.10.50.10:9100  users:(("node_exporter-1",...))
LISTEN 0 4096       127.0.0.1:12345 users:(("alloy-loki-02",...))
$ sudo -u postgres psql -tAc "SELECT extname FROM pg_extension;"
plpgsql

# object-01
$ sudo ss -tlnp
LISTEN 0 128     10.10.50.20:8333   users:(("weed",...))   # s3
LISTEN 0 128       127.0.0.1:9333   users:(("weed",...))   # master (loopback)
LISTEN 0 128       127.0.0.1:18080  users:(("weed",...))   # volume grpc
LISTEN 0 4096    10.10.50.20:9100   users:(("node_exporter-1",...))
LISTEN 0 128       127.0.0.1:8080   users:(("weed",...))   # volume
LISTEN 0 128       127.0.0.1:18333  users:(("weed",...))   # s3 grpc
LISTEN 0 128       127.0.0.1:18888  users:(("weed",...))   # filer grpc
LISTEN 0 128       127.0.0.1:8888   users:(("weed",...))   # filer
LISTEN 0 128     10.10.50.20:18333  users:(("weed",...))   # s3 grpc (mgmt addr)
LISTEN 0 128       127.0.0.1:19333  users:(("weed",...))   # master grpc
# metrics 포트(임의 -metricsPort 값) LISTEN 0건

# warpgate-01
$ warpgate version
warpgate v0.26.1
$ warpgate --help | grep -i metric   # (출력 없음)
$ curl -sk -L -o /dev/null -w 'metrics: %{http_code} %{url_effective}\n' https://localhost:8888/metrics
metrics: 200 url_effective=https://localhost:8888/@warpgate#/login?next=%2Fmetrics
$ curl -sk -L -o /dev/null -w 'health: %{http_code} %{url_effective}\n' https://localhost:8888/api/health
health: 200 url_effective=https://localhost:8888/@warpgate#/login?next=%2Fapi%2Fhealth

# netbird-01
$ sudo docker exec netbird-management /go/bin/netbird-mgmt management --help | grep -A1 metrics-port
      --metrics-port int   metrics endpoint http port. Metrics are accessible under
                            host:metrics-port/metrics (default 9090)
$ sudo docker exec netbird-management cat /proc/net/tcp
  sl  local_address rem_address   st ...
   0: 0100007F:17AC 00000000:0000 0A ...   # 127.0.0.1:6060 (pprof, loopback)
   1: 0B00007F:9177 00000000:0000 0A ...   # 127.0.0.11:* (docker embedded DNS)
   2: 00000000:2382 00000000:0000 0A ...   # 0.0.0.0:9090  <- metrics, LISTEN(0A), 컨테이너 내부에만
   3: 040012AC:C5AA 33C6A3D5:01BB 01 ...   # outbound ESTABLISHED(01), 무관
```
