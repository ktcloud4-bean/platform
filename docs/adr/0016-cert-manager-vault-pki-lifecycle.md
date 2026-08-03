# ADR-0016: Kubernetes 내부 인증서 lifecycle을 cert-manager와 Vault PKI로 분리

- 상태: `Accepted`
- 날짜: 2026-08-03
- 관련 작업: `CERTMGR-01`, `PKI-01`, `VAULT-02`, `OBS-01`

## 배경

Vault PKI는 내부 workload CA와 발급 정책을 소유하지만 Certificate의 갱신 시점, private key 생성,
Kubernetes Secret 반영과 consumer reload를 조정하지 않는다. `OBS-01` 당시에는 cert-manager
consumer가 없어 controller 세 개를 먼저 설치하지 않았고, 인증서 만료는 blackbox probe로만
관측했다. 첫 실제 mTLS consumer를 CrowdSec agent와 LAPI로 정하면서 자동 발급·갱신 controller를
선택해야 한다.

CrowdSec chart의 self-signed CA는 Vault와 별도 trust domain을 만들고 CRL 경계를 제공하지 않는다.
반대로 consumer가 Vault API를 직접 호출하게 하면 앱마다 TokenRequest, CSR, 갱신과 Secret 갱신
로직을 다시 구현해야 한다.

## 결정

Vault를 Kubernetes 내부 인증서의 유일한 CA와 발급 정책 소유자로 유지하고, cert-manager를
Kubernetes 내부 Certificate lifecycle controller로 도입한다. cert-manager는 Vault
`ClusterIssuer`를 통해 CSR만 전달하며 CA key를 받지 않는다. private key는 cert-manager가
생성해 consumer namespace의 Kubernetes TLS Secret에 저장하고 Git이나 Vault로 보내지 않는다.

Vault 인증은 정적 token Secret 대신 Issuer 전용 ServiceAccount의 단기 TokenRequest와 Kubernetes
auth를 사용한다. ServiceAccount, namespace, Issuer 고유 audience를 Vault auth role에 묶고,
전용 policy에는 전용 PKI signing endpoint 한 개만 허용한다. consumer별 이름·OU·용도 경계는
공용 role을 넓히지 않고 후속 작업의 별도 PKI role과 policy로 더 좁힌다.

cert-manager는 Vault PKI가 대상으로 삼는 Kubernetes 내부 TLS·mTLS에만 사용한다. Proxmox,
OPNsense, Traefik ingress와 Warpgate의 공인 인증서 발급자·private key·DNS credential 소유 경계는
바꾸지 않는다. 첫 consumer 연결과 reload·폐기 판정은 `PKI-01`이 소유한다.

## 검토한 대안

- **CrowdSec chart self-signed CA:** 설치는 단순하지만 내부 CA가 하나 더 생기고 Vault의 발급·CRL
  경계와 분리된다.
- **consumer별 Vault 직접 호출:** controller Pod는 줄지만 모든 consumer가 CSR·갱신·Secret 반영과
  실패 복구를 구현해야 해 권한과 운영 로직이 복제된다.
- **cert-manager 자체 CA Issuer:** Vault 장애와는 분리되지만 CA private key가 Kubernetes Secret에
  들어가고 `VAULT-02`가 확정한 내부 trust domain을 우회한다.
- **Vault CSI/Agent로 파일 렌더:** Secret 저장을 피할 수 있지만 자동 CSR lifecycle과 consumer별
  reload를 별도 구현해야 하며 현재 단일 노드에 cluster-wide CSI 권한을 추가한다.

## 결과

- cert-manager controller·webhook·cainjector Pod 세 개와 cluster-scoped CRD·RBAC가 추가된다.
- Vault가 sealed여도 이미 발급되어 Secret에 저장된 인증서는 만료 전까지 유효하지만 신규 발급과
  갱신은 실패한다. 따라서 duration과 `renewBefore`가 Vault 복구 허용시간을 결정한다.
- consumer private key가 Kubernetes Secret에 존재하므로 namespace RBAC, backup과 Secret 조회
  감사가 인증서 보호 경계가 된다. GitOps는 그 Secret의 원문을 소유하지 않는다.
- cert-manager 장애는 기존 인증서를 즉시 무효화하지 않지만 다음 갱신을 막는다. 관측은 만료 시각과
  Issuer/Certificate 상태를 함께 봐야 한다.
- 실제 consumer가 없는 `CERTMGR-01` rollback은 CRD·controller·namespace를 제거할 수 있다.
  consumer가 생긴 뒤의 제거는 각 Certificate와 reload 경로를 먼저 되돌리는 별도 작업이어야 한다.

## 재검토 조건

- Kubernetes Secret에 private key를 두는 것이 허용되지 않는 workload가 생긴다.
- 여러 cluster가 같은 Vault PKI를 사용해 Issuer별 audience·role 관리가 복잡해진다.
- cert-manager 또는 Vault issuer 유지가 중단되거나 Kubernetes 호환 범위를 벗어난다.
- Vault sealed 허용시간이 인증서 갱신 여유를 반복해서 초과한다.
