# Vault 단일 replica Raft 기준선 (`docs/runbook/vault-raft-baseline.md`)

- 검증일: 2026-07-31 (`VAULT-01` 라이브 검증)
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

## 5. Shamir 구성과 초기화

- shares: 5, threshold: 3 (HashiCorp 기본값)
- `KMS-01`(AWS KMS auto-unseal, `DEFERRED`) 전환 전까지만 유효한 운영 값. 전환 시 recovery key로 재생성됨
- 초기화 명령(출력은 즉시 파일로 리다이렉트, 터미널에 출력하지 않음):

```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > vault-init-output.json
chmod 600 vault-init-output.json
```

### unseal — CLI 대화형 프롬프트가 TTY 없이는 동작하지 않는 이유

`vault operator unseal`을 인자 없이 파이프로 값을 흘려 넣으면
`file descriptor 0 is not a terminal` 오류로 실패한다(라이브 확인). key를 **첫 번째 위치 인자**로
주는 방법은 공식적으로는 되지만 원격 호스트의 `ps`에 순간적으로 노출될 수 있어 "shell 인자로
남기지 않는다" 요구와 충돌한다. 대신 HTTP API를 TLS로 직접 호출해 key를 **요청 본문**으로만
전달한다(`PUT /v1/sys/unseal {"key": "..."}`). 이 방식은 인자·프롬프트·로그 어디에도 key가
노출되지 않는다.

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
| `kubectl get secret -n vault` | 0건 (TLS key도 Secret 미사용) |
| Pod 로그·`vault-init-output.json` 대조 | unseal key/root token 문자열이 Pod 로그에 0건 |
| Node/DiskPressure/SELinux/swap/failed unit | Ready / False / Enforcing / 0 / 0 |
| `vault-0` `restartCount` | 0 (재시작은 Pod 재생성, crash loop 아님) |
| 임시 자원 정리 | helper Pod 2개, port-forward, 로컬 검증 스크립트·파일 정리 완료 |

## 7. 로컬 복구 절차

1. `k3s-01`에 SSH 후 `sudo /usr/local/bin/k3s kubectl get pod vault-0 -n vault`로 상태 확인.
2. `sealed:true`면 저장소 밖 암호화 보관소에서 unseal key(threshold 3개 이상)를 꺼낸다.
3. `kubectl port-forward -n vault svc/vault <local>:8200`로 로컬 접근을 연다.
4. `PUT https://vault.vault.svc.cluster.local:<local>/v1/sys/unseal` 본문 `{"key": "<key>"}`를
   서로 다른 key로 3회 호출(`--resolve`와 신뢰 CA 지정, `-k` 금지).
5. `sys/seal-status`에서 `sealed:false`, `initialized:true`를 확인.
6. root token은 초기화·복구 검증에만 사용하고 일상 작업에 쓰지 않는다(`VAULT-02`가 앱별 policy/auth를 구성).

## 8. rollback 경계

실패 시 되돌릴 대상은 다음으로 한정한다.

- k3s-01의 `vault` namespace 전체(Pod/StatefulSet/Service/ConfigMap/PVC/ServiceAccount) 삭제
- `argocd` namespace의 AppProject `vault`, Application `vault` 삭제
- `platform-root` Application의 `targetRevision`을 `main`으로 복귀
- `task/vault-01` 브랜치는 병합 전이면 삭제하지 않고 보존, 병합 후 실패가 드러나면 revert 커밋으로 처리

다음은 이 작업의 rollback 대상이 **아니다**: 다른 namespace, GITOPS-01이 만든 `argocd` 핵심 리소스,
OPNsense·Proxmox·OpenTofu state, k3s 자체, Keycloak, INGRESS-01/BKP-04 등 병렬 작업의 변경분.

## 9. 이 문서가 다루지 않는 것

| 내용 | 범위 |
|---|---|
| KV v2, Kubernetes auth, DB secrets engine, PKI, audit device, 앱별 policy | `VAULT-02` |
| PostgreSQL native backup·Vault Raft snapshot | `BKP-03` |
| AWS KMS auto-unseal 전환 | `KMS-01`(`DEFERRED`) |
