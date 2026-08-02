# Kyverno Audit 기준선

이 디렉터리는 `POL-01`의 Kyverno admission·reports controller를 소유한다. 공식 Helm chart
`3.8.2`/Kyverno `v1.18.2`와 [`values-pol-01.yaml`](values-pol-01.yaml)로 생성한 원시 manifest,
공식 release CRD를 저장소에 고정했다. 실제로 렌더되는 세 image는 tag와 OCI index digest를
함께 고정한다. generate·mutate-existing용 background controller와 CleanupPolicy용 cleanup
controller는 배포하지 않는다. CRD는 controller가 참조하는 API schema일 뿐 POL-01 정책
카탈로그가 아니며, 실제 정책 선언은 Audit 규칙 한 건뿐이다.

## 적용 경계

- 모든 validate 정책은 `validationFailureAction: Audit`만 사용한다. `Enforce`는 `POL-02` 전이다.
- 정책 카탈로그를 넓히지 않고 기존 Pod의 pod-level `runAsNonRoot` 누락 한 규칙만 report한다.
- Kyverno와 정책 선언은 각각 전용 AppProject·child Application이 소유한다.
- 사용자 credential, image pull credential와 Git 선언 Secret은 만들지 않는다.
- admission webhook은 TLS 없이는 동작할 수 없어 Kyverno가 CA와 leaf Secret 두 개를 자체 생성·
  갱신한다. 이 두 Secret은 애플리케이션 credential가 아니며 cleanup controller를 끈 상태의
  제품 필수 최소값이다.

현재 k3s `v1.36.2+k3s1`은 Kyverno `v1.18`의 공식 시험 범위(`v1.33`–`v1.35`)보다 한 minor
높다. 이 미시험 조합은 숨기지 않고 POL-01의 Audit report와 DNS·ingress·필수 egress 회귀를
실제 클러스터에서 통과해야만 유지한다. 호환 실패 시 해당 commit SHA 적용을 중단하고 시작
main SHA로 rollback한다.

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

## 동기화와 rollback

정상 상태의 root와 두 child Application은 `targetRevision: main`이다. merge 전 검증에서는
`AGENTS.md`의 `ARGO-ROOT` 잠금 아래 최신 `origin/main`으로 rebase한 설정 commit SHA를 child에,
그 pointer commit SHA를 `platform-root`에 사용한다. mutable branch 이름은 넣지 않는다.

검증 rollback은 `platform-root`의 automated sync를 잠시 멈춘 뒤 `policy-baseline` child를 먼저
foreground 삭제해 ClusterPolicy와 NetworkPolicy가 사라질 때까지 기다린다. 그 다음 `kyverno`
child를 삭제하고 admission controller가 동적으로 만든 `kyverno-*` webhook configuration을
정리한다. Argo가 raw manifest의 CRD를 child와 함께 prune하지 않는 라이브 동작을 확인했으므로,
정책 CR이 먼저 사라진 상태에서 이 디렉터리에 고정한 CRD 22개도 정확한 목록으로 제거한다. child
finalizer보다 AppProject가 먼저 삭제되는 순서 역전을 막기 위해 두 AppProject는 자동 prune하지
않으며, child 삭제 뒤 정확히 `kyverno`·`policy-baseline` AppProject를 수동 삭제한다. 마지막으로
기록한 시작 main SHA와 automated sync를 root에 복원해 `Synced/Healthy`를 확인한다. 기존 Pomerium
선언과 route는 그대로 남으며, 성공·실패와 무관하게 최종 선언의 child revision과 라이브 root를
`main`으로 복귀한 뒤 잠금을 푼다.
