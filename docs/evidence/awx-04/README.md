# AWX-04 완료 증거

## EE 공급망

- Jenkins `awx04-ee-build` #12, source
  `8d3f99396cef7b349b88b2207f606bebeca4485f`
- collection `community.postgresql 3.5.0`, Ansible playbook syntax 33개 통과
- Harbor EE digest
  `sha256:8a50355c48b8ffde5e86cbc552400194aba2c93b5ad169bb78305abc804905fe`
- SBOM referrer digest
  `sha256:67d87269a29f9ee05345312e1b20cf8b5b9142d13317bdea66ead913bfedba6d`
- Trivy High/Critical 0, CycloneDX SBOM attach, Cosign image·SBOM sign/verify 통과

## 라이브 판정

- immutable 사전 검증: root `87c7ad74b3a2dc2b631520264e2bc0c52dddbc28`, AWX/Jenkins
  `20a7d1ef2a64c088dbdb114fef14ed2784a88bd5`에서 `AWX04_PLATFORM=PASS`.
  Gitea mirror와 AWX Project `scm_revision`은 `b57b099c41ca212250787a0adfa7439c4f21af1e`로 같고,
  Vault external SSH input source, strict host key, `projects_persistence=false`, PVC 0,
  operational job 0, Harbor EE digest를 함께 판정했다.
- 실제 OIDC browser session: `AWX04_RBAC=PASS` — 일상 operator의 project revision/template read는 200,
  project·EE·credential 수정과 branch override는 모두 403.
- 검증 뒤 root·AWX·Jenkins를 literal `main`으로 복원해 `Synced/Healthy`를 확인했다. 최종 main 통합 뒤에도
  같은 판정을 final main SHA에서 다시 확인한다.
