# Keycloak 배포·신원·복구 런북

- 작업: `KC-01`
- 공개 issuer: `https://sso.imcherry5778.xyz`
- 시크릿 소비 결정: [ADR-0013](../adr/0013-keycloak-secret-consumption.md)
- 인증·관리 경계: [ADR-0004](../adr/0004-zero-trust-identity-and-management-access.md)

## 배포 경계

`gitops/apps/keycloak`은 Keycloak 한 replica, 초기 bootstrap Job, 표준 Kubernetes Ingress를
선언한다. 기존 packaged Traefik과 production DNS-01 resolver만 사용하며 Traefik
`HelmChartConfig`와 Pod를 수정하지 않는다. Keycloak의 TLS edge는 Traefik이고, 고정 hostname과
신뢰한 Pod CIDR의 `X-Forwarded-*`만 받아 issuer 변조를 막는다. 관리 port 9000은 Service와
Ingress에 노출하지 않는다.

Keycloak은 PG-01의 `keycloak` DB에 `keycloak_user`로 연결한다. JDBC TLS mode는
`verify-server`이고 `postgres-01.imcherry5778.xyz` SAN과 저장소의 공개 신뢰 앵커를 모두
검증한다. 다른 DB·role은 KC-01 범위가 아니다.

## 신원과 claim

| ID | realm | 용도 | 그룹 | 직접 권한 |
|---|---|---|---|---|
| `imcherry` | `platform` | 일상 로그인 | `/platform-users` | 없음 |
| `imcherry-admin` | `platform` | 승인된 특권 작업 | `/platform-privileged`, `/keycloak-readers` | 없음 |
| `imcherry-kc-recovery` | `master` | Keycloak 자체 복구 | 없음 | master `admin` realm role |

`keycloak-readers` 그룹에만 `realm-management/view-users` client role을 매핑한다.
`kc-verify` client는 `fullScopeAllowed=false`이며 명시한 `view-users` scope와 `groups` mapper만
사용한다. `view-users`의 내장 composite인 `query-users`, `query-groups`는 토큰에 함께 보일 수
있지만 `manage-users`, `view-clients`, `realm-admin`은 허용하지 않는다. 후속 서비스의 client와
role은 각 후속 작업이 자기 최소권한으로 추가한다.

세 ID는 모두 HMAC-SHA256·6자리·30초 TOTP가 필수다. 일상·특권·복구 암호와 TOTP seed는
서로 다르며 공유 관리자 계정을 만들지 않는다. 최초 암호와 seed는 저장소 밖 mode `0600`
파일로만 인계한다.

복구 ID는 password grant를 쓰지 않는다. master realm의 public `kc-recovery` client는
Authorization Code + PKCE와 TOTP만 허용하며 client secret과 service account가 없다. 이
client의 `fullScopeAllowed=true`는 복구 ID의 master `admin` role을 토큰에 싣기 위한
break-glass 예외이고, 일상·특권 ID가 있는 `platform` realm에는 적용하지 않는다.

## 최초 시크릿 주입

이 단계는 Vault가 `initialized=true`, `sealed=false`이고 PostgreSQL이 정상일 때만 실행한다.
Vault seal/unseal, init, Raft와 다른 DB/role은 건드리지 않는다.

```bash
export KC01_SECRET_DIR=/home/imcherry/secrets/ktcloud4-bean/keycloak
export VAULT_ROOT_TOKEN_FILE=/home/imcherry/secrets/ktcloud4-bean/vault-root.token
gitops/tools/kc-01/provision-secrets.sh --apply
```

스크립트가 쓰는 Vault 경로는 `kv/keycloak/runtime`, `kv/keycloak/bootstrap` 두 개뿐이다.
PostgreSQL에서는 먼저 `log_statement=none`과 `keycloak_user` 최소 속성을 확인한 뒤 그 role의
암호만 바꾼다. 이어 verify-full 양성 접속, 비 TLS 거부, `verify_db` 거부를 확인한다.

회전은 같은 환경에서 `--rotate`를 사용한다. Vault와 DB 갱신이 끝난 뒤 Keycloak Pod를 한 번
재생성하고 이 문서의 전체 검증을 반복한다. 실패하면 새 Pod를 만들지 말고 외부
`db-password` 값으로 `keycloak_user`와 Vault runtime 값을 일치시킨다.

## 최초 bootstrap과 재현

`keycloak-bootstrap-v2` Job은 배포보다 먼저 실행한다. Vault Agent와 bootstrap 컨테이너는
같은 UID로 메모리 파일을 소유하며, 종료 시 렌더링 파일을 모두 지우지 못하면 Job이 실패한다.

1. Vault Agent init이 메모리 볼륨에 DB·realm·개인 복구 관리자 입력을 렌더링한다.
2. offline `bootstrap-admin service`로 임시 관리 client를 만든다.
3. `platform` realm을 최초 import하고 master realm에 개인 복구 ID를 만든다.
4. 암호와 OTP credential, master `admin` role을 확인한다.
5. 임시 client를 삭제하고 CLI token과 렌더링 파일을 제거한 뒤 완료한다.

