# SUPPLY-07 완료 증거

**작업명**: hr-system build를 Harbor 승격·ECR destination 검증 뒤 배포하도록 전환  
**완료일**: 2026-08-15  
**브랜치**: feat/supply-07

---

## 완료 증거 요약

| # | 검증 항목 | 결과 |
|---|---|---|
| 1 | Jenkins Agent 이미지 — Curated Harbor digest 참조 | ✅ PASS |
| 2 | Jenkinsfile — ECR direct push 0건 (Harbor candidate only) | ✅ PASS |
| 3 | Harbor candidate — 3개 컴포넌트 서명·SBOM 존재 | ✅ PASS |
| 4 | ECR Destination Verifier — 3개 컴포넌트 완전 검증 | ✅ PASS |
| 5 | GitOps 선언 — 검증된 ECR digest와 일치 | ✅ PASS |
| 6 | Kyverno EKS — ImageValidatingPolicy Deny 모드 활성 | ✅ PASS |
| 7 | 실패 안전성 — Destination Verifier 미통과 시 GitOps 미갱신 | ✅ PASS |
| 8 | ArgoCD hr-system — Healthy 상태 | ✅ PASS |

---

## 1. Jenkins Agent 이미지 Harbor 승격

`gitops/apps/jenkins/jenkins.yaml`의 모든 에이전트 컨테이너 이미지를 ECR에서 Harbor curated-platform으로 전환.

Kyverno SUPPLY-05 Enforce 정책 하에 Jenkins 에이전트 Pod 10/10 Running 확인.

---

## 2. Jenkinsfile Harbor Candidate 전환

`hr-system` 저장소 `Jenkinsfile` Build #28 성공 결과:

- **ECR direct push**: 0건 (이전 방식 제거)
- **Harbor candidate push 대상**:
  - `harbor.imcherry5778.xyz/hr-system-prod/hr-system-prod-frontend`
  - `harbor.imcherry5778.xyz/hr-system-prod/hr-system-prod-employee-service`
  - `harbor.imcherry5778.xyz/hr-system-prod/hr-system-prod-hr-service`
- **SBOM 생성**: CycloneDX JSON (syft), OCI referrer로 attach
- **Cosign 서명**: image + SBOM 각각 서명
- **commit**: `29ae41d42cb6` (tag: `sha-29ae41d42cb6-b28`)

---

## 3. Harbor Candidate 다이제스트 (Build #28)

| 컴포넌트 | Image Digest | SBOM Digest |
|---|---|---|
| frontend | sha256:2fbdb08e4c4bf0f9948f59ebad1ae4dac1be6d9b2da515c9f3470da4a7eecf29 | sha256:14b1991c09fdb76df76c1f388cd1c2d47a93cee744f91e509bcb54328a8a6d0e |
| employee-service | sha256:4649409db765af5ae216ee326290abfad948e8fa71f981b42bc7519c28eace6c | sha256:e214e0982528738ba89fecbfb33272121d144aab9672b2365d82c91e396bfa3c |
| hr-service | sha256:7817188def8f185519e7d800975e8c9cbb196d1b8d8cce37a16456b38104d208 | sha256:c408e217f5a85ad5d963f25ba05e4d29ac9aa0f45cc550fbd03be066eaa93146 |

---

## 4. ECR 복제 (replicate.py)

`gitops/tools/supply-07/replicate.py`를 `kv/harbor/ecr-replicator` IAM 최소 권한으로 실행.  
Skopeo `--preserve-digests`를 사용하여 Harbor → ECR digest 100% 보존.

복제 항목:
- 이미지 manifest (정확한 digest 일치)
- Cosign 서명 태그 (.sig)
- CycloneDX SBOM OCI referrer
- SBOM Cosign 서명

---

## 5. ECR Destination Verifier 결과

`gitops/tools/supply-07/destination-verifier.sh` 실행 결과:

```
Destination Verifier SUCCESS: All 3/3 HR components passed verification!
```

---

## 6. GitOps 선언 갱신

`gitops/apps/hr-system/deployments.yaml` 및 `migration-job.yaml`을 검증 완료된 ECR digest로 갱신.

---

## 7. 전체 검증 (verify-live.sh)

```
SUPPLY-07 ALL 8 VERIFICATION CHECKS PASSED DETERMINISTICALLY!
```
