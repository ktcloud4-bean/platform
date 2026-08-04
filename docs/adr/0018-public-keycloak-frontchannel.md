# ADR-0018: 외부 OIDC 온보딩용 Keycloak 사용자 프런트엔드 공개

- 상태: `Accepted`
- 날짜: 2026-08-04
- 관련 작업: `EDGE-DESIGN-02`, `EDGE-02`, `NB-ENROLL-01`, `IAM-ENROLL-01`
- 구체화하는 결정: [ADR-0004](0004-zero-trust-identity-and-management-access.md),
  [ADR-0017](0017-team-identity-and-shuffle-rbac.md)

## 배경

`EDGE-01`은 공개 공격면을 NetBird control·relay 하나로 제한하고 Keycloak issuer와 애플리케이션
포털을 NetBird 연결 뒤에 두었다. 이 경계는 이미 등록된 peer에는 적합하지만 새 외부 장치는
NetBird에 로그인하려면 Keycloak 브라우저 또는 device authorization에 먼저 도달해야 하고,
Keycloak에 도달하려면 NetBird가 먼저 연결되어야 하는 순환 의존이 생긴다. 사람 장치에 setup
key를 배포하면 순환을 우회할 수 있지만 장치 등록과 사람 신원을 분리해 추적해야 하고 키 전달·
폐기 지점이 늘어난다.

팀 계정은 `IAM-01`에서 이미 사전 생성했고 공개 회원가입은 요구하지 않는다. 필요한 것은
신규 사용자가 기존 일상 ID와 MFA로 NetBird OIDC 로그인을 완료할 수 있는 공개 사용자 인증면이지,
Keycloak 관리면이나 NetBird 없이 쓰는 애플리케이션 포털의 공개가 아니다.

## 결정

`sso.imcherry5778.xyz`의 **Keycloak `platform` realm 사용자 프런트엔드만** Cloudflare proxy
뒤에 공개한다. 고정 issuer는 바꾸지 않는다. 같은 hostname의 내부 split DNS는 k3s ingress를
계속 직접 가리켜 NetBird management와 내부 애플리케이션의 backchannel이 Cloudflare에 의존하지
않게 한다.

공개 경로는 현재 NetBird 설정이 사용하는 OIDC 사용자 흐름의 `platform` realm, 정적 resource와
discovery로 allowlist한다. Cloudflare뿐 아니라 origin의 Traefik 동적 route에서도 같은 경계를
강제한다. `/admin/`, 관리용 `master` realm, root index, health와 metrics는 외부에서 차단한다.
Keycloak 관리와 복구는 내부 DNS·trusted 관리 경로와 로컬 복구 ID를 계속 사용한다. Cloudflare
Access 같은 별도 사용자 로그인은 OIDC authorization·token·device flow 앞에 겹치지 않는다.

Cloudflare의 proxied `sso` record는 현재 WAN IPv4를 origin으로 쓰되, hostname 조건의 Origin
Rule로 [`ip-plan.md`](../ip-plan.md)가 소유하는 전용 origin port에 연결한다. 이 port는 현재
NetBird가 소유한 WAN TCP 443과 분리한다. OPNsense는 Cloudflare가 게시한 origin source만 그
port로 허용하고 k3s ingress HTTPS로 전달한다. origin은 유효한 인증서를 사용하는 Full (strict)
TLS를 유지하며 임의 인터넷 source의 직접 접속은 PF에서 거부한다. Cloudflare source 목록을
안전하게 갱신할 수 없거나 빈 목록이 되면 fail closed한다.

WAF·rate limit은 `sso` hostname에만 적용한다. browser authorization과 정적 resource에는
사람 흐름을 보존하는 정책을, token·device authorization endpoint에는 대상 TTL과 정상 poll
횟수를 먼저 계산한 비대화형 정책을 적용한다. challenge loop나 정상 device poll 차단이 생기면
정책을 완화해 재시도하지 않고 해당 규칙을 rollback한다.

Keycloak의 공개 self-registration, email login, 비밀번호 찾기는 활성화하지 않는다. 관리자가
사전 생성한 `/platform-users` 일상 계정이 초기 비밀번호 변경과 MFA 등록을 직접 완료한다.
NetBird 사람 장치는 이 일상 계정으로 등록하고 `/platform-privileged`만 가진 특권 계정은
NetBird peer 소유자로 사용하지 않는다. 특권 계정은 이미 연결된 승인 장치에서 필요한 서비스에
별도 로그인한다.

