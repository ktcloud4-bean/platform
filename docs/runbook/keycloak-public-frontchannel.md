# Keycloak 공개 사용자 프런트엔드

- 설계 작업: `EDGE-DESIGN-02`
- 적용 작업: `EDGE-02`
- 후속: `NB-ENROLL-01`, `IAM-ENROLL-01`
- 결정: [ADR-0018](../adr/0018-public-keycloak-frontchannel.md)
- 현재 실행 상태: **완료, 라이브 적용됨** (2026-08-04)

## 목적과 현재 경계

`EDGE-02`는 외부 신규 장치가 기존 Keycloak 일상 ID와 MFA로 NetBird OIDC 로그인을 시작할 수
있게 `sso` 사용자 프런트엔드만 공개한다. 적용 전 공개 경계는
[`EDGE-01`](netbird-public-edge.md)의 DNS-only `netbird` 하나와 기존 NetBird NAT뿐이었다.

```text
외부 사용자
  → Cloudflare proxied sso:443
  → hostname 전용 Origin Rule
  → OPNsense의 Cloudflare-source-only origin port
  → k3s Traefik HTTPS
  → Keycloak platform realm 사용자 프런트엔드

외부 신규 장치
  → NetBird Login
  → 위 Keycloak 경로에서 기존 /platform-users ID + MFA
  → NetBird peer 등록
  → NB-ENROLL-01의 split DNS·exact route
  → 내부 access Portal
```

공개 target의 주소와 port는 [`ip-plan.md`](../ip-plan.md)가 소유한다. 이 문서에는 WAN 주소,
내부 주소, OPNsense UUID와 Cloudflare record ID를 복제하지 않는다.

## 소유 범위

`EDGE-02`가 소유한다.

- Cloudflare proxied `sso` record와 hostname exact Origin Rule
- `sso` 전용 WAF·rate limit과 Cloudflare·Traefik 동적 route의 외부 path allowlist
- Cloudflare origin source alias와 전용 WAN origin port의 OPNsense PF/NAT
- 공개 요청의 Full (strict) TLS와 고정 issuer 보존
- 외부 origin 우회 차단, rollback snapshot과 masked drift snapshot 갱신

`EDGE-02`에서 하지 않는다.

- Keycloak 공개 self-registration·email login·비밀번호 찾기 활성화
- `/admin/`, `master` realm, health·metrics 공개
- `access`, 애플리케이션 alias, k3s canonical host의 공개 DNS·NAT
- Cloudflare Access를 OIDC authorization·token endpoint 앞에 배치
- NetBird control·relay NAT, recovery peer·policy 또는 Default policy 변경
- 일반 사용자 NetBird route·DNS·device group과 팀원 실제 MFA 등록
- Traefik 정적 entrypoint·plugin 변경 또는 k3s Pod 재기동

## 공개 path 계약

외부 allowlist는 Keycloak 공식 reverse proxy 경계를 기준으로 다음 기능만 통과시킨다.

| 분류 | 외부 정책 |
|---|---|
| `platform` realm OIDC·login action | 허용; browser·device flow에 필요한 하위 path 포함 |
| 정적 resource와 discovery | 허용 |
| `/admin/`·Admin REST API | 차단 |
| 관리용 `master` realm | 차단 |
| root index·health·metrics | 차단 |
| 미분류 path | 기본 차단 후 실제 정상 흐름 증거가 있는 경우만 같은 작업에서 추가 |

WAF challenge는 browser authorization에만 적용할 수 있다. token·JWKS·device authorization
poll처럼 비대화형 client가 쓰는 path에는 interactive challenge를 적용하지 않는다. rate limit은
NetBird client의 token TTL·poll interval·한 번의 정상 로그인 요청 수를 먼저 계산해 정한다.
origin-side path 정책은 OPNsense가 보존한 transport source가 Cloudflare alias에 속하는지로 외부
요청을 구분한다. 임의 client가 만들 수 있는 `X-Forwarded-For` 같은 header를 보안 경계로 믿지
않으며 내부 관리 source의 기존 route에는 이 외부 allowlist를 적용하지 않는다.

## 적용 전 stop condition과 승인

다음 read-only preflight 중 하나라도 실패하면 공개 객체를 만들지 않는다.

