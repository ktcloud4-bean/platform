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

policy는 앱 하나당 하나씩 두고 자기 경로만 연다. 명시하지 않은 경로는 Vault 기본 deny다.

## audit device 선택

`file_path=stdout`으로 Pod 로그에 쓴다. PVC에 쓰면 Vault가 로테이션을 하지 않아
4Gi PVC가 차는 순간 **Vault가 모든 요청을 거부한다**. 등록된 audit device가 전부 실패하면
Vault는 동작을 멈추도록 설계돼 있기 때문이다.

Pod 로그는 k3s가 로테이션하므로 그 위험이 없다. 대신 Pod가 재생성되면 과거 로그는 사라진다.
Wazuh 도입 시 노드의 Pod 로그를 agent가 수집하거나 file/socket device를 **추가**하면 되고,
보존 기준은 `AUDIT-01`이 소유한다. audit device는 여러 개를 동시에 붙일 수 있다.

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

policy 파일은 Git이 소유한다. 값이 아니라 **권한 경계**라 커밋해도 비밀이 새지 않는다.
