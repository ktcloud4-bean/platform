# EKS Kyverno 이미지 공급망 정책 기준선

이 디렉터리는 `SUPPLY-01`의 AWS EKS(`hr-system-prod-cluster`) 전용 Kyverno admission·reports controller 및 `ImageValidatingPolicy`를 소유한다. 공식 Helm chart `3.8.2`/Kyverno `v1.18.2`와 [`values-supply-01.yaml`](values-supply-01.yaml)로 생성한 원시 manifest, 공식 release CRD를 저장소에 고정했다.

## 적용 경계

1. **IRSA 기반 무자격증명 ECR 연동**:
   - `kyverno-admission-controller` ServiceAccount는 전용 IRSA IAM Role(`arn:aws:iam::465137780685:role/hr-system-prod-kyverno-admission-role`, `AmazonEC2ContainerRegistryReadOnly`)을 사용한다.
   - static registry Secret을 클러스터에 두지 않고 Amazon credential helper를 통해 ECR 인증 및 signature/attestation OCI referrer 조회를 수행한다.

2. **ImageValidatingPolicy 공급망 거버넌스**:
   - 신규 정책은 Kyverno 1.18 stable `ImageValidatingPolicy`(`policies.kyverno.io/v1beta1`)로 작성하며 `failurePolicy: Fail`, `validationActions: [Deny]`로 Enforce한다.
   - **허용 레지스트리**: Customer ECR(`465137780685.dkr.ecr.ap-northeast-2.amazonaws.com`) 외의 외부 레지스트리(예: docker.io, quay.io 등) 이미지는 즉시 거부한다.
   - **Digest 고정**: 모든 이미지는 `@sha256:...` digest로 고정되어야 하며, tag-only 선언은 거부한다.
   - **서명 및 Attestation 검증**: Customer ECR의 자체 빌드 애플리케이션 이미지(`hr-system-prod-employee-service`, `hr-system-prod-hr-service`, `hr-system-prod-frontend`)는 플랫폼 Cosign image signature 및 서명된 CycloneDX SBOM attestation(`application/vnd.cyclonedx+json`)이 확인되어야만 admission을 통과한다.
   - **최소 권한 예외**: `kube-system` 네임스페이스 전체 제외를 금지하며, AWS 관리형 add-on(VPC CNI, CoreDNS, kube-proxy)의 exact controller/ServiceAccount와 리전별 공식 ECR(`602401143452.dkr.ecr.ap-northeast-2.amazonaws.com/*`) 조합만 예외로 인정한다.
   - **자체 ECR Bootstrap 이미지**: 자체 ECR 미러에서 배포하는 AWS Load Balancer Controller(`hr-system-prod-bootstrap-aws-load-balancer-controller`) 및 bootstrap 이미지는 일반 customer ECR 정책(허용 ECR + digest 고정)을 통과한다.

## 렌더링 절차

```bash
helm template kyverno https://kyverno.github.io/kyverno/kyverno-3.8.2.tgz \
  --namespace kyverno \
  --kube-version 1.36.2 \
  --skip-tests \
  --values gitops/apps/kyverno-eks/values-supply-01.yaml \
  > gitops/apps/kyverno-eks/install.yaml
sed -i 's/[[:space:]]\+$//' gitops/apps/kyverno-eks/install.yaml
```

## 동기화와 rollback

- 정상 상태의 root와 child Application은 `targetRevision: main`이다.
- `ARGO-ROOT` 잠금 아래 merge 전 라이브 검증에서는 최신 `origin/main`으로 rebase한 커밋 SHA를 사용한다.
- 실패 시 시작 main SHA로 되돌려 child를 복원하며, Kyverno 전체 제거 시에는 정책과 admission webhook, CRD를 순차 정리한다.
