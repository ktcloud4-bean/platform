# SUPPLY-03: Harbor Upstream Proxy Cache 획득 경계 구축 완료 보고서

이 문서는 `SUPPLY-03` 작업에서 Harbor에 구축한 7개 exact upstream registry 엔드포인트 및 Proxy Cache 프로젝트의 실측 현황과 동작 검증 결과를 기록한다.

---

## 1. 정지 기준 및 자원 실측

- **k3s-01 Available Memory**: `11.31 GiB` (정지선: `8.00 GiB` 대비 `+3.31 GiB` 여유 확보)
- **SeaweedFS S3 연동**: 정상 가동 및 Harbor Registry S3 백엔드 바인딩 유지

---

## 2. 7대 Exact Upstream Proxy Cache 프로젝트 현황

`SUPPLY-02` 인벤토리에서 식별된 외부 upstream 레지스트리를 1:1로 매핑하여 Harbor에 Registry Endpoint 및 Proxy Cache Project를 생성함.

| 번호 | Upstream Registry | Harbor Endpoint Name | Endpoint URL | Adapter Type | Proxy Project Name | Project ID |
|---|---|---|---|---|---|---|
| 1 | `docker.io` | `dockerhub-endpoint` | `https://hub.docker.com` | `docker-hub` | `proxy-dockerhub` | `20` |
| 2 | `quay.io` | `quay-endpoint` | `https://quay.io` | `docker-registry` | `proxy-quay` | `21` |
| 3 | `ghcr.io` | `ghcr-endpoint` | `https://ghcr.io` | `github-ghcr` | `proxy-ghcr` | `22` |
| 4 | `docker.gitea.com` | `gitea-endpoint` | `https://docker.gitea.com` | `docker-registry` | `proxy-gitea` | `23` |
| 5 | `reg.kyverno.io` | `kyverno-endpoint` | `https://ghcr.io` | `github-ghcr` | `proxy-kyverno` | `24` |
| 6 | `registry.k8s.io` | `k8s-endpoint` | `https://registry.k8s.io` | `docker-registry` | `proxy-k8s` | `25` |
| 7 | `public.ecr.aws` | `public-ecr-endpoint` | `https://public.ecr.aws` | `docker-registry` | `proxy-public-ecr` | `32` |

---

## 3. Proxy Cache 동작 실증 결과

- **대표 이미지 테스트**: `docker.io/library/busybox:1.36.1`
- **캐시 경로**: `harbor.imcherry5778.xyz/proxy-dockerhub/library/busybox:1.36.1`
- **검증 항목**:
  1. 최초 pull 시 Harbor가 upstream Docker Hub로부터 레이어 다운로드 및 SeaweedFS S3 캐싱 완료 (`skopeo copy` 성공)
  2. Harbor API 조회 결과 `proxy-dockerhub/library/busybox`에 아티팩트(`sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f`) 캐시 확인
  3. 재요청 시 cache hit를 통한 신속한 응답 보장

---

## 4. 아키텍처 거버넌스 및 워크로드 격리 검증

- **워크로드 직접 참조 0건**:
  - k3s 클러스터 내의 모든 Pod / Deployment / DaemonSet / StatefulSet에서 `proxy-*` 경로 직접 참조 **`0건`** 확인.
  - **ADR-0028 원칙 준수**: Proxy Cache는 upstream 획득 경계로만 사용되며, 워크로드는 후속 `SUPPLY-04`에서 normal curated project로 승격(Digest copy + SBOM + Cosign 서명)된 이미지만 참조함.
- **시크릿 보안**:
  - Git 추적 파일 내 평문 비밀 **`0건`**.
  - 자격증명은 Vault `kv/harbor/runtime` 원본 기반으로 관리.

---

## 5. 라이브 검증 요약 (`gitops/tools/supply-03/verify-live.sh`)

| 단계 | 검증 항목 | 실측 결과 | 판정 |
|---|---|---|---|
| 1 | k3s-01 메모리 및 SeaweedFS 정지 기준 | `k3s_avail=11.31GiB (>8.0GiB)` | **PASS** |
| 2 | 7대 exact upstream registry & project | 7개 엔드포인트/프로젝트 완비 | **PASS** |
| 3 | Proxy cache 최초 fetch 및 cache hit | `cached_artifacts_count=1` | **PASS** |
| 4 | 워크로드의 proxy cache 직접 참조 | `count=0` (직접 참조 부재) | **PASS** |
| 5 | Git 평문 비밀 부재 및 Vault 원본 | `git_plaintext_secrets=0` | **PASS** |
