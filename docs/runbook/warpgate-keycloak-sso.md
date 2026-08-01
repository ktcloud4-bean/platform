# Warpgate Keycloak SSO·역할·세션 운영

## 1. 범위와 고정 전제

- 작업 ID: `WG-02`
- 대상: `warpgate-01` (`10.10.30.10`, ACCESS VLAN 30)
- 제품: Warpgate `v0.26.1`
- issuer: `https://sso.imcherry5778.xyz/realms/platform`
- 브라우저 진입: `https://warpgate.imcherry5778.xyz:8888`
- callback: `https://warpgate.imcherry5778.xyz:8888/@warpgate/api/sso/return`
- 공개 A/AAAA·NAT는 만들지 않는다. 서비스 이름은 Unbound에서만 Warpgate VM을 가리킨다.
- 최종 운영 대상의 cross-VLAN 통신 최소화는 `NET-04`가 소유한다.

선행 기준선과 복구 계정은
[`warpgate-privileged-access.md`](warpgate-privileged-access.md), Keycloak 장애 복구는
[`keycloak.md`](keycloak.md), 신원 경계는
[`ADR-0004`](../adr/0004-zero-trust-identity-and-management-access.md)를 따른다.

## 2. 사전 판정과 승인 경계

### ACCESS → PLATFORM OIDC 경로

`NET-03`의 RFC1918 차단보다 앞에서 아래 한 경로만 허용한다.

| 항목 | 값 |
|---|---|
| 인터페이스 | ACCESS (`opt3`) |
| 방향·IP·프로토콜 | in, IPv4, TCP |
| 출발지 | `10.10.30.10` 한 대 |
| 목적지 | `10.10.20.10` 한 대 |
| 목적 포트 | `443` 한 개 |
| sequence | `1115` |
| 상태·감사 | quick, keep state, logging enabled |

이는 discovery·authorization-code token 교환·JWKS를 위한 backend 경로다. 다른
PLATFORM 주소·포트와 기존 RFC1918 차단은 그대로 둔다. `docs/backlog.md`의 원래
`WG-02` 잠금 `없음`은 실제 의존성과 달랐으므로 `OPNSENSE-LIVE`로 보정한다.

### 내부 service alias

Unbound의 기존 canonical host `warpgate-01.imcherry5778.xyz → 10.10.30.10`에
`warpgate.imcherry5778.xyz` host alias를 연결한다. 공개 resolver에는 이 이름의
A/AAAA를 만들지 않는다. 이 변경도 `OPNSENSE-LIVE` 승인 아래에서만 수행한다.

### 자체서명 TLS 판정

setup 인증서는 SAN이 `warpgate.local`·`localhost`이고 신뢰되지 않은 자체서명이라
브라우저가 service alias의 SSO callback·cookie 경로를 정상 신뢰할 수 없다. 따라서
`WG-02`는 service alias 한 이름의 별도 Let's Encrypt DNS-01 인증서를 소유한다.
이는 ingress나 공개 진입을 만드는 `INGRESS-01`/`EDGE-01` 변경이 아니다.

- Cloudflare에는 발급 중 `_acme-challenge.warpgate.imcherry5778.xyz` TXT만 일시 생성한다.
- Warpgate 전용 API token은 zone `imcherry5778.xyz`의 Zone:Read·DNS:Edit만 가진다.
- OPNsense·Proxmox·k3s의 token, 인증서, private key를 재사용하지 않는다.
- lego `v5.2.1` archive는 SHA-256으로 고정하며 `lego run`이 발급과 갱신을 함께 수행한다.
- token은 `/etc/warpgate-acme/cloudflare.env` `0600 root:root`, ACME state는
  `/var/lib/warpgate-acme` `0700 root:root`, 배포 인증서·key는
  `/var/lib/warpgate`에 `0600 warpgate:warpgate`로 둔다.