- 최신 `origin/main`의 `EDGE-01`, `KC-01`, `NB-02`, `NET-04`가 `DONE`이 아니다.
- `PUBLIC-DNS`, `OPNSENSE-LIVE` 또는 `ARGO-ROOT`에 다른 작업자 잠금이 있다.
- Cloudflare zone의 실제 plan에서 destination port Origin Rule과 필요한 WAF 정책을 제공하지 않는다.
- 현재 WAN NAT·PF가 [`ip-plan.md`](../ip-plan.md)의 `EDGE-01` 경계와 다르다.
- OPNsense 일반 drift가 있거나 Cloudflare source 목록을 fail-closed로 유지할 방법이 없다.
- target origin port가 이미 다른 live listener/NAT/PF 또는 UPnP mapping에 사용 중이다.
- OPNsense DNAT 뒤 Traefik에서 Cloudflare transport source를 신뢰 가능한 방식으로 구분할 수 없다.
- Keycloak 고정 issuer, TLS, proxy header trust 또는 외부 공개 path 목록이 선언과 다르다.
- NetBird와 Warpgate의 독립 복구 기준점이나 rollback 입력을 확보할 수 없다.

preflight가 모두 통과하면 공개 DNS·외부 노출 적용 직전에 현재 증거, exact 객체와 영향,
rollback 입력, 아래 완료 증거를 한 번에 제시해 통합 승인을 받는다. 승인 전에는 DNS, Origin Rule,
WAF, NAT와 PF를 stage하거나 활성화하지 않는다.

## 적용 순서 계약

1. Cloudflare zone 전체 record와 관련 ruleset, OPNsense raw config, Keycloak·Traefik 선언 SHA를
   저장소 밖 owner-only 위치에 snapshot한다.
2. OPNsense Cloudflare source alias·PF·NAT를 disabled 상태로 만들고 API readback에서 source,
   destination, protocol, port, sequence, log와 disabled를 대조한다.
3. Cloudflare `sso` record, hostname exact Origin Rule, 외부 path·WAF·rate limit을 만들되 origin
   PF는 계속 disabled로 둔다.
4. Cloudflare source에서 들어온 요청에만 적용되는 Traefik 동적 route의 동일 path allowlist를
   immutable commit SHA로 stage하고 내부 관리 경로가 그대로 열려 있음을 확인한다.
5. Cloudflare Trace 또는 ruleset API readback에서 hostname 조건과 origin port 적용을 확인한다.
6. PF·NAT를 활성화하고 저장 설정과 PF runtime을 대조한 뒤 아래 완료 증거를 각각 한 번 수행한다.
7. 성공한 live 의미값만 masked OPNsense drift snapshot과 runbook 적용 결과에 반영한다.

## 완료 증거

| 증거 | 단일 검증 방법 |
|---|---|
| 공개 DNS·origin allowlist | 권위 DNS와 Cloudflare ruleset, OPNsense 저장 설정·PF runtime을 한 실행에서 대조해 `netbird` DNS-only 경계와 `sso` proxied 경계만 존재하고 origin port는 Cloudflare source만 허용함을 판정 |
| Keycloak 외부 사용자 프런트엔드 | 랩 밖 신규 client에서 discovery부터 기존 `/platform-users` ID의 PKCE 또는 device authorization·MFA·localhost callback까지 한 흐름으로 완료하고 issuer·TLS·token 원문 비출력을 확인 |
| 관리면·우회 차단 | 같은 외부 시점에 `/admin/`, `master` realm, root·management path와 WAN origin 직접 접속이 거부되고 허용 discovery control은 성공함을 판정 |
| 기존 공개·복구 독립 | NetBird control 연결과 등록된 recovery peer의 Warpgate TCP 8888 경로가 유지되며 `access`·애플리케이션 공개 record/NAT가 0건임을 확인 |
| rollback | `sso` Cloudflare·OPNsense 객체만 제거해 EDGE-01 DNS·NAT allowlist로 복귀하고 Keycloak 내부 issuer와 NetBird·Warpgate가 유지됨을 확인 |

`EDGE-02`는 external OIDC 도달만 판정한다. 일반 팀 device group, split DNS, 내부 ingress route와
offboarding은 `NB-ENROLL-01`에서 검증하며 Pomerium과 각 애플리케이션 RBAC를 이 작업에서 다시
검증하지 않는다.

## 2026-08-04 적용 결과

preflight에서 두 가지 차이를 발견해 먼저 정리했다. `WAZUH-02`·`SOAR-DASH-01`이 남긴 Unbound
alias 2건이 OPNsense drift 스냅샷에 반영되지 않아 먼저 스냅샷만 갱신했다(별도 커밋, live
변경 0). Cloudflare zone에는 2026-07-13 폐기된 `ktcloud4-acer` 프로젝트가 남긴
`acer-waf-custom`(4개)·`acer-waf-ratelimit`(1개) ruleset이 있었고 Free plan의 WAF Custom
Rule 5개·Rate Limit 1개 한도를 이미 점유해 `sso` 전용 규칙을 만들 자리가 없었다. 사용자 확인
뒤 두 ruleset을 삭제해 슬롯을 확보했다(`acer-waf-managed`는 project-neutral이라 유지).

