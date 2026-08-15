# SUPPLY-05-FIX-03 증거

## 판정

`DONE` — Kyverno ImageValidatingPolicy admission timeout의 실제 계층을 특정하고, Enforce/Fail·Deny·exact 예외를 유지한 최소 보정을 immutable SHA에서 검증했다.

## 실패 지점과 보정

- 시작 main SHA: `b059eeb5921b275ab83abf890a7fd6afc88a34f2`
- curated Renovate Job 생성 시 `ivpol.mutate.kyverno.svc-fail-finegrained-k3s-image-supply-chain-policy` webhook의 `context deadline exceeded`를 재현했다.
- Kyverno Service/Endpoint와 admission controller Ready 상태를 확인했고, controller 로그의 30초 webhook 요청과 `write tcp ... i/o timeout`을 확인해 Service 미준비가 아닌 이미지 signature 검증 지연으로 특정했다.
- `verifyImageSignatures`는 current attestor를 먼저 확인하고 성공 시 previous를 조회하지 않는 CEL short-circuit OR로 보정했다.
- `matchConditions`의 비표준 `images.*` 참조를 `object.spec.?containers.orValue([])`·initContainers·ephemeralContainers의 exact image prefix 조건으로 교체했다. 시스템 예외의 namespace·ServiceAccount·label·repository 경계는 유지했다.
- Kyverno chart의 중복 `TUF_ROOT` 환경변수도 제거해 Argo structured-merge 비교 오류를 해소했다. Kyverno `resourceFilters`에는 `kube-system`·`kyverno` namespace 전체 제외를 추가하지 않았다.

## 정적 검증

- policies·kyverno·root `kubectl kustomize` 렌더링 PASS
- 두 ImageValidatingPolicy의 `matchConditions`에서 `images.` 없음 확인 PASS
- canary `bash -n`, `shellcheck`, `git diff --check` PASS

## immutable live 검증

임시 root SHA `95ad5ef4f2229b037f31726e0eb2b7c30c0321b1`에서 다음 child 선언을 적용했다.

- `kyverno`, `policy-baseline`: policy/config SHA `777bef4db3fac2e91e0231080965a6af6be725fb`
- `renovate`: `main`
- `platform-root`, `kyverno`, `policy-baseline`, `renovate`: `Synced/Healthy`
- ImageValidatingPolicy: `failurePolicy=Fail`, `validationActions=Deny`, attestor `current, previous`
- curated Renovate/Vault init canary: `supply05fix03-canary-1786795713` Job `Complete` 및 `succeeded=1`
- canary는 Renovate 프로세스를 즉시 종료하도록 바꾼 단일 Job이며 GitHub dependency 조회·실제 PR 생성은 실행하지 않았다.

검증 후 root를 시작 SHA로 되돌리고 `targetRevision: main`으로 복구했다. 최종 main 통합 뒤 동일 child의 `Synced/Healthy`를 확인한다.
