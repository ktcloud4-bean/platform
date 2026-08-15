# SUPPLY-01-FIX-01 증거

## 판정

`DONE` — EKS Kyverno가 전용 private TUF egress 경로를 통해 mirror를 사용할 수
있도록 보정했고, immutable Argo 검증과 허용 admission을 완료했다.

## 실패 지점과 최소 보정

- 시작 main SHA: `7e892947467353d7713f85a8f9b5829ea0b27168`
- 원래 실패는 서명 부재가 아니라 Kyverno의 TUF mirror URL이 외부 CDN으로 직접
  나가려다 `connection refused`/timeout 난 것이었다. private EKS에는 NAT/IGW
  default route가 없고, 기존 ADR의 NAT 및 `0.0.0.0/0` 금지 경계도 유지했다.
- `k3s-01`에 persistent secondary `10.10.20.12/24`를 추가하고, 이 주소에만
  hostNetwork CONNECT proxy를 배포했다. proxy는 EKS app subnet
  `10.20.10.0/24`, `10.20.20.0/24`에서 `tuf-repo-cdn.sigstore.dev:443`만
  CONNECT 허용하며 upstream도 `10.10.20.12`로 bind한다.
- OPNsense에는 CDN FQDN alias와 다음 세 exact rule만 추가했다: proxy source
  `.12` → CDN TCP 443, 두 EKS subnet → `.12:8445`. EKS node SG rule은
  `tofu-app-eks`가 소유하도록 `10.10.20.12/32:8445` 한 건만 추가했다.
- Kyverno에는 `HTTPS_PROXY`를 주입하고 Kubernetes Service CIDR
  `172.20.0.0/16`을 `NO_PROXY`에 추가했다. 처음 rollout이 hostNetwork Pod IP
  `.10`을 probe한 문제는 probe host를 listener `.12`로 고쳐 해결했다.

## 정적 검증

- `kubectl kustomize gitops/apps/obs` PASS
- `kubectl kustomize gitops/apps/kyverno-eks` PASS
- policy의 current/previous `tuf.mirror`, CycloneDX referrer,
  `verifyAttestationSignatures`, `extractPayload`, `failurePolicy=Fail`,
  `validationActions=Deny` 렌더링 PASS
- Ansible syntax check, Python compile, `git diff --check`, OpenTofu fmt/validate
  PASS
- `tofu-app-eks` plan/apply는 `1 added, 0 changed, 0 destroyed`; `tofu-app-network`
  은 기존 inline/external SG drift가 있어 apply하지 않았다.

## immutable live 검증

- validation root `d1aac17d383208c494798a92a0c39cdff9e21842`, child implementation
  `e649b4fbe5de6be2d25e76bddc08b4d8b25d428e`에서 `platform-root`, `obs`,
  `kyverno-eks`가 각각 `Synced/Healthy/Succeeded`였다.
- EKS admission controller Pod는 `Ready=true`, restart 0이며 Kyverno의
  `NO_PROXY`에 `172.20.0.0/16`이 live 반영됐다.
- 기존 SUPPLY-01 양성 fixture인 ECR `aws-load-balancer-controller` digest를
  `kube-system`에 `kubectl create --dry-run=server`로 1회 제출해
  `pod/supply-01-tuf-proof created (server dry run)` 및 `admission=PASS`를
  확인했다. 실제 Pod와 데이터는 만들지 않았다.
- 서명 또는 CycloneDX attestation이 없는 HR 기존 digest는 동일 정책에서
  거부됐다. 이는 TUF egress 실패가 아니라 `failurePolicy=Fail`의 의도된 음성
  결과이므로 성공으로 오판하지 않았다.

OPNsense는 live validation 뒤 `check-drift.sh --update`로 마스킹 snapshot을
갱신하고 일반 drift check에서 `드리프트 없음`을 확인했다. AWS/VPC public egress,
NAT, 공개 DNS, 데이터/PVC/VM 삭제는 수행하지 않았다.