startup import는 이미 존재하는 realm을 덮어쓰지 않는다. realm 변경은 Admin API의 현재 상태와
Git 선언의 차이를 먼저 분류한 별도 작업으로 수행한다. Job을 단순 재실행해 기존 realm을
교정하지 않는다.

## 완료 검증

라이브 검증은 토큰이나 비밀 원문을 출력하지 않는다.

```bash
export KC01_SECRET_DIR=/home/imcherry/secrets/ktcloud4-bean/keycloak
# 실행 호스트의 기본 resolver가 랩 Unbound를 쓰지 않을 때만 docs/ip-plan.md의
# sso alias 대상을 지정한다. TLS hostname과 issuer 검증은 그대로 유지된다.
export KC01_CONNECT_IP='<docs/ip-plan.md의 sso alias 대상 IPv4>'
gitops/tools/kc-01/verify-live.sh
```

검증기는 다음을 양성·음성으로 확인한다.

- 공인 TLS, HTTP 301, discovery와 실제 access token의 고정 issuer
- TOTP 누락 거부와 올바른 TOTP 로그인 성공
- 실제 token의 `groups`와 `resource_access.realm-management.roles`
- 일상 ID의 Users API 403, 특권 ID의 Users API 200과 Clients API 403
- master realm 개인 복구 ID의 platform realm 관리 API 200
- Argo `Synced/Healthy`, targetRevision `main`, namespace Secret 0건
- 상시 컨테이너 SA token 미마운트, Git·전체 Keycloak Pod 로그의 비밀 원문 0건

master recovery 검증은 Authorization Code callback을 캡처해 account console이 code를 소비하기 전에
PKCE 교환을 끝낸다. callback URL·code·token·cookie는 출력하지 않고 mode `0600` 임시 파일을 종료 trap에서 제거한다.

master realm은 `otpPolicyCodeReusable=false`이므로 `imcherry-kc-recovery`를 사용하는 각
검증은 새 30초 TOTP 구간에서 시작한다. TOTP POST가 callback으로 이동하지 않고 OTP form에
남으면 verifier는 `TOTP rejected or replayed`로만 보고한다. callback URL에 도달했으나 요청과
응답 state가 다를 때만 `authorization state mismatch`로 판정한다.

Pod 재시작 유지는 Deployment Pod를 삭제한 뒤 새 UID와 Ready, 동일 issuer/MFA/claim을 다시
확인한다. 노드 재부팅 유지는 k3s 재부팅 소유 작업과 조율한 뒤 같은 검증과 PostgreSQL TLS
session을 다시 확인한다. **Vault Pod가 재생성돼 sealed면 Keycloak을 재시작하지 말고 사용자에게
unseal을 요청한다.**

## IdP 장애와 독립된 복구 시험

아래 시험은 `platform` realm 로그인을 잠시 막으므로 사용자 승인과 즉시 복구 시간을 확보한
뒤에만 실행한다.

```bash
export KC01_SECRET_DIR=/home/imcherry/secrets/ktcloud4-bean/keycloak
export KC01_CONNECT_IP='<기본 resolver가 랩 Unbound가 아닐 때만 지정>'
gitops/tools/kc-01/verify-recovery.sh
```

스크립트는 master realm의 개인 복구 ID로 platform realm을 비활성화하고, platform token
발급이 `403 access_denied`인 동안에도 같은 로컬 경로의 Admin API가 200임을 확인한 뒤 realm을
즉시 다시 켜고 일상 ID token 발급 200을 재확인한다. EXIT/INT/TERM trap도 재활성화를 시도한다.
자동 복구가 실패하면 같은 로컬 ID로
`PUT /admin/realms/platform`에 `{"enabled":true}`를 적용하고 discovery를 확인한다.

Keycloak 전체가 기동하지 않으면 PostgreSQL과 Vault가 정상인지 먼저 복구한다. 모든 Keycloak
node를 내린 상태에서만 공식 offline `kc.sh bootstrap-admin`으로 새 임시 admin을 만들 수 있다.
상시 복구 ID가 정상인 동안 이 절차를 실행하지 않는다.

## 롤백

1. Git에서 Keycloak Application·AppProject·앱 선언과 DNS 원본 변경을 되돌려 Argo가
   `keycloak` namespace를 prune하게 한다. Traefik 자체는 변경 대상이 아니다.
2. OPNsense에서 정확히 `sso.imcherry5778.xyz`의 `k3s-01` alias만 제거하고 Unbound를 재구성한 뒤
   drift snapshot을 지원 절차로 갱신한다.
3. PostgreSQL DB와 schema는 삭제하지 않는다. 재배포하려면 외부 `db-password`로
   `keycloak_user`와 Vault runtime 값을 다시 일치시킨다.
4. Vault에서는 필요할 때 정확히 `kv/keycloak/runtime`, `kv/keycloak/bootstrap`만 삭제한다.
   auth method, policy, seal, Raft는 유지한다.

## 남기면 안 되는 출력

- 사용자·client·DB 암호와 TOTP seed
- access/refresh token, bootstrap client secret
- Vault root token, Kubernetes ServiceAccount token
- PostgreSQL 암호가 든 SQL·passfile 원문
