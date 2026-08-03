# cert-manager와 Vault PKI 연결

이 디렉터리는 `CERTMGR-01`의 cert-manager controller·webhook·cainjector, CRD 여섯 개와
`ClusterIssuer/vault-internal` 선언을 소유한다. `PKI-01`에서는 첫 consumer인 CrowdSec용
`vault-crowdsec-agent`·`vault-crowdsec-lapi` ClusterIssuer와 각 Issuer 전용 ServiceAccount도
소유한다. 실제 consumer Certificate와 TLS 활성화 선언은 `gitops/apps/crowdsec/`가 소유한다.

## 고정 release와 변경 경계

공식 cert-manager `v1.21.1` 정적 manifest를 [`install.yaml`](install.yaml)로 vendoring했다.
upstream manifest SHA-256, source commit, controller·webhook·cainjector와 잠재 ACME solver의
OCI index/amd64 digest는 [`release-metadata.env`](release-metadata.env)가 소유한다. 실제 선언의
모든 image 참조는 `tag@sha256:index` 형식이다.

upstream에서 바꾼 것은 다음 두 가지뿐이다.

1. 네 image 참조를 OCI index digest로 고정했다.
2. controller와 cainjector leader election Role·RoleBinding·인자를 `kube-system`에서
   `cert-manager` namespace로 옮겨 AppProject 목적지를 하나로 닫았다.

선언한 CRD는 `Certificate`, `CertificateRequest`, `Issuer`, `ClusterIssuer`, ACME `Order`,
`Challenge` 여섯 개다. ACME issuer나 외부 solver를 구성하지 않지만 controller가 가리키는 solver
image도 mutable tag로 남기지 않는다. 큰 CRD는 child Application의 server-side apply로 처리한다.
cainjector가 관리하는 webhook·CRD conversion `caBundle`만 Argo diff에서 제외하며 다른 필드는
self-heal 대상이다.

## 인증서 소유와 인증 경계

```text
Certificate
  -> cert-manager controller
     -> TokenRequest(ServiceAccount/cert-manager-vault-issuer, audience=vault://vault-internal)
        -> Vault auth/kubernetes/role/cert-manager-vault-issuer
           -> policy cert-manager-vault-issuer
              -> pki/sign/cert-manager-internal-workload
  <- signed chain
  -> consumer namespace의 TLS Secret
```

- Vault는 내부 CA key, trust domain, 발급 policy와 PKI role을 계속 소유한다.
- cert-manager는 Kubernetes 내부 Certificate의 CSR·갱신·Secret 반영만 소유한다. private key는
  cert-manager가 생성해 consumer namespace Secret에 두며 Vault와 Git에는 보내지 않는다.
- `ClusterIssuer/vault-internal`은 Vault server의 공개 자체서명 인증서를
  `Secret/vault-server-ca`에서 읽는다. 이 Secret에는 private key나 credential이 없다.
- Issuer 전용 ServiceAccount는 자동 token mount가 없고, controller는 이름이 고정된
  `serviceaccounts/token` subresource만 `create`할 수 있다. Vault auth role도 같은 ServiceAccount,
  namespace와 Issuer 고유 audience에 묶인다.
- Vault policy는 `pki/sign/cert-manager-internal-workload`의 `update`만 허용한다.
  기존 `pki/sign/internal-workload`, private key를 반환하는 `pki/issue/*`, KV·database·sys 경로는
  열지 않는다.
- Proxmox·OPNsense·Traefik ingress·Warpgate의 공인 인증서는 이 controller가 소유하지 않는다.

선택 이유와 Secret/private-key 경계는
[ADR-0016](../../../docs/adr/0016-cert-manager-vault-pki-lifecycle.md)이 소유한다.

## Vault 구성

[`provision.sh`](../../tools/certmgr-01/provision.sh)는 `VAULT-CONFIG` 잠금 아래 다음 세 리소스만
`check`, `apply`, `rollback`한다.

| 종류 | 이름 | 경계 |
|---|---|---|
| PKI role | `cert-manager-internal-workload` | cluster-local hostname, EC P-256, max TTL 720h |
| policy | `cert-manager-vault-issuer` | 위 role의 `sign` endpoint 한 개 |
| Kubernetes auth role | `cert-manager-vault-issuer` | 전용 SA·namespace·audience, no-default-policy, 1분 token |

