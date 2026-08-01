# Vault secrets engine · Kubernetes auth · 내부 PKI

- 목적: 앱이 정적 시크릿과 단기 DB 자격증명, 내부 인증서를 최소권한으로 받아가는 기반을 만든다.
- 검증일: 2026-08-01 (`VAULT-02`)
- 소유 결정: [ADR-0006](../adr/0006-vault-seal-and-bootstrap-boundary.md)
- 구성 스크립트와 경계: [`infra/vault/README.md`](../../infra/vault/README.md)

## 전제조건과 접근 권한

- Vault가 `initialized: true`, `sealed: false`이고 Raft leader가 정상이다.
- Argo의 `vault` Application이 Synced/Healthy다.
- Vault Pod에서 `postgres-01.imcherry5778.xyz`가 해석되고 TCP 5432가 열려 있다(`NET-03A`).
- **root token**. 저장소 밖 mode `0600` 파일로만 주입한다. 작업이 끝나면 폐기한다.
- PostgreSQL superuser 접근(초기 role 생성 1회). 이후에는 필요 없다.

Shamir share는 이 작업에 필요하지 않다. root token이 있으면 share를 꺼내지 않는다.

## 예상 영향과 공유 잠금

- 백로그상 잠금은 없지만 **`gitops/root/`와 Argo `platform-root`는 실질적 공유 자원이다.**
  이 작업은 `gitops/apps/vault/`와 `gitops/root/vault-project.yaml`을 바꾸므로 같은 시점에
  다른 작업자가 `platform-root`의 targetRevision을 자기 브랜치로 고정하면 서로 원복시킨다.
- **StatefulSet이 바뀌면 Pod가 재생성되고 Vault가 sealed 된다.** 수동 unseal이 필요하다.
  Pod를 건드리는 변경은 한 번에 모아서 적용해 unseal 횟수를 줄인다.

## 실행 순서

### 1. Pod 선언 보정 (GitOps, unseal 1회 필요)

Kubernetes auth와 DB TLS에는 Pod 안에 두 가지가 있어야 한다.

- ServiceAccount token: Vault가 TokenReview를 호출할 자기 신분증
- postgres 서버 인증서: `sslmode=verify-full`의 신뢰 앵커

`gitops/apps/vault/`에 `rbac.yaml`(`system:auth-delegator` 바인딩)과
`postgres-ca-configmap.yaml`을 추가하고, StatefulSet에 projected SA token(만료 1시간)과
CA를 마운트한다. AppProject의 `clusterResourceWhitelist`에 ClusterRoleBinding을 추가한다.

**장기 reviewer token을 Kubernetes Secret에 두는 방식은 쓰지 않는다.** 만료 없는 자격증명이
생기고 VAULT-01의 "vault namespace Secret 0건"이 깨진다. kubelet이 갱신하는 projected
token이 그 두 문제를 모두 피한다. 대가는 Pod 재생성 시 unseal 1회다.

### 2. PostgreSQL 관리 role (1회)

```sql
CREATE ROLE vault_admin WITH LOGIN CREATEROLE PASSWORD '<주입>';
GRANT CONNECT ON DATABASE keycloak TO vault_admin;
GRANT keycloak_user TO vault_admin WITH ADMIN OPTION;
```

superuser를 주지 않는다. PostgreSQL 16의 `CREATEROLE`은 자신이 만든 role만 관리하므로
영향 범위가 닫혀 있다. 비밀번호는 SQL을 stdin으로 넘겨 명령 인자에 남기지 않고,
적용 전에 `log_statement=none`을 확인한다.

### 3. Vault 구성

```bash
export VAULT_ROOT_TOKEN_FILE=<저장소 밖 경로>/vault-root.token
export PG_VAULT_PASSWORD_FILE=<저장소 밖 경로>/pgvault.pw
infra/vault/scripts/configure.sh
```

audit device를 가장 먼저 켠다. 이후의 모든 변경이 감사에 남는다.
database 연결 직후 `rotate-root`가 실행되어 사람이 아는 비밀번호는 그 시점에 폐기된다.

## 중단 조건

- Vault가 sealed이거나 Raft leader가 없다.
- `platform-root`가 다른 작업자의 브랜치에 고정돼 있다.
- database 연결이 TLS 단계에서 실패한다(인증 실패는 비밀번호 문제이므로 구분한다).
- audit device를 켤 수 없다. 이 경우 이후 작업의 감사 기록이 남지 않는다.

## 성공 판정

