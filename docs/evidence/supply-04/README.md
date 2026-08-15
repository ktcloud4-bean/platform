# SUPPLY-04: Upstream Artifact Curated Project 승격 및 OCI 서명/SBOM Attestation 검증 보고서

## 1. 개요

- **백로그 ID**: `SUPPLY-04`
- **목표**: Upstream 일반 워크로드 아티팩트를 normal Harbor curated project(`curated-platform`)로 승격(Digest OCI Copy + Cosign 서명 + CycloneDX SBOM Attestation 생성)하고, k3s 라이브 클러스터 및 GitOps 선언의 이미지 경로를 `@sha256:` 고정 다이제스트로 전면 전환.
- **수행 일시**: 2026-08-15
- **책임자**: Antigravity Live Supply Chain Operator

---

## 2. Harbor Curated Project 및 승격 파이프라인

1. **Harbor Curated 프로젝트**:
   - 프로젝트명: `curated-platform` (Public OCI Registry)
   - 엔드포인트: `https://harbor.imcherry5778.xyz/curated-platform/`
   - 스토리지 백엔드: SeaweedFS S3 (`s3.imcherry5778.xyz:8333/harbor-registry`)

2. **Cosign 서명 & CycloneDX SBOM Attestation**:
   - 서명 키: Vault `kv/jenkins/runtime` 내 `cosign_private_key`, `cosign_password`, `cosign_public_key`
   - OCI 1.1 Referrers spec 기반 서명 레이어(`application/vnd.dev.cosign.simplesigning.v1+json`) 및 CycloneDX v1.5 SBOM Attestation(`application/vnd.cyclonedx+json`) 부착.
   - 서명 및 Attestation 검증: `cosign verify`, `cosign verify-attestation --type cyclonedx` 100% PASS.

3. **승격 완료 이미지 인벤토리 (49개 워크로드)**:
   - 산출물: [`docs/evidence/supply-04/promoted-images.json`](promoted-images.json)
   - 대표 이미지:
     - `gitea`: `harbor.imcherry5778.xyz/curated-platform/gitea@sha256:89dc3c214b3992e5bb01e05ad21139d7a8b302d3ea3d8942d3f7e904e92af148`
     - `sonarqube`: `harbor.imcherry5778.xyz/curated-platform/sonarqube@sha256:d4899d380ad9d7b63ebaa751e047f5a4f064f8902cdf7c1a3c3c96f7d71600ed`
     - `keycloak`: `harbor.imcherry5778.xyz/curated-platform/keycloak@sha256:26939e1318d6f008fc2ee6e10cec1cf8f1ba8a21846c1bc81b91ed0506bc2a7a`
     - `argocd`: `harbor.imcherry5778.xyz/curated-platform/argocd@sha256:75cfed86123c23ba0707504f5e30cfda09d22359c5b77ff5d13a0832397d8c26`
     - `dex`: `harbor.imcherry5778.xyz/curated-platform/dex@sha256:8a9281c3a115180415b0726ca160e38fc40f9284bc9a2d1032c839a3a934695c`
     - `redis` (ArgoCD): `harbor.imcherry5778.xyz/curated-platform/redis@sha256:e499175dfb27569cd40010c2eee346113db95fdd0efc88ab9fd70a9e807f4542`
     - `vault`: `harbor.imcherry5778.xyz/curated-platform/vault@sha256:18ceda087817a9e0dbed22fb632225fdc079f1b909bc0ff94d00ade4c4990e9f`
     - `loki`: `harbor.imcherry5778.xyz/curated-platform/loki@sha256:69fb2ab2ff32db54123cc0587858687e306a877c6aefcf22efb9f72c69e72c81`
     - `grafana`: `harbor.imcherry5778.xyz/curated-platform/grafana@sha256:f33c692ba1a5ee15724cf6b22db65e9de39dde14d80f7d73a9546e3fc917270b`
     - `jenkins`: `harbor.imcherry5778.xyz/curated-platform/jenkins@sha256:8279be0a0ed95ad3b67c8677b9e03ff322f61338d39244234a907e9039ac3683`
     - `trivy`: `harbor.imcherry5778.xyz/curated-platform/trivy@sha256:c6e969c5662a546ad5de4a73c2a6b7a7c627f86d916903e175aa623af5b97ada`
     - `crowdsec`: `harbor.imcherry5778.xyz/curated-platform/crowdsec@sha256:95a25d0f0fb92d96204e74fd48a5c4bd2c949b1b2a31769fa3487ad4769314e1`
     - `awx`: `harbor.imcherry5778.xyz/curated-platform/awx@sha256:07f20882f1f163c0071945e03544a165c2a4e275164c1bf5f0111cd0821fa736`
     - `opensearch`: `harbor.imcherry5778.xyz/curated-platform/opensearch@sha256:23297b8d8545e129dd58c254ed08d786dc552410ba772983ad2af31048d2f04b`
     - `pomerium`: `harbor.imcherry5778.xyz/curated-platform/pomerium@sha256:9f0ba711a72d9b15d4d8d037e47c88a5b5e2294be53d862c8cfde30f251bc139`
     - `velero`: `harbor.imcherry5778.xyz/curated-platform/velero@sha256:a77d493b80f622e0bed1b9a19fea40a48d427de24e82be3f64824528b1ab7ecb`

---

## 3. 5대 완료 증거 검증 결과

| 검증 항목 | 검증 명령 / 판정 기준 | 실측 결과 | 판정 |
|---|---|---|---|
| **1. Harbor Curated 프로젝트** | `curl https://harbor.imcherry5778.xyz/api/v2.0/projects?name=curated-platform` | HTTP 200, public: true, 49개 아티팩트 등록 | **PASS** |
| **2. Cosign 서명 & Attestation** | `cosign verify`, `cosign verify-attestation --type cyclonedx` | 대표 3종 및 49개 전체 아티팩트 OCI 서명 & SBOM 검증 100% PASS | **PASS** |
| **3. Upstream 격리 실측** | `inventory.py` live 실측 | 일반 워크로드의 upstream 레지스트리 직접 참조 `0건` (Harbor curated 전면 전환 완료) | **PASS** |
| **4. Tag-only 워크로드 제거** | `inventory.py` digest 실측 | 일반 워크로드의 tag-only 참조 `0건` (ArgoCD, Dex, Redis 포함 100% `@sha256:` 고정) | **PASS** |
| **5. 라이브 워크로드 정상성** | `kubectl get pods -A` | 전체 네임스페이스 100% `Running` / `Completed` (Ready) | **PASS** |

---

## 4. GitOps 선언 동기화

- `gitops/apps/` 내 50개 파일 및 `gitops/bootstrap/argocd/` 내 매니페스트들의 이미지 참조를 `harbor.imcherry5778.xyz/curated-platform/<repo>@sha256:...`로 전환 완료.
- Git 저장소 내 평문 Private Key 또는 Secret 노출 `0건` 검증 완료.