적용은 OPNsense alias 3개(API) → OPNsense NAT(REST API 미제공, GUI로 disabled 생성 후
readback 대조) → Cloudflare DNS·Origin Rule·WAF·Rate Limit(API, enabled) → GitOps(immutable
SHA로 `platform-root`·`keycloak` Application 라이브 검증) → 전체 readback 뒤 NAT 활성화
순서로 진행했다. `keycloak` AppProject에 `traefik.io/Middleware`가 whitelist돼 있지 않아
sync가 막힌 것을 발견해 crowdsec AppProject와 같은 패턴으로 추가했다.

완료 증거 5개를 모두 실행했다.

1. **공개 DNS·origin allowlist**: 공개 resolver·Cloudflare API로 `netbird` DNS-only,
   `sso` proxied 2건만 확인. OPNsense 저장 설정·PF runtime의 WAN NAT는 NB-01 세 건과
   EDGE-02 8443(source `EDGE02_CF_EDGE_SOURCES`만) 한 건으로 일치했다.
2. **Keycloak 외부 사용자 프런트엔드**: Cloudflare edge IP로 강제 resolve한 실제 PKCE
   요청(`client_id=netbird-client`, 등록된 `redirect_uri=http://localhost:53000/`, S256)이
   로그인 폼까지 200으로 도달했고, 기존 `/platform-users` 일상 ID로 비밀번호 변경·TOTP
   MFA 등록·콜백(`state`·`session_state` 일치)까지 완료했다.
3. **관리면·우회 차단**: 같은 외부 경로에서 `/admin/`·`/admin/master/console/`·
   `/realms/master`·root가 403, WAN origin(TCP 8443) 직접 접속은 timeout, 허용 discovery는
   200/404(정상 도달)로 대조됐다.
4. **기존 공개·복구 독립**: NetBird `/api/accounts` 401 불변, Warpgate TCP 8888 recovery
   경로 도달, `access`·애플리케이션 공개 record 0건을 확인했다.
5. **rollback**: Cloudflare 4개 객체와 GitOps 변경을 제거해 EDGE-01 기준선(단일 Ingress,
   Middleware 0개)으로 복귀함을 확인한 뒤(OPNsense는 alias만 API로, NAT는 GUI로 각각
   disable/delete까지) 같은 exact 값으로 재적용해 최종 상태를 검증했다.

부수적으로 `netbird.imcherry5778.xyz` 대시보드의 사전 존재 결함 두 건을 발견해 별도로
고쳤다(`NB-02-FIX-01`: `AUTH_REDIRECT_URI`·`AUTH_SILENT_REDIRECT_URI`가 절대 URL로 선언되어
dashboard origin과 중복 결합되던 문제, 그리고 `netbird-client`에 없는 `groups` scope를
`AUTH_SUPPORTED_SCOPES`에 요청하던 문제 — `groups` claim은 이미 dedicated protocol mapper로
scope 요청과 무관하게 전달된다). 두 값 모두 git 템플릿과 `netbird-01` 라이브 컨테이너에
반영했다. 외부에서 NetBird 대시보드 접속 시 최초 로드에서 나타나는 "Unauthenticated" 화면은
내부 경로에서는 재현되지 않는 별개 현상으로 원인 미특정 상태이며, `NB-ENROLL-01` 또는 후속
FIX 작업이 조사한다.

## Rollback

1. Cloudflare `sso` proxied record를 disable 또는 삭제해 새 외부 session 진입을 먼저 막는다.
2. hostname Origin Rule, WAF·rate limit을 작업 전 snapshot의 exact 상태로 복구한다.
3. OPNsense에서 `EDGE-02` PF·NAT만 disable하고 runtime에서 사라진 것을 확인한 뒤 삭제한다.
4. Cloudflare source alias가 다른 rule에서 참조되지 않을 때만 삭제한다.
5. Keycloak·Traefik에 적용한 task-owned 변경이 있으면 immutable 시작 SHA로 rollback한다.
6. `EDGE-01`의 NetBird DNS-only record, TCP 80/443·UDP 3478 NAT와 recovery policy는 건드리지
   않고 일반 drift 없음과 내부 `sso` issuer를 확인한다.

이 rollback은 신규 외부 로그인만 중단한다. 이미 연결된 NetBird peer를 일괄 삭제하거나 기존
Keycloak session을 revoke하지 않는다. 특정 사용자 offboarding은 `NB-ENROLL-01` 절차를 따른다.