root token은 저장소 밖 mode `0600` 파일에서 stdin으로만 Vault Pod에 전달한다. 스크립트는
root token·ServiceAccount JWT·Vault token을 출력하거나 명령 인자에 넣지 않는다. 이 구성은
Vault init·seal migration·기존 `pki/roles/internal-workload`를 바꾸지 않는다. `KMS-01`의
`VAULT-INIT` 창과 동시에 실행하지 않는다.

### PKI-01 CrowdSec 경계

CrowdSec는 혼합 role 하나를 쓰지 않는다. agent role은 정확한
`crowdsec-agent.crowdsec-01.svc.cluster.local`, `clientAuth`, 고정 `agent-ou`만 발급하고 LAPI
role은 정확한 `crowdsec-service.crowdsec-01.svc.cluster.local`, `serverAuth`만 발급한다. LAPI
서버 인증서에 agent 권한을 함께 넣는 것보다 role·policy·Kubernetes auth audience를 둘로 나누는
쪽이 더 좁다.

[`gitops/tools/pki-01/provision.sh`](../../tools/pki-01/provision.sh)는 `VAULT-CONFIG` 잠금 아래
두 PKI role, 각 signing endpoint 하나만 여는 policy 두 개와 Issuer별 Kubernetes auth role 두
개만 `check`, `apply`, `rollback`한다. 공용 `internal-workload` role과 `CERTMGR-01` 리소스는
바꾸지 않는다. Vault server의 공개 CA는 같은 `files/vault.crt` 단일 원본에서 CrowdSec
namespace의 ConfigMap으로도 렌더하며 credential이나 private key를 포함하지 않는다.

## 검증과 commit 순서

[`verify-static.sh`](../../tools/certmgr-01/verify-static.sh)는 고정 hash·image 네 개·CRD 여섯 개,
ClusterIssuer signing path와 Kustomize 렌더만 확인한다. 라이브 완료 증거는
[`verify-live.sh`](../../tools/certmgr-01/verify-live.sh)의 세 단계로 한 번씩 판정한다.

1. `capacity-pre`: 배포 직전 available RAM과 PVC 선언 합계를 각 한 번 측정한다.
2. `issue-renew`: immutable root/child `Synced/Healthy`, controller Pod 세 개, Vault 타 PKI role
   `403`, 배포 후 RAM/PVC, 시험 Certificate 한 장의 최초 발급·Secret·chain과 단축
   `duration: 1h`/`renewBefore: 55m` 자동 갱신 한 사이클을 확인한다. 시험 자원은 sealed 시험에
   그대로 이어 쓰되 승인 대기 중 추가 갱신이 생기지 않도록 한 사이클 직후 `renewBefore: 5m`으로
   quiesce하므로 이 단계가 성공했을 때만 잠시 남는다.
3. `sealed-cleanup`: 별도 승인 직후 Vault를 seal하고 같은 Secret의 기존 인증서 chain 유효성을
   한 번 확인한다. 같은 Certificate의 duration만 바꿔 다음 revision 발급이 Vault sealed 오류로
   실패하고 기존 revision·fingerprint가 유지되는 것을 한 번 확인한다. 이때 같은 Certificate의
   `duration: 61m`/`renewBefore: 55m`을 함께 적용해 다음 revision 한 번만 즉시 요청한다.
   `KMS-01` 이후의
   `seal_type=awskms`에서는 recovery share를 입력하지 않고 `vault-0` Pod를 한 번 재생성해 AWS KMS
   auto-unseal한다. `sealed=false`, `seal_type=awskms`, Pod Ready와 Issuer Ready를 확인한 뒤
   Certificate·CertificateRequest·Secret을 제거한다.

`issue-renew`에서 capacity·Vault policy가 이미 PASS한 뒤 시험 CSR만 실패했다면 같은 branch에서
원인을 고치고 `issue-renew-retry`로 재개한다. 이 mode는 immutable root/child와 controller 준비만
기다리고 이미 한 번 판정한 capacity·타 PKI path `403`은 반복하지 않는다.

sealed 시험의 기존 인증서 PASS 뒤 신규 발급 유도만 실패했다면 복구·시험 자원 제거를 먼저
확인한다. 같은 이름의 Certificate를 정상 Vault에서 revision 1로 다시 준비한 뒤
`CERTMGR01_EXPECTED_SEALED_REVISION=1`, `CERTMGR01_VERIFY_SEALED_EXISTING=false`로 재개해 이미
판정한 기존 인증서 항목은 반복하지 않고 신규 발급 실패와 auto-unseal·제거만 닫는다.

