# Vault 단일 replica Raft 기준선 (`docs/runbook/vault-raft-baseline.md`)

- 검증일: 2026-08-03 (`VAULT-01` 기준선 + `KMS-01` seal migration)
- 대상: k3s-01 `vault` namespace (Argo CD `platform-root` → child Application `vault`)
- seal/bootstrap 경계: [ADR-0006](../adr/0006-vault-seal-and-bootstrap-boundary.md)

## 1. 버전과 공급망

| 항목 | 값 |
|---|---|
| Vault | `2.0.3` (2026-06-17 공식 릴리스) |
| image | `hashicorp/vault:2.0.3` (Docker Hub 공식 `hashicorp` organization) |
| image digest | `sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54` (`skopeo inspect`로 확인, 실행 Pod `imageID`와 대조 완료) |
| 라이선스 | Business Source License 1.1 (`BUSL-1.1`); 각 버전 출시일로부터 4년 뒤 `MPL-2.0`로 전환. 경쟁 호스팅 서비스가 아닌 이 랩의 내부 사용은 허용 범위 |
| Kubernetes 대상 | k3s `v1.36.2+k3s1` |
| 배포 방식 | `hashicorp/vault-helm` chart(v0.34.0, app-version 2.0.3)는 참고용일 뿐 사용하지 않음. `gitops/apps/vault/`의 원시 manifest(Kustomize)로 선언 |

고정값 단일 원본은 [`gitops/apps/vault/release-metadata.env`](../../gitops/apps/vault/release-metadata.env)다.

## 2. GitOps 구조

```text
gitops/root/
  app-project.yaml        platform-root AppProject (Application kind whitelist 추가)
  vault-project.yaml      AppProject "vault" — 목적지 namespace vault 전용, 최소 kind whitelist
  vault-application.yaml  child Application "vault" (source path gitops/apps/vault)
gitops/apps/vault/
  namespace.yaml
  serviceaccount.yaml     automountServiceAccountToken: false (K8s auth는 VAULT-02 범위)
  configmap.yaml          vault.hcl (listener/storage/disable_mlock)
  pvc.yaml                vault-data 4Gi, local-path (volumeClaimTemplate 아님 — 고정 이름 PVC)
  service.yaml            vault(ClusterIP) + vault-internal(headless, 8200/8201)
  statefulset.yaml        replicas 1, Raft storage
```

`vault` Application은 전용 AppProject를 쓰고 destination을 `namespace: vault` 하나로 제한한다.
`platform-root` 자체의 `namespaceResourceWhitelist`에는 `argoproj.io/Application` kind만
추가했고 `clusterResourceWhitelist`는 비워 둔다(Namespace 생성 권한은 `vault` project에만 부여).

## 3. TLS: Kubernetes Secret을 쓰지 않는 이유와 구현

`VAULT-01` 지침은 TLS private key를 Git, 채팅, 로그, shell 인자뿐 아니라
**Kubernetes Secret 원문으로도 남기지 않을 것**을 요구한다. 따라서 인증서는 Secret이 아니라
`vault-data` PVC 내부 파일(`/vault/data/tls/vault.crt`, `/vault/data/tls/vault.key`, mode
`0600`/`0644`, owner `100:1000`)로만 존재한다. `kubectl get secret -n vault`는 항상 0건이다.

인증서는 PG-01과 동일하게 host-specific 자체서명 leaf 하나다(별도 CA 없음).

```bash
openssl req -x509 -newkey rsa:4096 -sha256 -days 365 -nodes \
  -keyout vault.key -out vault.crt \
  -subj "/CN=vault.vault.svc.cluster.local" \
  -addext "subjectAltName=DNS:vault.vault.svc.cluster.local,DNS:vault.vault.svc,DNS:vault,\
DNS:vault-0.vault-internal.vault.svc.cluster.local,DNS:vault-internal,\
DNS:vault-internal.vault.svc.cluster.local,DNS:vault.imcherry5778.xyz,DNS:localhost,IP:127.0.0.1"
```

### PVC 선(先)생성·부트스트랩 순서

`vault-data`를 StatefulSet `volumeClaimTemplates`가 아니라 **고정 이름 PVC**로 선언한 이유는,
Vault 컨테이너가 최초 기동 시 TLS 파일이 없으면 즉시 crash하므로 Pod가 뜨기 **전에** PVC에
인증서를 심어야 하기 때문이다.

