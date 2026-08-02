# 보안·운영 이벤트 분류와 보존 표준

- 소유 작업: `AUDIT-01`
- 상위 결정: [ADR-0007](adr/0007-detection-and-observability-staging.md)
- 구현 작업: `LOKI-01`, `WAZUH-01`
- 용량 단일 원본: [자원 예산과 정지 기준](capacity-plan.md)

이 문서는 Suricata, CrowdSec AppSec, Falco, Kubernetes, Vault, Keycloak, Pomerium,
NetBird와 Warpgate 이벤트의 중앙 수집 경계를 소유한다. 주소, 배치와 실행 설정은 각 소스의
기존 단일 원본을 따른다. 이 문서는 수집기 설치, audit device 추가, Loki·Wazuh 배포 또는
retention 실제 적용을 하지 않는다.

## 1. 분류 원칙

1. 탐지, 인증·인가, 권한·설정 변경, API 감사와 특권 세션 metadata는 **보안 이벤트**다.
   각 소스에서 Wazuh로 직접 보낸다.
2. 기동·종료, readiness, leader/reconcile, storage·driver·output 오류와 일반 서비스 상태는
   **운영 로그**다. Loki로 보낸다.
3. 같은 원본 이벤트를 Wazuh와 Loki 양쪽에 넣지 않는다. 한 stdout에 두 종류가 섞이면
   allowlist parser가 먼저 분류·마스킹한 뒤 정확히 한 출력으로만 보낸다. Loki를 Wazuh의
   relay로 쓰지 않는다.
4. 메트릭과 숫자형 상태는 이 로그 경로에 복제하지 않는다. Prometheus 계열 구현이 소유한다.
5. request/response body, packet payload, token·cookie·Secret 값, command argument, 환경변수,
   파일 내용과 세션 recording 원문은 중앙 저장소에 넣지 않는다.
6. 제품 로컬 DB·회전 파일은 직접 수집의 source/buffer이지 두 번째 중앙 검색 저장소가 아니다.
   이 표준의 보존기간은 중앙 저장소 기준이며, 기존 제품 로컬 보존은 더 길게 늘리지 않는다.

특정 소스 전체를 수집 대상에서 제외하지 않았고 ADR-0007의 Wazuh/Loki 역할을 바꾸지 않았으므로
새 ADR은 만들지 않는다. `수집하지 않음`은 소스 전체가 아니라 원문 payload·중복 stage·메트릭
같은 event class 또는 field에만 적용한다.

## 2. 실제 출력 형태 확인

2026-08-03에 이벤트를 새로 유발하지 않고 소스별 한 건의 기존 record만 읽었다. 원문 값은
기록하지 않고 key와 자료형만 확인했다. 라이브 조회를 생략한 Warpgate는 `WG-01`이 이미 실제
판정한 감사 record를 사용했다.

