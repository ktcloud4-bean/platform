# SUPPLY-04-FIX-01: Keycloak Bootstrap Job v3 안전 전환 라이브 검증 보고서

## 1. 개요

- **백로그 ID**: `SUPPLY-04-FIX-01`
- **목표**: 완료된 Keycloak bootstrap Job의 immutable Pod template 특성을 고려하여, 기존 완료 Job(`keycloak-bootstrap-v2`)을 수동 삭제/강제 교체하지 않고, check-first/no-op 경로를 수행하는 새 versioned Job(`keycloak-bootstrap-v3`)으로 안전하게 승격하여 GitOps 및 공급망 정책 준수를 완성.
- **수행 일시**: 2026-08-15
- **책임자**: Antigravity Live Supply Chain Operator

---

## 2. 작업 내역 및 설계 원칙

1. **기존 완료 Job 보존**:
   - `keycloak-bootstrap-v2` Job을 강제 삭제하거나 재실행하지 않고 그대로 보존하여 클러스터 안정성 확보.

2. **Check-First / No-Op 안전 경로 ([`gitops/apps/keycloak/bootstrap-job.yaml`](../../gitops/apps/keycloak/bootstrap-job.yaml))**:
   - 새 Job 이름: `keycloak-bootstrap-v3`
   - `initContainers[0]` (vault-agent): `harbor.imcherry5778.xyz/curated-platform/vault@sha256:18ceda087817a9e0dbed22fb632225fdc079f1b909bc0ff94d00ade4c4990e9f`
   - `containers[0]` (bootstrap): `harbor.imcherry5778.xyz/curated-platform/keycloak@sha256:26939e1318d6f008fc2ee6e10cec1cf8f1ba8a21846c1bc81b91ed0506bc2a7a`
   - 이미 존재하는 `platform` 및 `master` realm, MFA 설정, 복구 계정(`imcherry-kc-recovery`), 복구 클라이언트(`kc-recovery`)에 대해 덮어쓰기 없는 무변경(no-op) 검증 수행 후 성공 완료.

3. **Keycloak 상태 보존**:
   - 기존 사용자, group membership, 운영 OIDC client에 대한 변경 0건 보장.
   - OIDC Discovery 엔드포인트(`https://sso.imcherry5778.xyz/realms/platform/.well-known/openid-configuration`) 정상 응답 확인.

---

## 3. 7대 완료 증거 라이브 실측 결과 ([`gitops/tools/supply-04-fix-01/verify-live.sh`](../../gitops/tools/supply-04-fix-01/verify-live.sh))

| 번호 | 검증 시나리오 및 판정 기준 | 라이브 실측 결과 | 판정 |
|---|---|---|---|
| **1** | **기존 완료 Job 보존** | `keycloak-bootstrap-v2` Job의 수동 삭제 없이 라이브 보존 확인 | **PASS** |
| **2** | **새 Versioned Job v3 완료** | `keycloak-bootstrap-v3` 배포 및 `Complete (1/1)` 도달 확인 | **PASS** |
| **3** | **Curated Digest 이미지 검증** | Job v3의 vault-agent 및 keycloak 컨테이너 이미지가 Harbor `curated-platform` `@sha256` 고정임을 확인 | **PASS** |
| **4** | **Keycloak 서버 런타임 가동** | Keycloak server Pod `Running (1/1)` 정상 가동 | **PASS** |
| **5** | **SSO OpenID Issuer 검증** | `https://sso.imcherry5778.xyz/realms/platform/.well-known/openid-configuration` 정상 응답 (`issuer` 일치) | **PASS** |
| **6** | **Kyverno Enforce 정책 통과** | `k3s-image-supply-chain-rules` Enforce 정책 통과 확인 | **PASS** |
| **7** | **클러스터 전 워크로드 가동** | `kubectl get pods -A` 전 네임스페이스 100% `Running` / `Completed` 유지 | **PASS** |

---

## 4. 결론

- `SUPPLY-04-FIX-01`의 안전한 versioned bootstrap Job 전환이 성공적으로 라이브 적용되었습니다.
- Keycloak 런타임 및 OIDC 인증 기능이 무중단 상태를 유지하면서 선언 및 라이브 Job 이미지의 공급망 표준이 100% 충족되었습니다.