2026-08-01에 아래를 모두 실측했다.

**Kubernetes auth.** 바인딩된 ServiceAccount(`vault-verify/allowed-sa`)는 로그인에 성공해
20분 token과 policy를 받았다. 같은 role에 바인딩되지 않은 SA와, 다른 namespace에 바인딩된
role로의 로그인은 모두 `403 service account name not authorized`였다.

**policy 격리.** `keycloak` policy를 가진 token은 `kv/data/keycloak/*`를 읽었고,
`kv/data/pomerium/*` 읽기, 자기 경로 쓰기, `sys/mounts` 조회는 모두 `403 permission denied`였다.
쓰기 거부 뒤 원래 값이 그대로임을 확인했다.

**동적 PostgreSQL 자격증명.** 발급한 사용자로 k3s 안에서 `sslmode=verify-full` 접속에
성공했고 `pg_stat_ssl`이 TLSv1.3을 보고했다. 상속한 role은 `keycloak_user` 하나뿐이고
superuser가 아니다. 다른 DB(`verify_db`)는 CONNECT 권한 없음으로 거부됐고,
`sslmode=disable`은 `pg_hba.conf`가 비암호화라는 이유로 거절했다. lease를 revoke하자
같은 자격증명의 재접속이 인증 실패했고 PostgreSQL에서 해당 role이 실제로 사라졌다.

**내부 PKI.** `chain-verify.vault.svc.cluster.local`로 발급한 인증서는 issuer가
`ktcloud4-bean Internal CA`이고 SAN이 정확했으며 `openssl verify`가 `OK`였다.
폐기 후 CRL에 해당 serial이 등록된 것을 확인했다. 공인 zone 이름(`sso.imcherry5778.xyz`)
발급은 `common name not allowed by this role`로 거부됐다.

**audit.** 108건의 request/response 이벤트가 기록됐고 거부 12건도 남았다. 경로·operation·
policy는 남지만 `client_token`은 HMAC-SHA256으로 가려졌다. **KV에 기록한 시험값 문자열은
로그에서 0건**이었다. audit device는 Pod가 두 번 재생성되는 동안 Raft에 남아 유지됐다.

**정리.** 검증용 Pod·namespace·ServiceAccount·auth role·KV 시험값·동적 lease를 모두
제거했다. `vault` namespace의 Secret은 계속 **0건**이고, PostgreSQL에 남은 동적 role은 0개다.

## 알려진 한계

- Vault 내부 구성은 Argo가 동기화하지 않는다. 드리프트를 자동으로 잡지 못하며 재현은
  `configure.sh` 실행에 의존한다.
- `configure.sh`는 재실행 가능하지만 완전한 멱등성 도구는 아니다. 이미 있는 mount는 건너뛰되
  `vault write`는 값을 덮어쓴다. 삭제된 항목을 감지하지는 못한다.
- 앱 소비 방식은 `KC-01`의 [ADR-0013](../adr/0013-keycloak-secret-consumption.md)이 처음
  결정했다. Keycloak은 cluster-wide injector·privileged CSI 없이 명시적 Vault Agent init이
  메모리 볼륨에 렌더링하며, 다른 앱은 자기 회전·자원 조건을 다시 검토한다.
- TTL 만료는 revoke로 대체 검증했다. 1시간 경과 관측은 포함하지 않는다.

## 실패 시 원상복구

```bash
# Vault 구성만 되돌리기 (Vault 자체는 건드리지 않는다)
vault secrets disable database
vault secrets disable pki
vault secrets disable kv
vault auth disable kubernetes
vault policy delete keycloak
vault policy delete pomerium
vault audit disable stdout
```

PostgreSQL은 superuser로 되돌린다.

```sql
REVOKE keycloak_user FROM vault_admin;
DROP ROLE vault_admin;
```

Pod 선언은 `gitops/apps/vault/`의 변경을 되돌리고 Argo가 동기화하게 한다. 이때도 Pod가
재생성되어 unseal이 필요하다.

**audit device를 마지막에 끈다.** 먼저 끄면 이후 롤백 작업이 감사에 남지 않는다.

## 남기면 안 되는 출력

- Vault root token, Shamir share.
- `vault_admin` 초기 비밀번호. `rotate-root` 이후에는 무효지만 그 전 값도 남기지 않는다.
- 동적으로 발급된 DB 자격증명과 그 `.pgpass`.
- Kubernetes ServiceAccount token(검증용 단기 token 포함).
- PKI 발급 인증서의 private key.
