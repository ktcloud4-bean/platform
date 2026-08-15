# SUPPLY-08 완료 증거

**작업명**: Jenkins ECR publisher IAM 사용자 제거 (`infra/aws/tofu-app-ci/`)  
**완료일**: 2026-08-15  
**브랜치**: feat/supply-08

---

## 완료 증거 요약

| # | 검증 항목 | 결과 |
|---|---|---|
| 1 | Jenkinsfile ECR direct push 0건 및 AWS 자격증명 미사용 | ✅ PASS |
| 2 | OpenTofu `infra/aws/tofu-app-ci/` clean plan (0 add, 0 change, 0 destroy) | ✅ PASS |
| 3 | AWS IAM: `hr-system-prod-jenkins-ecr-publisher` user 및 key 완전 삭제 | ✅ PASS |
| 4 | AWS 계정 Standing Access Key 정확히 4건 수렴 | ✅ PASS |
| 5 | Destination Verifier & Harbor ECR replication 3개 컴포넌트 100% PASS | ✅ PASS |

---

## 1. Jenkins ECR Publisher 제거 내역

- **OpenTofu (`infra/aws/tofu-app-ci/`)**:
  - `jenkins_ecr_publisher.tf` 완전 삭제 (data source `hr_images`는 `data.tf`로 이관)
  - `outputs.tf`에서 `jenkins_ecr_publisher_*` output 제거
  - `tofu apply`로 IAM User `hr-system-prod-jenkins-ecr-publisher` 및 inline policy `hr-system-prod-ecr-publish-only` 삭제 완료
  - 사후 `tofu plan` 실행 결과: `0 to add, 0 to change, 0 to destroy` (무변경)

- **Jenkins GitOps 선언 정리**:
  - `gitops/apps/jenkins/vault-agent-config.yaml`: `hr_system_aws_access_key_id`, `hr_system_aws_secret_access_key` 템플릿 제거
  - `gitops/apps/jenkins/jenkins.yaml`: `aws-hr-ecr-publisher` credential 선언 제거

---

## 2. Standing Access Key 수렴 현황 (정확히 4건)

AWS IAM 계정의 모든 사용자를 전수 검사하여 standing service access key가 지정된 4건으로 수렴함을 확인:

| 역할 (Key Name) | IAM User Name | Access Key ID | 상태 |
|---|---|---|---|
| `backup` | `seaweedfs-offsite-backup` | `AKIAWYTC7I7GTCB4WEXE` | Active (1건) |
| `vault_auto_unseal` | `vault-auto-unseal` | `AKIAWYTC7I7G2BLL6W2V` | Active (1건) |
| `argocd_credential_issuer` | `hr-system-prod-argocd-eks-credential-issuer` | `AKIAWYTC7I7G6YF3F6UC` | Active (1건) |
| `harbor_ecr_replicator` | `hr-system-prod-harbor-ecr-replicator` | `AKIAWYTC7I7GZEEBPYTC` | Active (1건) |

총 Service Standing Key 수: **정확히 4건** (Jenkins publisher key 완전 제거).

---

## 3. Destination Verifier & Harbor ECR 복제 검증

`gitops/tools/supply-07/destination-verifier.sh` 재검증 통과:
- `frontend`: ECR digest, Cosign 서명, CycloneDX SBOM OCI referrer, SBOM 서명 모두 유효
- `employee-service`: ECR digest, Cosign 서명, CycloneDX SBOM OCI referrer, SBOM 서명 모두 유효
- `hr-service`: ECR digest, Cosign 서명, CycloneDX SBOM OCI referrer, SBOM 서명 모두 유효

---

## 4. 전체 검증 실행 로그

```
============================================================
 SUPPLY-08 Live Verification
============================================================

[Step 1] Verifying Jenkinsfile performs 0 direct ECR pushes or AWS credential uses...
  [PASS] Jenkinsfile contains 0 legacy ECR push commands / AWS credential bindings

[Step 2] Verifying OpenTofu infra/aws/tofu-app-ci clean plan (0 add, 0 change, 0 destroy)...
  [PASS] OpenTofu infra/aws/tofu-app-ci matches clean state (0 changes)

[Step 3] Verifying hr-system-prod-jenkins-ecr-publisher IAM user and keys are completely removed...
  [PASS] hr-system-prod-jenkins-ecr-publisher is deleted from AWS IAM

[Step 4] Verifying standing access keys converge to exactly 4 designated service accounts...
  [PASS] Standing Key [harbor_ecr_replicator]: User=hr-system-prod-harbor-ecr-replicator KeyId=AKIAWYTC7I7GZEEBPYTC (Count=1)
  [PASS] Standing Key [vault_auto_unseal]: User=vault-auto-unseal KeyId=AKIAWYTC7I7G2BLL6W2V (Count=1)
  [PASS] Standing Key [backup]: User=seaweedfs-offsite-backup KeyId=AKIAWYTC7I7GTCB4WEXE (Count=1)
  [PASS] Standing Key [argocd_credential_issuer]: User=hr-system-prod-argocd-eks-credential-issuer KeyId=AKIAWYTC7I7G6YF3F6UC (Count=1)
  [PASS] Exactly 4 standing service access keys verified

[Step 5] Running Destination Verifier to ensure Harbor replication & ECR integrity...
============================================================
 Destination Verifier SUCCESS: All 3/3 HR components passed verification!
 Candidate release is verified and ready for GitOps deployment.
============================================================

============================================================
 SUPPLY-08 ALL VERIFICATION CHECKS PASSED DETERMINISTICALLY!
============================================================
```