1. `namespace.yaml`, `pvc.yaml`만 먼저 `kubectl apply`(WaitForFirstConsumer이므로 아직 Bound 안 됨)
2. 같은 PVC를 마운트하는 임시 helper Pod(`busybox`)를 떠서 Bound를 트리거
3. `kubectl exec`로 `/vault/data/tls/`, `/vault/data/raft/` 생성, 인증서 파일 주입, `chmod 600`/`644`, `chown 100:1000`
4. helper Pod 삭제
5. 이후 Argo CD가 나머지 리소스(StatefulSet 등)를 동기화하면 Pod가 이미 채워진 PVC를 그대로 사용

## 4. 알려진 함정: entrypoint의 암묵적 `-config` 중복

공식 `hashicorp/vault` 이미지의 `docker-entrypoint.sh`는 `args[0]=server`일 때 자동으로
`-config=/vault/config`(디렉터리 전체)를 추가한다. 여기에 사용자가 `-config=/vault/config/vault.hcl`을
**추가로** 넘기면 같은 `listener "tcp"` 블록이 두 번 로드되어 `0.0.0.0:8200` bind가
충돌하고 `CrashLoopBackOff`(`Error initializing listener of type tcp: ... address already in use`)가
발생한다. 라이브에서 재현·확인했다. `statefulset.yaml`의 `args`는 `["server"]`만 남긴다
(디렉터리에 파일이 하나뿐이므로 결과적으로 같은 `vault.hcl`이 로드된다).

## 5. seal 구성과 KMS-01 migration

Day 1 초기화는 Shamir shares 5, threshold 3이었다. `KMS-01` 이후에는 같은 5/3 구조의
**recovery key**를 쓴다. recovery key는 root token 재생성, recovery rekey와 Shamir seal로의
migration을 승인하지만 KMS가 unavailable인 Vault를 직접 unseal하지는 못한다.

Vault 선언은 다음 비밀이 아닌 값만 Git에 둔다.

```hcl
seal "awskms" {
  region     = "ap-northeast-2"
  kms_key_id = "alias/ktcloud4-bean-vault-auto-unseal"
}
```

endpoint를 지정하지 않아 공인 AWS KMS API를 사용한다. IAM access key 원본은 저장소 밖
`$KTC_SECRET_ROOT/kms-01/env`, runtime copy는 `vault/vault-awskms` Secret이다. ConfigMap,
StatefulSet manifest, Pod log와 명령 인자에는 credential 원문을 넣지 않는다. AWS resource와
state 경계는 [`infra/aws/tofu-kms/README.md`](../../infra/aws/tofu-kms/README.md)가 소유한다.

### Day 1 초기화 기록

초기화 때 쓴 명령은 다음과 같다. 이 명령을 migration된 live Vault에 다시 실행하지 않는다.

```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-init-output.json
chmod 600 vault-init-output.json
```

### secret-safe migration

`vault operator unseal`을 인자 없이 파이프로 값을 흘려 넣으면
`file descriptor 0 is not a terminal` 오류로 실패한다(라이브 확인). key를 **첫 번째 위치 인자**로
주는 방법은 공식적으로는 되지만 원격 호스트의 `ps`에 순간적으로 노출될 수 있어 "shell 인자로
남기지 않는다" 요구와 충돌한다. 대신 sealed Pod에 직접 `kubectl exec -i`하고 Vault CLI의
`vault write sys/unseal -`가 stdin의 JSON을 HTTPS request body로 보내게 한다. Service는 sealed
Pod를 Ready endpoint에서 제외하므로 migration 중 호출 경로로 쓰지 않는다. 이 방식은 key를
인자·프롬프트·로그에 남기지 않는다.

[`kms-01-seal-migrate.sh`](../../infra/vault/scripts/kms-01-seal-migrate.sh)는 strict SSH와
Pod 내부 loopback TLS를 사용하며 key를 stdin→HTTPS body로만 전달한다. Shamir→KMS에서는 현재
Shamir key 파일, KMS→Shamir에서는 현재 recovery key 파일을 준다. 세 번의 요청 모두
`migrate=true`다.

