# Kyverno 정책 기준선

이 디렉터리는 `POL-01`/`POL-02`의 Kyverno admission·reports controller를 소유한다. 공식 Helm chart
`3.8.2`/Kyverno `v1.18.2`와 [`values-pol-01.yaml`](values-pol-01.yaml)로 생성한 원시 manifest,
공식 release CRD를 저장소에 고정했다. 실제로 렌더되는 세 image는 tag와 OCI index digest를
함께 고정한다. generate·mutate-existing용 background controller와 CleanupPolicy용 cleanup
controller는 배포하지 않는다. CRD는 controller가 참조하는 API schema일 뿐 POL-01 정책
카탈로그가 아니며, 실제 정책 선언은 Audit 규칙 한 건뿐이다.

## 적용 경계

- 정책 카탈로그를 넓히지 않고 기존 Pod의 pod-level `runAsNonRoot` 누락 한 규칙만 Enforce한다.
- PolicyException은 admission·reports controller에서 활성화하되 `kyverno` namespace의 객체만
  인식한다. 정책 child가 소유한 예외는 live Audit 위반 workload와 두 정확한 rule에만
  적용되고, 각 조건의 UTC 만료 시각 뒤에는 admission bypass가 자동으로 끝난다.
- 예외는 background scan에 적용하지 않아 기존 위반 report를 숨기지 않는다.
- Kyverno와 정책 선언은 각각 전용 AppProject·child Application이 소유한다.
- 사용자 credential, image pull credential와 Git 선언 Secret은 만들지 않는다.
- admission webhook은 TLS 없이는 동작할 수 없어 Kyverno가 CA와 leaf Secret 두 개를 자체 생성·
  갱신한다. 이 두 Secret은 애플리케이션 credential가 아니며 cleanup controller를 끈 상태의
  제품 필수 최소값이다.

현재 k3s `v1.36.2+k3s1`은 Kyverno `v1.18`의 공식 시험 범위(`v1.33`–`v1.35`)보다 한 minor
높다. 이 미시험 조합은 숨기지 않고 POL-01의 Audit 검증과 POL-02의 예외 만료·signed release·
rollback 경계를 실제 클러스터에서 통과해야만 유지한다. 호환 실패 시 해당 commit SHA 적용을
중단하고 시작 main SHA로 rollback한다.

POL-02 라이브 검증에서 정확 범위 예외의 만료 전 허용·만료 뒤 거부, 기존 signed release의
`Running/Ready`, 시작 main rollback의 ClusterPolicy `Audit`·PolicyException 0건과 root/child
`Synced/Healthy`를 통과했다. Kyverno v1.18.2의 namespaced image-policy webhook 경로와 legacy
Cosign verifier는 Cosign v3 bundle 경계를 처리하지 못해, E2E namespace만 정확히 선택하는
`ImageValidatingPolicy`의 static-key verifier를 사용한다.

재생성 입력과 결과 hash는 [`release-metadata.env`](release-metadata.env)가 소유한다.

```bash
helm template kyverno https://kyverno.github.io/kyverno/kyverno-3.8.2.tgz \
  --namespace kyverno \
  --kube-version 1.36.2 \
  --skip-tests \
  --values gitops/apps/kyverno/values-pol-01.yaml \
  > gitops/apps/kyverno/install.yaml
sed -i 's/[[:space:]]\+$//' gitops/apps/kyverno/install.yaml
```

## NetworkPolicy 기준선

k3s 기본 Flannel CNI와 내장 kube-router NetworkPolicy controller가 라이브에서
`KUBE-NWPLCY`·`KUBE-POD-FW` 체인을 설치하므로 정책은 실제로 강제된다. 전체 namespace를
일괄 전환하지 않고 현재 통신표가 명확한 `pomerium` namespace 한 곳만 기준선으로 삼는다.

- 모든 Pod의 ingress·egress를 기본 거부한다.
- 모든 Pod에서 CoreDNS TCP/UDP 53을 허용한다.
- Traefik에서 Pomerium, Pomerium에서 Dashy ingress만 허용한다.
- Pomerium에서 Vault·Headlamp의 정확한 Pod port를 허용한다.
- OIDC/authenticate hostname의 외부 443과 Service DNAT 뒤 Traefik websecure 8443을 허용한다.

`gitops/tools/pol-01/egress-verify-pod.yaml`은 `pomerium`과 같은 selector를 사용해 CoreDNS,
Vault, Headlamp와 기존 SSO HTTPS egress를 한 번씩 확인하고 즉시 삭제하는 검증 자원이다.

주소값은 문서에 복제하지 않는다. Pomerium의 외부 HTTPS 목적지는 기존 hostname 경로를
보존하기 위해 TCP 443으로만 제한하고 IP를 새 단일 원본처럼 고정하지 않는다.

## POL-02 검증

`gitops/tools/pol-02/verify-live.sh exception`은 정확한 이름의 임시 `PolicyException`을 30초만
만들고 같은 위반 Pod 입력이 만료 전에는 허용되며 범위 밖 이름과 만료 뒤에는 거부되는지
admission 응답으로 한 번씩 판정한다. `verify-live.sh signed-release <signed-digest>`는 E2E-01
pipeline을 재실행하지 않고 이미 서명한 digest를 기존 trust와 registry credential로 실제
Pod까지 기동해 Enforce 회귀가 없음을 판정하고 즉시 정리한다.

## 동기화와 rollback

정상 상태의 root와 두 child Application은 `targetRevision: main`이다. merge 전 검증에서는
`AGENTS.md`의 `ARGO-ROOT` 잠금 아래 최신 `origin/main`으로 rebase한 설정 commit SHA를 child에,
그 pointer commit SHA를 `platform-root`에 사용한다. mutable branch 이름은 넣지 않는다.

POL-02 rollback은 `platform-root`의 automated sync를 잠시 멈추고 `policy-baseline` child를
기록한 시작 main SHA로 먼저 돌려 ClusterPolicy가 Audit이고 PolicyException이 0건인지 확인한다.
그 다음 `e2e-01` child를 시작 main SHA로 돌리고 파생 사본 `kyverno/e2e-01-registry`를 정확한
이름으로 삭제한 뒤 `kyverno` child를 시작 main SHA로 돌려 PolicyException feature flag를
원복한다. 마지막에 root의 targetRevision과 automated sync를 시작 main으로 복원해
`Synced/Healthy`를 확인한다.

Kyverno 전체 제거가 필요한 rollback은 기존 POL-01 순서를 유지한다. `policy-baseline` child를
먼저 foreground 삭제하고, `kyverno` child·동적 webhook·고정 CRD 22개·두 AppProject를 순서대로
정리한다. 기존 Pomerium 선언과 route는 그대로 남으며, 성공·실패와 무관하게 최종 선언의 child
revision과 라이브 root를 `main`으로 복귀한 뒤 잠금을 푼다.