`EDGE-02`는 공개 인증면과 origin 경계만 소유한다. NetBird의 일반 사용자 device group,
split DNS, 내부 ingress 대상의 exact route와 장치 offboarding은 `NB-ENROLL-01`이 소유한다.
`access` Portal과 애플리케이션 hostname은 공개하지 않으며 Pomerium Route와 서비스 자체 RBAC를
계속 최종 인가로 둔다. 사람용 setup key는 만들지 않고, setup key는 headless·복구 peer처럼
브라우저 인증이 불가능한 비사람 장치에만 제한한다.

## 검토한 대안

- **Keycloak을 계속 NetBird 안에 두고 사람마다 setup key 배포:** 공개면은 가장 작지만 키
  전달·폐기와 peer 소유자 정합성이 사람 수명주기와 분리되고 최초 MFA 전에 장치 접근권한이 생긴다.
- **`access` Portal까지 공개:** clientless 사용성을 얻지만 실제 리소스를 NetBird 안에 둔다는
  목표에 필요하지 않고 Pomerium·애플리케이션 공개 공격면을 함께 넓힌다.
- **Keycloak 공개 self-registration:** 팀 계정은 이미 명명·그룹·email을 검증해 사전 생성했으므로
  bot 방어, email 검증과 가입 승인이라는 새 수명주기를 추가할 이유가 없다.
- **Keycloak의 모든 path 공개:** Admin REST API와 관리 realm을 불필요한 스캔·credential
  공격면에 놓으므로 채택하지 않는다.
- **Cloudflare Access를 Keycloak 앞에 추가:** 사용자가 NetBird OIDC를 시작하기 전에 별도 신원
  체계를 통과해야 하고 device/token endpoint를 방해하므로 채택하지 않는다.
- **NetBird와 같은 WAN TCP 443을 origin으로 공유:** L4 NAT가 hostname을 판정할 수 없고 기존
  NetBird control·relay rollback을 결합하므로 Cloudflare origin port override로 분리한다.
- **Cloudflare Tunnel:** inbound NAT 없이 origin을 숨기는 장점이 있지만 새 connector·credential·
  관측 경계를 추가하고 현재 OPNsense·Suricata 공개 경로를 우회하므로 이번 범위에서는 채택하지
  않는다.

## 결과

- 신규 외부 장치는 setup key 없이 기존 Keycloak 일상 ID와 MFA로 NetBird OIDC 로그인을 시작할
  수 있다.
- 인터넷 공개는 `netbird` control·relay와 `sso` 사용자 프런트엔드로 한정되고 Portal·리소스·
  Keycloak 관리면은 비공개로 남는다.
- Keycloak 가용성이 신규 peer 등록과 새 OIDC session의 의존성이 되지만 기존 연결 peer와 로컬
  복구 경로는 독립적으로 유지한다.
- Cloudflare WAF·Origin Rule과 OPNsense source allowlist라는 운영 상태가 추가되므로 source 목록,
  rule 우선순위와 rollback을 함께 관리해야 한다.
- 계정 disable만으로 이미 등록된 peer가 즉시 제거된다고 가정하지 않고 Keycloak session revoke,
  NetBird 사용자 차단과 peer 삭제를 하나의 offboarding 절차로 다룬다.

## 재검토 조건

- 팀이 관리하는 외부 IdP나 device trust가 도입되어 Keycloak 직접 password 로그인을 대체한다.
- Cloudflare Origin Rule·source range 또는 WAF 기능이 현재 계약에서 제공되지 않거나 안정적으로
  자동 갱신할 수 없다.
- 여러 공개 애플리케이션이 생겨 단일 `sso` 전용 origin port보다 별도 DMZ reverse proxy나
  Cloudflare Tunnel의 운영비용이 더 낮아진다.
- NetBird가 public Keycloak 없이 안전한 invitation·device enrollment를 제공해 bootstrap 순환이
  사라진다.
- 외부 clientless Portal이 실제 요구가 되면 `access` 공개는 이 결정에 끼워 넣지 않고 별도 ADR과
  작업으로 재검토한다.

## 참고

- [Keycloak reverse proxy와 공개 path 지침](https://www.keycloak.org/server/reverseproxy)
- [Keycloak hostname과 frontend/backchannel 분리](https://www.keycloak.org/server/hostname)
- [Cloudflare Origin Rules destination port override](https://developers.cloudflare.com/rules/origin-rules/)
- [Cloudflare proxy 지원 port](https://developers.cloudflare.com/fundamentals/reference/network-ports/)
