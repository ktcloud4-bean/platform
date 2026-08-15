# SUPPLY-01-FIX-02 검증 증거

## 1. 작업 요약
- **작업 ID**: `SUPPLY-01-FIX-02`
- **목표**: EKS Kyverno 공급망 어드미션 정책 복구 (`ctlog` 설정 및 어드미션 검증)
- **수행 내역**:
  1. `gitops/apps/kyverno-eks/policies/image-validating-policy.yaml` 정책 선언 정비:
     - `attestors[].cosign.ctlog`에 `url: https://rekor.sigstore.dev`, `insecureIgnoreTlog: true`, `insecureIgnoreSCT: true` 설정 추가 (`k3s-image-supply-chain-policy.yaml` 표준과 정렬).
     - 과거 하드코딩 digest allowlist 완전 제거.
     - `verifyImageSignatures` short-circuit OR 적용 (`verifyImageSignatures(img, [attestors.current]) > 0 || verifyImageSignatures(img, [attestors.previous]) > 0`).
  2. HR 서비스 이미지 서명 및 Attestation 독립 검증:
     - `hr-service`, `employee-service`, `frontend` 3개 워킹 이미지에 대해 `cosign verify` PASS 확인.
     - `hr-service` CycloneDX OCI referrer attestation manifest 서명 검증 PASS 확인.
  3. Server-side Admission 양성/음성 검증:
     - 정상 서명 이미지 Pod dry-run: `ALLOWED`
     - 미서명 fixture 이미지 Pod dry-run: `DENIED`
     - Tag-only 미고정 이미지 Pod dry-run: `DENIED`
  4. Kyverno 컨트롤러 로그 검증:
     - `rekor URL must be provided` 오류 0건 (`rekor_url_errors=0`).
  5. `hr-db-migrate` Job Pod 어드미션 통과 및 `Completed`(`Succeeded`) 확인.
  6. Argo CD `platform-root`, `kyverno-eks`, `hr-system` Application `Synced/Healthy` 수렴 확인.

---

## 2. 완료 증거 판정 표

| 검증 항목 | 기준 | 실측 결과 | 판정 |
|---|---|---|---|
| 서명 및 Attestation 독립 검증 | `cosign verify` 성공 | 3종 이미지 및 SBOM attestation manifest 서명 검증 PASS | `PASS` (`evidence_signatures=pass`) |
| Server-Side Admission 양성 | 정상 서명 이미지 Pod 생성 허용 | `verify-positive-hr` Pod server dry-run `ALLOWED` | `PASS` (`evidence_admission_positive=pass`) |
| Server-Side Admission 음성 (미서명) | 미서명 fixture 이미지 차단 | `verify-unsigned` Pod server dry-run `DENIED` | `PASS` (`evidence_admission_negative_unsigned=pass`) |
| Server-Side Admission 음성 (Tag-only) | Tag-only 미고정 이미지 차단 | `verify-tag-only` Pod server dry-run `DENIED` | `PASS` (`evidence_admission_negative_tagonly=pass`) |
| Kyverno 컨트롤러 로그 | `rekor URL must be provided` 0건 | `rekor_url_errors=0` | `PASS` (`evidence_rekor_log=pass`) |
| hr-db-migrate Job 실행 | Pod 어드미션 통과 및 Completed | `job.batch/hr-db-migrate Complete 1/1 (Completed)` | `PASS` (`db_migrate_status=Succeeded`) |
| Argo CD 동기화 수렴 | platform-root, kyverno-eks, hr-system `Synced`/`Healthy` | 3개 Application 모두 `Synced`/`Healthy` | `PASS` (`hr_system_argocd=Synced_Healthy`) |

---

## 3. 세부 검증 로그 요약

```text
=== [1/6] Git 선언 HR 서비스 이미지 서명 및 Attestation 독립 검증 ===
서명 검증 대상: 465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-hr-service@sha256:4f2002043e92e1462c4a52946d5ba7dea10e23d81cb5354689ad4afeea20e753
 -> Image signature PASS
서명 검증 대상: 465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-employee-service@sha256:d53ccf25f6ded935d40710bda1c0ec0bb510c50a912dc83e2158faa6e995c572
 -> Image signature PASS
서명 검증 대상: 465137780685.dkr.ecr.ap-northeast-2.amazonaws.com/hr-system-prod-frontend@sha256:a3cbdf849807d1ee04de9853690041d975509de7f38db0aacee347a2c31178db
 -> Image signature PASS
CycloneDX Attestation 서명 검증: hr-system-prod-hr-service@sha256:c408e217f5a85ad5d963f25ba05e4d29ac9aa0f45cc550fbd03be066eaa93146
 -> CycloneDX Attestation signature PASS
evidence_signatures=pass independent_verification=PASS

=== [2/6] EKS ImageValidatingPolicy Server-Side Admission 검증 ===
evidence_admission_positive=pass server_dry_run=ALLOWED
evidence_admission_negative_unsigned=pass rejected=TRUE
evidence_admission_negative_tagonly=pass rejected=TRUE

=== [3/6] Kyverno 컨트롤러 로그 Rekor URL 오류 검증 ===
evidence_rekor_log=pass rekor_url_errors=0

=== [4/6] hr-db-migrate Job 상태 및 Pod 실행 확인 ===
NAME                      STATUS     COMPLETIONS   DURATION   AGE
job.batch/hr-db-migrate   Complete   1/1           5s         10s

=== [5/6] Argo CD Application 동기화 상태 대기 ===
Wait [1/60]: platform-root=Synced/Healthy, kyverno-eks=Synced/Healthy, hr-system=Synced/Healthy
모든 대상 Application이 Synced/Healthy 상태에 도달했다.

=== [6/6] 최종 증거 집계 ===
NAME                                READY   STATUS    RESTARTS   AGE
employee-service-569b5ccc6d-dc99r   1/1     Running   0          4d22h
frontend-d9d4457d8-4pgv9            1/1     Running   0          4d22h
hr-service-f579b5dc9-5gsjg          1/1     Running   0          4d15h
evidence_final=pass SUPPLY_01_FIX_02_COMPLETED=TRUE
```