```bash
export KTC_SECRET_ROOT=${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}

# Shamir → AWS KMS
infra/vault/scripts/kms-01-seal-migrate.sh migrate \
  "$KTC_SECRET_ROOT/vault-unseal-keys.b64"

# AWS KMS → Shamir rollback drill
infra/vault/scripts/kms-01-seal-migrate.sh migrate \
  "$KTC_SECRET_ROOT/vault-recovery-keys.b64"

# Shamir 선언에서 재기동한 뒤의 일반 unseal(migration 아님)
infra/vault/scripts/kms-01-seal-migrate.sh unseal \
  "$KTC_SECRET_ROOT/vault-recovery-keys.b64"
```

KMS→Shamir 전에는 KMS seal block에 `disabled = "true"`를 넣은 immutable transient SHA를
root와 child가 읽어야 한다. 정상 auto-unseal 선언으로 돌아갈 때는 `disabled`를 제거한 새 SHA를
적용하고, Shamir key가 된 현재 3개 share로 다시 migrate한다.

최종 auto-unseal 뒤 recovery key는 verification을 켜서 5/3으로 재생성한다. 새 파일이 이미
있으면 script는 덮어쓰지 않는다.

```bash
infra/vault/scripts/kms-01-seal-migrate.sh rekey-recovery \
  "$KTC_SECRET_ROOT/vault-unseal-keys.b64" \
  "$KTC_SECRET_ROOT/vault-recovery-keys.b64"
```

verification 완료 전에는 기존 Shamir share가 유효하다. 완료 뒤에는 새 recovery share만
유효하므로 기존 `vault-unseal-keys.b64`를 폐기하고 이름을 바꿔 재사용하지 않는다.

## 6. 라이브 검증 결과

| 항목 | 결과 |
|---|---|
| Argo CD `platform-root`/`vault` Application | Synced/Healthy, revision이 main 병합 커밋과 일치 |
| 실행 imageID | `docker.io/hashicorp/vault@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54` (고정 digest와 일치) |
| StatefulSet | `1/1` Ready, replicas 1, storage raft |
| PVC | `vault-data` `Bound`, `local-path`, `4Gi` |
| TLS 정상 hostname + 신뢰 CA | `curl --resolve vault.vault.svc.cluster.local ... --cacert vault.crt` → HTTP 200/204 |
| TLS 잘못된 hostname | `curl --resolve wrong.example.com ...` → curl 60, "no alternative certificate subject name matches" |
| TLS 신뢰되지 않은 인증서 | `--cacert` 생략(시스템 기본 CA) → curl 60, "self-signed certificate" |
| 초기화 전 `sys/health` | `initialized:false sealed:true` |
| sealed 상태 비인증 요청 | `sys/mounts` → `503 Vault is sealed` |
| `vault operator init` | `unseal_keys_b64` 5개, `unseal_threshold` 3, `root_token` 발급 확인(값은 출력하지 않음) |
| unseal 3/5 | `sealed:false` 도달, `progress` 1→2→0 정상 |
| unseal 후 비인증 요청 | `sys/mounts` → `403 permission denied`(sealed 아님, 미인증) |
| unseal 후 root token 인증 요청 | `sys/mounts`, `sys/health` → `200` |
| Pod 단독 재시작(`kubectl delete pod vault-0`) | 새 Pod가 `sealed:true`로 기동(수동 unseal 상태는 재부팅마다 소실 — 설계대로) |
| 재시작 후 비인증 요청 | `sys/mounts` → `503 Vault is sealed` |
| 재시작 후 동일 3 key unseal | 성공, `sealed:false` |
| 재시작 전후 안전한 최소 상태 비교 | `cluster_id`, `cluster_name`, `n`, `t`, `storage_type`, seal `type` 모두 동일 → 같은 Raft 데이터가 영속됨 확인 |
| `kubectl get secret -n vault` | `VAULT-01` 당시 0건. `KMS-01` 이후 TLS key는 계속 Secret을 쓰지 않고, AWS SDK credential용 `vault-awskms` 한 개만 저장소 밖 원본에서 runtime reconcile |
| Pod 로그·`vault-init-output.json` 대조 | unseal key/root token 문자열이 Pod 로그에 0건 |
| Node/DiskPressure/SELinux/swap/failed unit | Ready / False / Enforcing / 0 / 0 |
| `vault-0` `restartCount` | 0 (재시작은 Pod 재생성, crash loop 아님) |
| 임시 자원 정리 | helper Pod 2개, port-forward, 로컬 검증 스크립트·파일 정리 완료 |

### KMS-01 seal 경계 결과