| 소스 | 확인한 원본과 형식 | 확인한 안전한 구조 | 판정 |
|---|---|---|---|
| Suricata | OPNsense `eve.json`의 기존 `event_type=alert` JSON 한 건 | `timestamp`, `flow_id`, interface, 5-tuple, `alert.{action,category,gid,signature_id,rev,signature,severity}`, flow 통계 | payload 비활성 기존 경계 유지 |
| CrowdSec AppSec | AppSec Pod의 기존 logfmt 한 건과 공식 AppSec alert schema | stdout은 `time`, `level`, `module`, `type`, `msg`, `runner_uuid`; alert context는 `request_uuid`, `rule_ids`, `rule_name`, `source_ip`, `target_host`, `target_uri` | stdout 원문이 아니라 구조화한 match/alert만 보안 event로 채택 |
| Falco | Falco Pod의 기존 JSON rule event 한 건 | `time`, `rule`, `priority`, `source`, `hostname`, `output_fields`; 현재 필드는 namespace, Pod, container, process | 기존 제한 출력 유지 |
| Kubernetes | 기존 `core/v1 Event` 한 건 | event 시각, `reason`, `type`, `count`, reporting component, involved object UID | API audit 파일은 현재 없음; `WAZUH-01`이 `audit.k8s.io/v1` Metadata 계약을 구현 |
| Vault | `stdout/` audit device의 기존 JSON 한 건 | `time`, `type`, `auth`, `request`, `response`; `request.id`, operation, path, remote endpoint | token·header·data 계열은 값이 HMAC이어도 제거 |
| Keycloak | 기존 `org.keycloak.events` logfmt 한 건 | `type`, realm/client/user ID, username, source IP, auth method/type, `code_id`, error | 앱 record 자체에 timezone이 없어 CRI envelope 시각 사용 |
| Pomerium | 기존 authorize JSON 한 건 | `time`, `request-id`, `check-request-id`, `session-id`, user/email, route, method/path/host/IP, allow/deny와 이유 | 보안 판단 record와 운영 record를 service/action으로 분리 |
| NetBird | 기존 `events.db` row 한 건 | `timestamp`, `activity`, `id`, `initiator_id`, `target_id`, `account_id`, JSON `meta`; 시각은 timezone 포함 | 이벤트 ID는 request ID가 아니라 source-local event ID |
| Warpgate | [WG-01 실제 감사 판정](runbook/warpgate-privileged-access.md#판정-항목) | `UserAuthenticated1`, `UserAuthenticationFailed1`, `TargetSessionStarted1`, `TargetSessionEnded1`, session/recording metadata | 로컬 host key가 인증되지 않은 경로로 새 조회하지 않음 |

CrowdSec 필드 계약은 [공식 AppSec alert 예시](https://docs.crowdsec.net/docs/appsec/vpatch_and_crs/#alert-inspection),
Kubernetes API 감사 필드 계약은 [공식 `audit.k8s.io/v1` Event schema](https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/#audit-k8s-io-v1-Event)를
따른다. 제품 버전 변경으로 schema가 달라지면 구현 작업은 수집을 시작하지 말고 이 표준을 먼저
갱신한다.

## 3. 공통 필수 필드

중앙 event는 아래 이름으로 정규화한다. 원본 key는 parser 검증용으로 보존할 수 있지만 검색
계약은 이 표의 이름이다.

| 필드 | 필수 조건 |
|---|---|
| `event.time` | source event 시각을 UTC RFC 3339로 정규화한다. 소수초를 보존하고 timezone 없는 앱 시각은 사용하지 않는다. Kubernetes container log는 CRI envelope 시각을 쓴다. |
| `event.ingested` | collector가 받은 UTC RFC 3339 시각. source 시각의 대체값이 아니며 clock drift 조사에만 쓴다. |
| `event.source`, `event.dataset` | 제품과 event family. 예: source=`vault`, dataset=`audit`. |
| `event.class` | `security` 또는 `operation`. 한 record에는 하나만 허용한다. |
| `event.action`, `event.outcome` | 제품의 rule/event/verb와 `success`, `failure`, `allow`, `deny`, `unknown` 중 해당 결과. 결과를 추측하지 않는다. |
| `event.severity` | source가 제공할 때만 원값과 정규화 값을 함께 둔다. 없는 severity를 만들지 않는다. |
| `observer.name`, `observer.type` | event를 만든 node·appliance·service와 제품 종류. 주소는 이 필드에 복제하지 않는다. |
| `actor.kind` | `user`, `service_account`, `peer`, `process`, `none` 중 하나. network event는 `peer`, syscall event는 `process`로 두고 user/SA가 없음을 source 표에 명시한다. |
| `actor.id` 또는 `actor.name` | source가 제공할 때 필수. 이메일·표시명 대신 stable subject, entity, user ID, ServiceAccount 또는 peer ID를 우선한다. |
| `correlation.kind` | `request`, `trace`, `session`, `flow`, `event`, `none` 중 하나. |
| `correlation.id` | source-native ID가 있을 때만 기록한다. `none`이면 비워 두고 아래 source별 대체 조회 key를 쓴다. hash나 UUID를 새 request ID처럼 만들지 않는다. |
| `resource.*`, `network.*` | 대상 object, route, peer, namespace/Pod/container 또는 5-tuple 중 source별 필수 context. |

필수 field가 빠지거나 parse할 수 없는 record는 다른 저장소로 우회하지 않는다. source schema
오류로 집계하고 pipeline health 경보를 낸다. 원문을 일반 오류 로그에 복사하지 않는다.

## 4. 목적지와 보존

보존은 기간과 크기 중 먼저 도달한 상한이다. 구현 acceptance에서는 고정 관측창의 실제
**저장 후 크기**로 목표 기간이 상한 안에 드는지 계산한다. 맞지 않으면 배포를 멈추고 허용
event class를 줄인다. 디스크를 채우거나 임의로 PVC를 늘려 통과시키지 않는다.

| 코드 | 중앙 목적지 | event class | 최대 기간 | 일일 저장 상한 | 기간 전체 상한 |
|---|---|---|---:|---:|---:|
| `D30` | Wazuh 직접 | 탐지량이 큰 IDS·WAF·runtime match | 30일 | 전체 합계 256 MiB/일 | 7.5 GiB |
| `A90` | Wazuh 직접 | API·identity·권한·접근·감사 metadata | 90일 | 전체 합계 96 MiB/일 | 8.4375 GiB |
| `O7` | Loki | 허용된 운영 로그 | 7일 | 전체 합계 2 GiB/일 | 14 GiB |
| `C0` | 수집하지 않음 | payload·body·recording·중복 stage·debug dump | 0일 | 0 | 0 |

Wazuh index 전체 hard cap은 `D30 + A90 = 15.9375 GiB`이며 16 GiB를 넘지 않는다. task-time
PVC 요청 합계 66.125 GiB와 경고선 96 GiB의 차이는 29.875 GiB이므로 16 GiB는 그 안에
들어가고 13.875 GiB를 남긴다. 이 값은 논리 상한이지 디스크 예약이 아니다.
용량 계획이 명시하듯 Wazuh indexer 배치는 아직 PVC 예산에 포함되지 않으므로 `WAZUH-01`은
`LOKI-01`·`OBS-01` 뒤의 실제 여유에서 16 GiB와 index overhead가 들어가는지 다시 판정해야 한다.

Loki chunk hard cap 14 GiB는 용량 계획의 `object-01` 버킷 데이터 구획 170 GiB 중 10% 미만이다.
WAL, cache, index와 collector buffer는 이 14 GiB에 기대어 k3s PVC 경계를 넘을 수 없으며
`LOKI-01`이 별도로 계산한다. 2026-08-03 read-only 확인에서는 k3s guest와 object guest가
각각 disk 정지 기준 밖이었지만, 이 결과는 후속 `K3S-HEAVY` 적용 직전 재측정을 대신하지 않는다.

### 소스별 routing

| 소스 | event 종류 | 분류 | 목적지·보존 | 중앙 수집에서 제외할 것 |
|---|---|---|---|---|
| Suricata | `eve.json`의 `event_type=alert` | 보안 | Wazuh 직접 `D30` | packet/payload, non-alert flow·HTTP·DNS transaction |
| Suricata | engine 기동·rule load·capture/output 오류 | 운영 | Loki `O7` | stats 숫자형 상태는 metrics 경로 |
| CrowdSec AppSec | Coraza/CRS match, alert, transaction remediation 결과 | 보안 | Wazuh 직접 `D30` | raw query value, header, cookie, body, `DumpRequest`, LAPI decision과 같은 event의 복제본 |
| CrowdSec AppSec | AppSec/LAPI 기동, rule load, readiness, timeout·연결 오류 | 운영 | Loki `O7` | security match가 든 `msg` 원문 |
| Falco | rule match JSON | 보안 | Wazuh 직접 `D30` | syscall raw stream, command line/argument, environment, file content |
| Falco | engine·modern eBPF driver·drop·output health | 운영 | Loki `O7` | counters는 metrics 경로 |
| Kubernetes | API audit terminal stage(`ResponseComplete` 또는 `Panic`) Metadata | 보안 | Wazuh 직접 `A90` | `RequestReceived` 중복 stage, request/response object, Secret·token body |
| Kubernetes | `core/v1 Event`와 허용된 controller/workload lifecycle log | 운영 | Loki `O7` | 보안 audit event, 반복 health probe, metrics |
| Vault | `stdout/` audit request·response stage | 보안 | Wazuh 직접 `A90` | token/accessor, header, request/response data와 body |
| Vault | seal·Raft·storage·listener·lifecycle log | 운영 | Loki `O7` | audit JSON의 복제본 |
| Keycloak | user event와 admin event(`details` 비활성 유지) | 보안 | Wazuh 직접 `A90` | token/assertion, credential, redirect query, admin representation body |
| Keycloak | server·JVM·DB pool·cache·readiness log | 운영 | Loki `O7` | `org.keycloak.events` record 복제본 |
| Pomerium | authenticate/session 및 authorize allow·deny record | 보안 | Wazuh 직접 `A90` | cookie, token/header, email 원문, query value |
| Pomerium | service 기동·config load·upstream/health 오류 | 운영 | Loki `O7` | allow/deny record 복제본 |
| NetBird | `events.db`의 account·user·peer·policy·setup-key 변경과 접근 event | 보안 | Wazuh 직접 `A90` | setup key/token 값, geo/city, 사용자 email·표시명 |
| NetBird | management·signal·relay·dashboard lifecycle와 transport 오류 | 운영 | Loki `O7` | 제품 audit event와 일반 access body |
| Warpgate | 인증 성공·실패, target 인가, session 시작·종료 metadata | 보안 | Wazuh 직접 `A90` | password/cookie/key, command argument, terminal/file recording 원문 |
| Warpgate | systemd/service, protocol listener, storage·recording writer 오류 | 운영 | Loki `O7` | 감사 event 복제본 |
| Warpgate | terminal/file recording blob | 민감 원문 | 중앙 `C0`; 기존 제품 local `audit_retention=90days` 이상으로 늘리지 않음 | blob 전체 |

## 5. 소스별 필드와 상관 키

| 소스·event | 시각 | 주체 | native 상관 ID | native ID가 없을 때의 대체 조회 key | 추가 필수 field |
|---|---|---|---|---|---|
| Suricata alert | `timestamp`의 offset을 UTC로 변환 | `actor.kind=peer`; 사람 사용자 없음 | `flow_id` (`flow`) | 5-tuple + `flow.start` + interface | interface, direction, 5-tuple, proto, alert signature ID/rev/category/severity/action |
| CrowdSec AppSec match | `time` 또는 alert Date의 offset을 UTC로 변환 | `actor.kind=peer`; 사람 사용자 없음 | `request_uuid` (`request`) | source IP + target host + 마스킹한 path + rule IDs + 시각 | config/rule ID, in-band 여부, remediation, HTTP outcome/status |
| Falco rule match | JSON `time`을 UTC로 변환 | `actor.kind=process`; user/SA는 없음 | 없음 | hostname + namespace/Pod/container + `time` + `rule` | rule, priority, source, namespace, Pod, container, process; 조사 시 Pod UID·SA는 별도 read-only 보강 |
| Kubernetes API audit | `requestReceivedTimestamp`, `stageTimestamp` UTC | `user.uid/name/groups`; `system:serviceaccount:`은 SA로 분류; impersonation 별도 | `auditID` (`request`) | 없음 | stage, verb, sanitized request URI, source IP, user agent, objectRef, response status, admission annotations |
| Kubernetes Event | `eventTime`; 없으면 `lastTimestamp`, 그다음 creation timestamp | `actor.kind=none` | 없음 | involved object UID + reason + reporting component + 시각 | namespace, kind/name/UID, reason, type, count, reporting component, 마스킹한 message |
| Vault audit | JSON `time` UTC | `auth.entity_id`/`display_name`; Kubernetes auth metadata가 있으면 SA | `request.id` (`request`) | 없음 | request/response stage, operation, path, mount type, remote endpoint, auth policy 결과 |
| Keycloak user/admin | CRI envelope 시각 UTC | `userId`; admin actor와 대상이 있으면 분리 | `code_id`가 있을 때 `session` | realm ID + client ID + user ID + type + source IP + CRI 시각 | event type, realm/client ID, auth method/type, error/outcome |
| Pomerium authn/authz | JSON `time` UTC | `user`; email은 제거 | `request-id`와 관련 `check-request-id` (`request`), `session-id` (`session`) | 없음 | route ID, method, 마스킹 path/host, source IP, allow/deny와 reason |
| NetBird product event | timezone 포함 `timestamp`를 UTC로 변환 | `initiator_id`; 대상 user/peer는 `target_id` | source-local `id` (`event`) | account ID + initiator ID + target ID + activity + 시각 | activity를 action 이름으로 매핑, account/target ID, 필요한 asset name/FQDN/IP |
| Warpgate audit | 제품 audit 시각을 UTC로 변환 | Warpgate user ID/name; 접속 peer 별도 | session event는 session ID (`session`), 인증 event는 없음 | event type + user ID + source peer + target + 시각 | auth outcome/reason, target ID/name/protocol, session start/end와 recording 존재 여부 |

`없음`은 결함이 아니다. 대체 조회 key는 조사 범위를 좁히는 composite일 뿐 request/trace ID로
저장하지 않는다. 서로 다른 소스의 사건을 연결할 때는 native request/session/flow ID가 같을 때
우선 연결하고, 그 다음에만 시간창·stable actor·resource·network peer를 함께 사용한다.
현재 표본에는 제품이 명시한 native `trace_id`가 없으므로 Pomerium의 관련 request ID나 임의
hash를 trace ID로 승격하지 않는다.

## 6. 마스킹과 개인정보

마스킹은 parser가 event를 spool, Wazuh 또는 Loki에 쓰기 **전**에 allowlist 방식으로 수행한다.
금지 field를 정규식으로 사후 치환하는 방식만으로 통과시키지 않는다.

| 정보 | 처리 |
|---|---|
| bearer/access/refresh/ID token, JWT, Vault token·accessor, setup key, password, Secret 값, private key | field 전체 제거. Vault HMAC 값도 재식별용 index로 쓰지 않고 제거 |
| `Authorization`, `Cookie`, `Set-Cookie`와 인증 header | header 이름만 필요한 경우 boolean `present`만 허용하고 값 제거 |
| request/response body, form·multipart, 환경변수, 파일 내용 | 중앙 수집 금지 `C0` |
| command line·argument, terminal/file recording | 중앙 수집 금지 `C0`; process 실행파일 이름과 승인된 rule metadata만 허용 |
| URI | scheme/host와 route path까지만. query·fragment 값은 제거하고 탐지에 필요한 query key 이름만 allowlist 가능 |
| 이메일·표시명·geo/city | 제거. stable 제품 user/entity/peer ID로 상관분석 |
| username | 플랫폼 account 식별자일 때 Wazuh에만 허용. email 형식이면 stable user ID만 남기고 제거 |
| source/destination IP | 보안 event에는 조사상 필요한 exact IP 허용. 운영 로그에는 원칙적으로 제거하고, 필요 시 IPv4 `/24`·IPv6 `/64` prefix까지만 허용 |
| Kubernetes `requestObject`·`responseObject`, Keycloak admin details, CrowdSec request dump | 생성·수집하지 않음. Kubernetes audit는 `Metadata` level만 허용 |
| error/message | token·body·query·command를 포함할 수 있으므로 source별 parser가 안전한 reason/code만 추출하고 원문은 버림 |

## 7. 후속 구현 acceptance

### `LOKI-01`

- 이 문서에서 `O7`인 record만 수집하고 security event가 0건임을 고정 표본으로 확인한다.
- Loki chunk는 기존 S3 경계를 사용하며 retained chunk 전체가 14 GiB, 저장 후 증가량이
  2 GiB/일을 넘지 않아야 한다.
- user, request, trace, session, flow, Pod UID 같은 high-cardinality 값은 label이 아니라
  structured field로 둔다.
- 마스킹 전 원문을 local spool에 남기지 않는다.

### `WAZUH-01`

- 이 문서에서 `D30`·`A90`인 record만 소스에서 직접 수집한다. Loki relay와 Loki 복제본은
  모두 0건이어야 한다.
- Kubernetes API audit가 현재 없으므로 공식 `audit.k8s.io/v1` `Metadata` 정책과 terminal
  stage를 구현하되 request/response body를 활성화하지 않는다.
- 고정 관측창의 index 실제 저장 증가량으로 `D30` 7.5 GiB, `A90` 8.4375 GiB, 전체
  16 GiB 상한을 만족해야 한다. `LOKI-01`·`OBS-01` 뒤 capacity gate가 이 placement를
  수용하지 못하면 배포를 중단한다.
- active response, 방화벽 자동 차단과 credential rotation은 계속 비활성이다.
