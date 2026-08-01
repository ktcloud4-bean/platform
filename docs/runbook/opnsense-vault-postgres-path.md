# OPNsense Vault → PostgreSQL 최소 경로

- 작업: `NET-03A`
- 적용일: 2026-08-01
- 범위: `k3s-01`에서 NAT된 Vault Pod TCP source와 `postgres-01`의 PostgreSQL TLS 포트 사이의 단일 IPv4 경로

## 판정

Vault Pod에서 `10.10.50.10:5432`으로 보낸 SYN의 실제 source는 Pod IP가 아니라
`k3s-01`의 `10.10.20.10`이다. OPNsense `vlan02`의 RFC1918 block rule이 이를
match하고, `vlan05`에는 packet이 도달하지 않았다.

동시에 MGMT control `10.10.10.10 → 10.10.50.10:5432`은 SYN/SYN-ACK까지
성공했다. 그러므로 PostgreSQL listener, DATA routing, DATABASE VM host firewall은
원인이 아니며, enforcement point는 PLATFORM ingress PF다.

이는 Vault DB engine의 네트워크 전제만 보정한다. DB role·동적 credential·
`sslmode=verify-full`와 CA 전달은 `VAULT-02`에서 구현·검증한다.

## 허용 정책

| 항목 | 값 |
|---|---|
| interface / direction | `opt2` (PLATFORM / `vlan02`) / inbound |
| family / protocol | IPv4 / TCP |
| source | `10.10.20.10` (k3s-01 NAT source 한 대) |
| destination | `10.10.50.10:5432` (postgres-01) |
| action / state / log | PASS / keep / enabled logging |
| sequence | `1016` — S3 `1015` 뒤, RFC1918 BLOCK `1020` 앞 |
| description | `NET-03A: Vault DB engine용 k3s-01에서 postgres-01 TLS TCP 5432만 허용; NET-04에서 실제 통신표로 재검토` |

단일 노드 k3s의 Pod egress가 node IP로 NAT되므로 PF만으로 Vault Pod 하나를
식별할 수 없다. 이 rule은 k3s-01에서 시작하는 TCP 5432 시도만 통과시키며,
PostgreSQL의 `hostssl`·SCRAM 및 `VAULT-02`의 database policy가 다음 경계다.
VLAN 전체, 다른 DATA host, 다른 포트, NAT/DNS/interface/IPv6은 바꾸지 않는다.

## 사전 조건과 중단 기준

1. `NET-03`, `PG-01`, `VAULT-01`이 모두 `DONE`이고 `OPNSENSE-LIVE` lock이 단독이어야 한다.
2. 전용 branch/worktree, clean main 비교, strict OPNsense SSH/HTTPS가 살아 있어야 한다.
3. PiKVM의 strict SSH와 `kvmd active`를 확인한다.
4. `check-drift.sh`가 인증된 TLS로 `드리프트 없음`이어야 한다.
5. API `search_rule?interface=opt2&show_all=1`에서 S3 `1015`, RFC1918 block
   `1020`, 기존 5432 rule 부재를 확인한다.
6. 실제 Vault Pod의 실패 probe와 `vlan02` PF block counter/packet capture,
   MGMT TCP 5432 SYN/SYN-ACK control을 같은 시점에 다시 확인한다.

하나라도 다르면 쓰지 않는다. 특히 PiKVM, strict 관리면, drift, 순서가 다르면
차이를 보고하고 중단한다.

## 적용과 rollback

원본 config는 API `GET /api/core/backup/download/this`로 저장소 밖 mode 0700
evidence directory에 mode 0600으로 저장하고 SHA-256만 기록한다. `config.xml`은
정규화된 drift snapshot이므로 apply 입력으로 쓰지 않는다.

1. `POST /api/firewall/filter/add_rule`에 `rule` object를 전송해
   `enabled=0`으로 rule 하나를 저장한다.
2. 반환 UUID의 `GET /api/firewall/filter/get_rule/{uuid}`와 전체 search에서
   interface, sequence, protocol, source, destination, port, description을 대조한다.
3. 값이 다르면 `POST /api/firewall/filter/del_rule/{uuid}`만 수행하고
   `POST /api/firewall/filter/apply` 후 중단한다.
4. 일치할 때만 `POST /api/firewall/filter/toggle_rule/{uuid}/1`와
   `POST /api/firewall/filter/apply`을 각각 한 번 수행한다.

자동 savepoint rollback은 가정하지 않는다. rollback은 생성 UUID만
disable → apply → delete → apply 순으로 처리한다. 관리면 이상이면 재시도하거나
광범위 rule을 추가하지 말고 PiKVM에서 작업 직전 OPNsense revision을 복원한다.
재부팅은 이 작업의 범위가 아니다.

## 완료 검증

1. API 저장 rule와 PF runtime rule/counter가 새 UUID와 정확히 일치한다.
2. Vault Pod에서 `10.10.50.10:5432` TCP connect가 성공하고, capture에서
   `vlan02` SYN 및 `vlan05` SYN/SYN-ACK을 확인한다.
3. Vault Pod 연결 실패의 원인이 TCP 경계가 아님을 확인하기 위해 TLS
   `verify-full` handshake는 `VAULT-02`에서 별도 증명한다.
4. k3s-01 → object-01 TCP 8333 control, OPNsense SSH/HTTPS, PiKVM, k3s Node,
   Vault pod가 모두 정상이어야 한다.
5. `check-drift.sh --update` 후 다시 일반 drift 검사에서 `드리프트 없음`을 확인한다.

Git에는 정상화된 `infra/opnsense/config.xml`, rule UUID, config SHA-256, 검증
결과만 남긴다. API secret, 원본 config, curl auth config, packet payload는 남기지 않는다.

## 2026-08-01 실행 증거

- 사전 게이트: strict OPNsense SSH/HTTPS, PiKVM `kvmd active`, 인증된 일반
  drift 없음, k3s Node `Ready`, `vault-0` `Running`을 모두 확인했다.
- 저장소 밖 mode 0700 evidence directory에 작업 전 config를 mode 0600으로 보관했다.
  SHA-256은 `52e0e83d2e581cf885eec7fadb86dedb68b057ddb89effb5a3dd39cbc44c030f`이다.
- 새 rule UUID는 `c23d9b13-b3a0-4205-852f-89e11d5cfe97`이다. API 저장값은
  `opt2/in/inet/TCP/10.10.20.10/10.10.50.10/5432/pass/keep/log/1016`과
  description이 계획과 정확히 일치했다.
- 실제 `vault-0`의 TCP probe는 source `10.10.20.10`으로 나갔고,
  `vlan02`와 `vlan05` 양쪽 capture에서 SYN, SYN-ACK, ACK을 확인했다.
  PF `@99`는 새 UUID label로 로드되어 evaluations 1, packets 7, states 1을
  기록했다.
- 기존 k3s-01 → object-01 TCP 8333 control, OPNsense strict SSH/HTTPS,
  PiKVM, k3s Node 및 Vault Pod 상태는 모두 정상이다. 재부팅은 하지 않았다.
- `check-drift.sh --update` 뒤 일반 drift가 없고, OPNsense drift 도구의
  unittest 18개와 `git diff --check`가 통과했다.

초기 staged rule은 toggle API 성공 문자열의 대소문자 차이를 안전장치가 실패로
판정해 PF apply 전에 삭제했다. 그 UUID는 사용하지 않았고, 최종 저장 정책과
runtime에는 위 UUID 하나만 남아 있다.