- 갱신 timer는 매일 임의 지연으로 확인하고, SAN·잔여 유효기간·key pair 검증에 성공한
  인증서만 배치한다.
- ACCESS VLAN은 외부 UDP/TCP 53을 직접 열지 않고 OPNsense Unbound만 쓴다. 내부
  `imcherry5778.xyz` local-zone은 공개 ACME TXT를 NXDOMAIN으로 답하므로 lego의
  recursive propagation self-check 대신 `--dns.propagation.wait 60s`를 선언한다.
  Cloudflare API 생성 뒤 60초를 기다리고 CA가 authoritative DNS에서 검증하게 하며,
  별도 DNS 방화벽 예외는 만들지 않는다.

setup 인증서·key는 최초 한 번 `tls.setup.*.pem`으로 보존한다. rollback은 ACME timer를
중지하고 이 두 파일을 본래 TLS 경로에 0600으로 복구한 뒤 SELinux context를 복원하고
Warpgate만 재시작한다.

## 3. Keycloak client와 역할 매핑

기존 realm·group·user·client와 bootstrap Job은 수정하지 않는다. Admin API는 소유 marker
`wg02.owner=warpgate_baseline/WG-02`가 붙은 confidential client `warpgate`와 client-local
`groups` mapper 하나만 선언한다.

| 항목 | 계약 |
|---|---|
| flow | Authorization Code만 활성 |
| direct grant·implicit·service account | 비활성 |
| redirect URI | 위 callback 한 개 |
| default scope | `email`, `profile` |
| mapper | full-path `groups`를 ID/access/userinfo token에 포함 |
| full scope | 비활성 |

Warpgate `v0.26.1` custom OIDC의 실제 schema를 사용한다. `roles_claim: groups`와
아래 exact mapping만 선언하고 wildcard·기본 role은 두지 않는다.

| Keycloak group claim | Warpgate role |
|---|---|
| `/platform-users` | `platform-users` |
| `/platform-privileged` | `platform-privileged` |

`auto_create_users: false`로 두고 `imcherry`와 `imcherry-admin` 사용자 및
provider·email SSO credential만 제품 DB에 미리 선언한다. direct role은 주지 않는다.
성공한 SSO 로그인 때 claim에 매핑된 role만 동기화되며 매핑되지 않은 기존 role은 제거된다.
등록되지 않은 사용자, 검증되지 않은 email, group 없는 사용자, mapper 실패 사용자는
로그인 또는 target 권한 단계에서 fail closed 된다. 제품 내장 `admin` 사용자와
`admin` role은 이 동기화 대상이 아니며 삭제하지 않는다.

## 4. 세션 정책

| 항목 | 값 |
|---|---|
| SSH 유휴 제한 | 5분 |
| HTTP session max age | 30분 |
| HTTP cookie max age | 8시간 |
| 세션 기록 | 활성 |
| 일반 로그 보존 | 7일 |
| 감사 로그 보존 | 90일 |

`v0.26.1`은 SSH 절대 최대 세션 설정을 제공하지 않으므로 존재하지 않는 키를 추가하지
않는다. SSH는 유휴 제한으로, 브라우저 세션은 제품이 제공하는 두 max-age로 통제한다.

## 5. 비밀 입력과 실행

저장소 밖 mode `0600` vars에 다음 값을 넣는다. 값은 Git, 명령 인자, 셸 trace,
Ansible 출력에 남기지 않는다.

- `warpgate_admin_password`: 기존 로컬 복구 관리자 비밀번호
- `warpgate_sso_client_secret_file`: Warpgate 전용 client secret 원문 파일
- `warpgate_keycloak_admin_bearer_header_file`: 복구 로그인으로 얻은 단기
  `Authorization: Bearer ...` header 파일
- `warpgate_acme_cloudflare_token_file`: Warpgate 전용 DNS token 원문 파일

