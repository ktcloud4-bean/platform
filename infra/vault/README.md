# Vault 구성

Vault의 **내부 구성**(secrets engine, auth method, policy, audit device)을 소유한다.
Vault 자체의 배포(StatefulSet·Service·PVC)는 GitOps가 소유하며 `gitops/apps/vault/`에 있다.
seal·unseal·Raft 경계는 [ADR-0006](../../docs/adr/0006-vault-seal-and-bootstrap-boundary.md),
적용 절차와 증거는 [runbook](../../docs/runbook/vault-secrets-engines.md)이 소유한다.

## 왜 GitOps가 아닌가

Argo CD는 Kubernetes 리소스를 동기화한다. Vault 내부 구성은 Kubernetes 객체가 아니라
Vault API의 상태이므로 Argo의 대상이 아니다. 그렇다고 이 값들을 Kubernetes Secret으로
내리면 "Vault에 넣은 것을 다시 클러스터에 평문으로 꺼내 놓는" 셈이 되어
`architecture.md`의 "GitOps가 Vault의 원문 시크릿을 소유하지 않는다"에 어긋난다.

그래서 이 계층은 스크립트로 재현하고, 실행은 사람이 승인한다.

## 경계

- 이 스크립트는 **mount·auth·policy·role만** 만든다. `init`, `unseal`, seal migration,
  Raft 구성 변경은 하지 않는다. 그 경계는 ADR-0006이 소유한다.
- root token은 이 스크립트를 실행할 때만 쓰고 끝나면 폐기한다. 저장소·클러스터에 두지 않는다.
- PKI는 클러스터 내부 이름만 발급한다. 공인 zone 이름은 role이 거부한다.
  Proxmox·OPNsense·ingress의 공인 인증서를 대체하지 않는다.
- database engine의 PostgreSQL 관리 계정은 superuser가 아니다. `CREATEROLE`과
  대상 role의 `ADMIN OPTION`만 가진다.

## 만드는 것

| 경로 | 용도 |
|---|---|
| `kv/` (KV v2) | 앱별 정적 시크릿. 경로는 `kv/data/<app>/*` |
| `auth/kubernetes` | ServiceAccount 기반 워크로드 인증 |
| `database/` | PostgreSQL 단기 자격증명. 연결은 `sslmode=verify-full` |
| `pki/` | 내부 workload TLS/mTLS. root CA는 `ktcloud4-bean Internal CA` |
| audit device `stdout/` | 감사 이벤트를 Pod 로그로 |
| `auth/oidc` | Vault UI 사람 로그인(VAULT-03). Keycloak `platform` realm confidential client `vault` |

`UPDATE-02`의 `renovate` policy와 Kubernetes auth role은 `renovate` namespace의 동명
ServiceAccount만 `audience=vault`로 허용하고 `kv/renovate/runtime` 한 경로만 읽힌다. GitHub
token은 `gitops/tools/update-02/provision.sh`가 KV로 직접 옮기며,
상시 container에는 Vault ServiceAccount token을 주지 않는다.

policy는 앱 하나당 하나씩 두고 자기 경로만 연다. 명시하지 않은 경로는 Vault 기본 deny다.

## audit device 선택

`file_path=stdout`으로 Pod 로그에 쓴다. PVC에 쓰면 Vault가 로테이션을 하지 않아
4Gi PVC가 차는 순간 **Vault가 모든 요청을 거부한다**. 등록된 audit device가 전부 실패하면
Vault는 동작을 멈추도록 설계돼 있기 때문이다.

Pod 로그는 k3s가 로테이션하므로 그 위험이 없다. 대신 Pod가 재생성되면 과거 로그는 사라진다.
Wazuh 도입 시 노드의 Pod 로그를 agent가 수집하거나 file/socket device를 **추가**하면 되고,
보안/운영 분류, 필수 필드, 마스킹과 Wazuh 90일 보존 기준은
[`AUDIT-01` 이벤트 표준](../../docs/audit-event-standard.md)이 소유한다. audit device는 여러 개를
동시에 붙일 수 있다.

## 실행

root token은 저장소 밖 mode `0600` 파일에서만 읽는다.

```bash
export VAULT_ROOT_TOKEN_FILE=<저장소 밖 경로>/vault-root.token
export PG_VAULT_PASSWORD_FILE=<저장소 밖 경로>/pgvault.pw
infra/vault/scripts/configure.sh
```

스크립트는 token과 비밀번호를 **stdin과 임시 파일로만** 전달한다. 명령 인자나 환경변수
선언에 넣지 않아 프로세스 목록·셸 기록에 남지 않는다.

database 연결을 만든 직후 `rotate-root`를 호출해 사람이 아는 비밀번호를 즉시 폐기한다.
그 뒤로는 Vault만 그 자격증명을 안다. 복구가 필요하면 PostgreSQL superuser로 재설정한다.

## 파일

| 경로 | 역할 |
|---|---|
| `scripts/configure.sh` | mount·auth·policy·role 생성 (재실행 가능) |
| `scripts/policies/*.hcl` | 앱별 policy 원문 |
| `scripts/configure-bkp03-snapshot.sh` | BKP-03 snapshot read policy·periodic token 선언 |
| `scripts/configure-vault-03-oidc.sh` | VAULT-03 `auth/oidc`, `vault-ui-operator` policy, `/platform-privileged` identity group-alias 선언 |
| `scripts/verify-bkp03-isolated-restore.sh` | Service 없는 별도 Vault에서 Raft restore 검증·정리 |
| `restore/bkp03-isolated-restore.yaml` | loopback·default-deny·임시 Raft restore Pod |

policy 파일은 Git이 소유한다. 값이 아니라 **권한 경계**라 커밋해도 비밀이 새지 않는다.

## 앱 소비 결정

VAULT-02는 소비 기반까지만 만들었다. 첫 소비자인 Keycloak은
[ADR-0013](../../docs/adr/0013-keycloak-secret-consumption.md)에 따라 cluster-wide injector나
CSI provider를 설치하지 않고, 자기 Pod에 명시한 Vault Agent init으로 기동 시점 값만
메모리에 렌더링한다. 이후 앱이 같은 방식을 자동 승계한다는 뜻은 아니며 지속 회전과
consumer 수를 기준으로 다시 선택한다.

## BKP-03 snapshot 경계

BKP-03 정기 job은 `sys/storage/raft/snapshot` read와 자기 token 조회·갱신만 가진 전용
periodic token을 사용한다. root token은 policy·token 최초 선언 때 stdin으로만 쓰고 정기
job에는 저장하지 않는다. live Vault가 sealed이면 작업자가 unseal하지 않고 중단한다.

restore API는 live `vault/vault-0`에 절대 호출하지 않는다. 검증 스크립트는 고정 격리
namespace의 Service 없는 Pod에만 snapshot-force하고, 원본 unseal key는 저장소 밖 mode
`0600` 파일에서 요청 본문으로 전달한다. KV marker, Kubernetes auth role의 고정 필드,
`keycloak` policy를 `set -eu` 검증 shell에서 조회하고 SHA-256을 live 값과 비교한다. 요청별
응답 필드는 비교에서 제외하며 결과 report에는 hash와 격리 조건만 기록한다. 실행 gate와 정리 증거는
[BKP-03 런북](../../docs/runbook/postgres-vault-native-backup.md)이 소유한다.