KV·auth·PKI는 `VAULT-02` 결과를 재검증하지 않았다. 상세 실행과 실패 판정은
[`docs/evidence/kms-01`](../evidence/kms-01/README.md)이 소유한다.

| 완료 증거 | 결과 |
|---|---|
| 사전 Raft snapshot | migration 전 175,605 bytes snapshot, SHA-256 `1edd1ae64a28787069e53656a7691e5ee8580647a5315c70ea4f616242e7d7b7` |
| KMS 장애 시험 | IAM inline policy만 회수하고 service credential `AccessDenied` 전파 뒤 Pod 한 번 재생성; KMS `AccessDenied`·NotReady, policy 복구 뒤 같은 Pod가 share 없이 auto-unseal |
| seal rollback drill | `awskms → disabled awskms → shamir → awskms`, 각 migration 완료 뒤 `migration=false`, 5/3 확인 |
| IAM·KMS 최소권한 | exact key의 `Encrypt`·`Decrypt`·`DescribeKey`만 허용; 대칭 single-Region key, rotation off, `prevent_destroy` |
| 비용·감사 | 월 USD 1 key + free tier 초과분 10,000 request당 USD 0.03; CloudTrail에서 성공 `Encrypt`·`Decrypt`와 거부 `DescribeKey`·`Encrypt` 확인 |
| 무인 재기동·Shamir 복귀 | migration 뒤 새 Pod가 share 입력 없이 unseal; 새 recovery key 5/3을 verification 완료해 클러스터 밖에 보존 |

## 7. 로컬 복구 절차

1. `k3s-01`에 strict SSH 후 `vault status`에서 `initialized`, `sealed`, `seal_type`만 확인한다.
2. `seal_type=awskms`, `sealed=true`면 recovery share를 unseal API에 넣지 않는다. IAM inline policy,
   access key active 상태와 공인 KMS API egress를 복구한다. Vault의 auto-unseal retry가 성공하면
   `sealed=false`가 된다.
3. KMS에서 독립해야 하는 유지보수·폐기라면 KMS가 다시 가용한 상태에서 사전 snapshot을 만들고,
   `disabled=true` KMS seal 선언으로 기동한 뒤 recovery share 3개를 `migrate=true`로 제출한다.
   `seal_type=shamir`, `sealed=false`를 확인한 뒤 KMS 선언과 credential runtime copy를 제거한다.
4. Shamir 상태의 다음 재부팅부터는 기존의 TLS HTTP API 방식으로 현재 share 3개를 제출한다.
5. root token은 초기화·복구 검증에만 사용한다. KV·auth·PKI 기능은 이 runbook의 seal 복구에서
   다시 판정하지 않는다.

## 8. rollback 경계

KMS-01 실패 시 되돌림은 seal 상태에 따라 순서를 지킨다.

- Shamir→KMS migration이 완료되기 전이면 시작 main SHA의 Shamir 선언으로 root/child를 되돌리고
  기존 Shamir share 3개로 unseal한다.
- migration 완료 뒤 Shamir로 되돌릴 때는 먼저 `disabled=true` KMS seal로 recovery share 3개를
  migrate한다. 이 성공 없이 KMS block을 삭제하지 않는다.
- 장애 시험의 IAM policy 회수는 `enable_vault_kms_access=true` plan 재적용으로 즉시 복구한다.
- 검증 종료 뒤 `platform-root`를 기록한 시작 main SHA로 되돌리고 child 선언이 literal `main`인지
  확인한다.
- PVC·Raft data, KMS key, backup bucket, 다른 namespace와 Vault Agent workload는 삭제하거나
  재생성하지 않는다.

KMS key의 `prevent_destroy`는 일상 rollback에서 해제하지 않는다. KMS key를 영구히 잃으면
recovery share만으로 auto-sealed storage를 열 수 없으므로, key 폐기는 Shamir migration과
재부팅을 끝낸 별도 작업만 소유한다.

## 9. 이 문서가 다루지 않는 것

| 내용 | 범위 |
|---|---|
| KV v2, Kubernetes auth, DB secrets engine, PKI, audit device, 앱별 policy | `VAULT-02` |
| PostgreSQL native backup·Vault Raft snapshot | `BKP-03` |
| AWS KMS key·IAM·비용·CloudTrail 기준 | `infra/aws/tofu-kms/README.md`와 `KMS-01` 증거 |