`role`은 세 파일이 symlink가 아닌 mode `0600` regular file인지 확인하고, secret
assert와 `no_log`를 적용한다. Keycloak token이 만료되면 저장된 값을
재사용하지 말고 [Keycloak 복구 절차](keycloak.md)에 따라 새 TOTP 구간에서 다시 발급한다.

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 known_hosts> -o PasswordAuthentication=no"
ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 WG-02 vars>" playbooks/warpgate-baseline.yml --syntax-check
ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 WG-02 vars>" playbooks/warpgate-baseline.yml --check --diff
# 승인 범위와 diff를 대조한 뒤
ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 WG-02 vars>" playbooks/warpgate-baseline.yml
ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 WG-02 vars>" playbooks/warpgate-baseline.yml
```

설정 파일은 template이 소유하고 실제 쓰기 전에 `warpgate --config %s check`를 통과한다.
두 번째 적용은 `changed=0`이어야 한다.

## 6. 완료 검증

1. strict TLS로 service alias의 SAN·chain·만료를 확인하고 공개 A/AAAA 0건, ACME TXT
   정리, timer 활성 상태를 확인한다.
2. 같은 검증 구간에서 일상 ID의 일상 target 성공·특권 target 거부, 특권 ID의 특권
   target 성공, 일상 ID의 동일 특권 target 거부를 대조한다.
3. group 없는 ID 또는 잘못된 자격증명을 거부하고 감사 로그에서 인증 성공·실패,
   세션 시작·종료, `Target ... not authorized`를 구분한다.
4. 새 recording을 제품 API에서 조회하고 파일이 `0600 warpgate:warpgate`, 올바른
   SELinux context인지 확인한다. 원문은 Git·작업 로그에 출력하지 않는다.
5. 사용자와 복구 시간을 확보한 뒤 Keycloak `platform` realm을 잠시 비활성화한다.
   SSO 실패와 동시에 로컬 Warpgate `admin` 로그인이 성공해야 한다. 즉시 realm을
   활성화하고 issuer·SSO 로그인을 다시 통과시킨다.
6. 기존 recording SHA-256과 boot ID를 기록한 뒤 `warpgate-01`만 재부팅한다.
   boot ID 변경, failed unit 0, AVC 0, Warpgate·ACME timer 자동 시작, recording hash 불변,
   SSO·로컬 복구 재통과를 확인한다.
7. OPNsense를 재부팅해 단일 pass rule과 alias 영속성을 확인한다. pass/block PF counter,
   다른 VLAN·포트 차단, strict 관리 TLS, `check-drift.sh` 무변경을 다시 증명한다.
8. 검증 전용 target·role·user·임시 계정을 모두 제거하고 Ansible check `changed=0`,
   Git·로그의 secret·세션 원문 0건을 확인한다.

## 7. 2026-08-01 실행 증거

### SSO·권한·감사

- Warpgate `v0.26.1`의 실제 custom OIDC schema와 관리 API를 기준으로 Keycloak 전용
  confidential client와 client-local full-path `groups` mapper 한 개만 만들었다. 기존 client,
  group, user와 bootstrap Job은 수정하지 않았다.
- `auto_create_users: false`, 기본 role 없음, exact group mapping 두 개를 적용했다. 일상 ID는
  `wg02-daily-loopback`만 조회·접속했고 특권 target은 403, 특권 ID는
  `wg02-privileged-loopback`만 조회·접속했고 일상 target은 403이었다. 두 허용 세션 모두
  고유 marker와 `exit 0`을 확인했다.
- 잘못된 Keycloak 자격증명, 잘못된 로컬 admin 자격증명과 무그룹 경로가 거부됐다. 감사
  로그에서 `UserAuthenticated1`, `UserAuthenticationFailed1`, `TargetSessionStarted1`,
  `TargetSessionEnded1`, `Target ... not authorized`를 구분했다.
- 제품 API의 종료 세션마다 `Terminal` recording 한 개를 확인했다. 파일은
  `0600 warpgate:warpgate`, SELinux `var_lib_t`였고 원문은 출력하거나 Git에 남기지 않았다.

### 인증서·복구·재부팅

- Warpgate service alias의 Let's Encrypt 인증서는 SAN이
  `warpgate.imcherry5778.xyz` 한 개이고 strict 검증 결과 0이었다. 공개 resolver A/AAAA와
  공개 NAT는 0건이며 발급 후 `_acme-challenge` TXT도 0건이다. ACME timer는 enabled·active다.
- 승인된 장애 drill에서 `platform` realm을 비활성화하자 SSO가 실패했고 같은 시점의 로컬
  `admin` 로그인은 201이었다. master realm 복구 ID로 즉시 realm을 활성화한 뒤 discovery
  200과 일상 SSO allow/deny를 다시 통과했다.
- Warpgate VMID 130만 재부팅해 boot ID가
  `fe547471-66ae-4ecf-9735-12e1d4fb3ac9`에서
  `0cf28e0a-c2b9-48a6-9751-48883811c54f`로 바뀌었다. failed unit 0, AVC 0, SELinux
  Enforcing, Warpgate와 ACME timer 자동 시작을 확인했다. 기존 recording SHA-256
  `d2733933d6c80d252e4ab264201ba5d339801ecc00ea12a4918ecace4daeafc0`은 불변이었고
  일상·특권 SSO, 403 대조와 로컬 admin을 다시 통과했다.

### OPNsense 최소 경로·영속성

- 저장 rule UUID `9c303af2-c202-4e54-ad42-91d4ab1e1fdf`는
  `opt3/in/IPv4/TCP/10.10.30.10/10.10.20.10/443/pass/keep/log/1115`와 일치한다.
  Unbound alias UUID `5452f494-129c-4447-a573-1cf8f24c8d8d`는 기존 canonical
  `warpgate-01.imcherry5778.xyz`를 service alias에 연결한다.
- OPNsense boot time은 `2026-08-01 19:33:48 KST`에서 `23:48:45 KST`로 바뀌었다.
  재부팅 후 저장 rule·alias와 PF `@106`이 유지됐고, strict discovery 200의 pass counter는
  598 packets·states 5, 같은 목적지 TCP 80과 다른 VLAN TCP 443 음성 control의 기존
  RFC1918 block counter는 6 packets였다.
- OPNsense DNS와 PF는 먼저 정상화됐지만 Keycloak readiness는 단일 DNS 의존성 영향으로
  약 10분 3초간 503이었다. Keycloak Pod는 재시작하지 않았고 자연 복구 뒤 연속 discovery
  200, 일상·특권 SSO와 로컬 admin을 재검증했다.
- strict 관리 TLS는 HTTP 200·verify 0, `check-drift.sh`는 무변경, OPNsense 회귀 테스트
  18개는 모두 통과했다.

### 선언 멱등성과 정리

- syntax-check, 최초 check/diff, 적용, 2차 적용 `changed=0`, Warpgate 재부팅 후 check
  `changed=0`을 통과했다. 검증 종료 cleanup은 OS 계정, loopback known-host, target 두 개,
  임시 거부 사용자를 제거해 `changed=4`였고 바로 이은 적용과 check/diff는 각각
  `changed=0 failed=0`이었다.
- 최종 role은 `admin`, `platform-users`, `platform-privileged`; 사용자는 `admin`,
  `imcherry`, `imcherry-admin`이다. target, loopback known-host, 검증 제품 사용자,
  `wg02-validation-target` OS 계정과 home은 모두 0건이다. SSO 사용자 두 명의 password
  credential은 0건이고 로컬 `admin`은 유지된다.
- 저장소 밖 비밀 18개를 현재 tracked 파일과 브랜치의 reachable blob, Warpgate journal에
  exact 대조해 원문 0건을 확인했다. journal의 검증 session marker 원문과 tracked recording
  payload 파일도 각각 0건이다.
