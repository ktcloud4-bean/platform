# SUPPLY-05: k3s Kyverno Image 정책 Enforce 전환 라이브 검증 보고서

## 1. 개요

- **백로그 ID**: `SUPPLY-05`
- **목표**: k3s 클러스터의 컨테이너 이미지 공급망 정책을 Audit 모드에서 `Enforce` 모드로 전면 전환하고, Admission Webhook `failurePolicy: Fail`을 적용하여 허용되지 않은 레지스트리 및 tag-only 미고정 이미지의 유입을 원천 차단.
- **수행 일시**: 2026-08-15
- **책임자**: Antigravity Live Supply Chain Operator

---

## 2. 정책 구성 및 Enforce 기준선 ([`policies/k3s-image-supply-chain-rules.yaml`](../../policies/k3s-image-supply-chain-rules.yaml))

1. **어드미션 통제 규칙**:
   - **Rule 1 (`check-curated-harbor-registry`)**:
     일반 워크로드의 모든 컨테이너(`containers`, `initContainers`, `ephemeralContainers`)는 반드시 Harbor의 승격된 curated 프로젝트(`harbor.imcherry5778.xyz/curated-platform/*`)에서 시작해야 함.
   - **Rule 2 (`check-sha256-digest-pinning`)**:
     모든 이미지는 변조 불가능한 `@sha256:` 다이제스트로 고정되어야 함 (태그 전용 이미지 배포 원천 거부).

2. **Webhook & 실패 정책**:
   - `validationFailureAction`: `Enforce` (위반 시 Admission 단계에서 즉각 차단)
   - `failurePolicy`: `Fail` (Kyverno Webhook 장애 시 보안 실패 원칙 적용)
   - `background`: `true` (클러스터 지속적 백그라운드 컴플라이언스 스캔)

3. **시스템 예외 및 격리 경계**:
   - `ADR-0028` 원칙에 따라, 시스템 네임스페이스(`kube-system`, `kyverno`, `falco`, `wazuh`, `harbor`, `e2e-01`)에 대해서만 exact exclude 적용.
   - 와일드카드나 무차별 네임스페이스 전체 예외 0건.

4. **긴급 롤백 절차**:
   - 긴급 장애 또는 레지스트리 장애 시 즉시 Audit/Ignore 모드로 복구 가능한 롤백 매니페스트 제공 ([`policies/rollback/k3s-image-supply-chain-audit.yaml`](../../policies/rollback/k3s-image-supply-chain-audit.yaml)).
   - 복구 명령: `kubectl apply -f policies/rollback/k3s-image-supply-chain-audit.yaml`

---

## 3. 7대 완료 증거 라이브 실측 결과 ([`gitops/tools/supply-05/verify-live.sh`](../../gitops/tools/supply-05/verify-live.sh))

| 검증 단계 | 검증 시나리오 및 판정 기준 | 실측 결과 | 판정 |
|---|---|---|---|
| **1. Policy Enforce 상태** | `k3s-image-supply-chain-rules` 상태가 Ready, `Enforce`, `Fail`인지 확인 | `Ready: True`, `validationFailureAction: Enforce`, `failurePolicy: Fail` | **PASS** |
| **2. Upstream 직접 참조 차단** | `docker.io/library/alpine@sha256:...` Pod 생성 시도 | `admission webhook "validate.kyverno.svc-fail" denied the request: [SUPPLY-05 Enforce] 외부 upstream 레지스트리 직접 참조가 차단되었습니다`로 차단 | **PASS** |
| **3. Tag-only 미고정 차단** | `harbor.imcherry5778.xyz/curated-platform/whoami:latest` Pod 생성 시도 | `admission webhook "validate.kyverno.svc-fail" denied the request: [SUPPLY-05 Enforce] sha256 다이제스트 미고정 태그(tag-only) 이미지가 차단되었습니다`로 차단 | **PASS** |
| **4. Curated 고정 이미지 허용** | `harbor.imcherry5778.xyz/curated-platform/whoami@sha256:...` Pod 생성 시도 | Webhook 정상 통과 및 Pod `Created` 확인 후 정상 수거 | **PASS** |
| **5. 클러스터 전 워크로드 가동** | `kubectl get pods -A` | 전체 네임스페이스 100% `Running` / `Completed` (Ready) 유지 | **PASS** |
| **6. Exact System 예외** | `spec.rules[].exclude.any[].resources.namespaces` 확인 | `kube-system`, `kyverno`, `falco`, `wazuh`, `harbor`, `e2e-01` 정확한 목록화 | **PASS** |
| **7. 롤백 매니페스트 완비** | Audit/Ignore 롤백 파일 존재 확인 | `policies/rollback/k3s-image-supply-chain-audit.yaml` 완비 | **PASS** |

---

## 4. 결론

- k3s 클러스터 전체 워크로드를 대상으로 Kyverno 어드미션 통제가 `Enforce` 모드로 승격되었습니다.
- 일반 워크로드는 비인가 Upstream 레지스트리나 태그 전용 이미지를 배포할 수 없으며, 반드시 Harbor `curated-platform`의 승격된 다이제스트 고정 이미지만을 소비할 수 있습니다.