merge 전 commit은 다음 순서를 따른다.

1. 최신 `origin/main`에 rebase한 **설정 commit**을 push한다. 이 commit의 child
   `targetRevision`은 literal `main`이다.
2. 다음 **pointer commit**에서 `cert-manager` child만 설정 commit SHA로 고정하고,
   `platform-root`를 pointer commit SHA로 전환한다. 둘 다 immutable SHA에서
   `Synced/Healthy`여야 한다.
3. 검증과 rollback 뒤 branch의 child를 literal `main`으로 복구한 최종 commit을 만든다.
   mutable branch 이름은 어느 Application에도 넣지 않는다.

## Argo revert rollback

시험 Certificate와 Secret을 먼저 제거한 뒤 아래 순서로 branch 배포를 되돌린다. cert-manager는
PVC와 실제 consumer를 아직 소유하지 않으므로 이 rollback은 controller·CRD·전용 namespace만
제거한다.

1. `platform-root` automated sync를 잠시 끈다.
2. `Application/cert-manager`를 foreground 삭제해 controller와 CRD를 제거한다.
3. 남은 `cert-manager` namespace를 삭제하고, prune 보호한 `AppProject/cert-manager`를 삭제한다.
4. root `targetRevision`과 automated sync를 시작 main SHA로 복구한다.
5. 배포 전에 있던 Application 집합이 다시 모두 `Synced/Healthy`이고 cert-manager Application,
   AppProject, namespace가 없는지 확인한다.
6. branch의 child 선언이 literal `main`인 것을 확인한 뒤 `ARGO-ROOT` 잠금을 푼다.

merge 뒤 main sync를 위해 Vault의 전용 PKI role·policy·auth role은 Argo revert에서 보존한다.
작업을 완전히 폐기할 때만 `provision.sh rollback`으로 이 세 개를 제거하며 Vault root CA,
`pki/`, 기존 role과 다른 앱 policy는 건드리지 않는다.

## 2026-08-03 라이브 결과

| 완료 증거 | 결과 |
|---|---|
| 고정 선언 | cert-manager `v1.21.1`, CRD 6개, image index digest 4개, patched install SHA-256 `f44b017192cdc6a51b950a685e14bebc61c134606a4e773c85ba3655c8954c53` |
| immutable Argo | 최신 main rebase 뒤 root pointer `bcbf1d8b5417c5680b12498e3b3b52d6327048c9`, child 설정 `1432e30835a35f9644339863128498b50ec1836a`에서 `Synced/Healthy`, controller 3개와 `vault-internal` Ready |
| Vault 권한 | 전용 auth role 로그인과 `pki/sign/cert-manager-internal-workload` 발급 성공, 기존 `pki/sign/internal-workload`는 `403` |
| capacity | 최신 main rebase 뒤 배포 전/후 available `13,840,269,312` → `13,560,250,368` bytes, PVC 선언 합계 `97,844,723,712` bytes 불변으로 정지선 통과 |
| Certificate | `certmgr-01-test` 한 이름으로 revision 1 발급, TLS Secret key 3개와 chain 확인, `renewBefore: 55m`에서 revision 2와 fingerprint 변경 후 `5m`으로 quiesce |
| sealed | 기존 revision 2 chain·fingerprint 유지, 신규 revision 요청만 Vault 오류로 `Ready=False`; `vault-0` 한 번 재생성 뒤 `awskms` auto-unseal·Issuer Ready |
| 제거·rollback | 시험 Certificate·CertificateRequest·Secret 제거, 최신 시작 main `a02291319577f5c6743cc53d03cd0e59ef79dcc9`로 Argo revert, cert-manager Application·AppProject·namespace 부재, 기존 Application 21개 전부 `Synced/Healthy`로 배포 전 집합과 동일 |

merge 전 실패는 모두 같은 branch에서 원인을 확인한 뒤 시작 main SHA로 되돌렸다. 시험 CSR의
필수 CN 누락과 SSH를 건넌 jsonpath·JSON patch quoting, Argo SHA 판정 변수 충돌을 고쳤고, 이미
PASS한 capacity·Vault `403`·sealed 기존 인증서는 재실행하지 않고 실패한 뒤쪽 증거만 이어서
판정했다. 최종 선언의 child `targetRevision`은 literal `main`이며 실제 consumer는 연결하지 않았다.
