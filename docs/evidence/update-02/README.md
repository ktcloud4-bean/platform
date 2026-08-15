# UPDATE-02 증거: Renovate 권위 저장소 채택

## 판정

`DONE` — Renovate를 실제 권위 저장소 `ktcloud4-bean/hr-system`에 단일 타깃으로 연결하고, fine-grained PAT 및 `npm`/`pip_requirements` allowlist, PR-only 비활성화 automerge, 단발 canary PR 생성 및 자동 cleanup, 용량 점검을 live 검증했다.

## 변경 요약

1. **저장소 타깃 및 매니저 제한 (`gitops/apps/renovate/config.yaml`)**:
   - 플랫폼: `github`
   - 대상 저장소: `ktcloud4-bean/hr-system` (단일 권위 저장소, autodiscover/onboarding 비활성)
   - 허용 패키지 매니저: `npm`, `pip_requirements`
   - PR-only 정책: `automerge: false`, `platformAutomerge: false`, `allowScripts: false`
   - 동시성 상한: `branchConcurrentLimit: 1`, `prConcurrentLimit: 1`, `prHourlyLimit: 0`
   - fine-grained PAT 호환: `issues` 스코프 격리 쿼리 패치 적용
2. **자격증명 주입 (`gitops/apps/renovate/vault-agent-config.yaml`, `infra/vault/`)**:
   - Vault Agent 템플릿: `kv/renovate/runtime`의 `github_token`을 `/renovate/runtime/github-token`에 권한 `0400`으로 렌더링
   - Vault AppRole/Kubernetes 정책 `renovate`에 `github_token` 읽기 권한 연결
3. **프로비저닝 및 검증 도구 (`gitops/tools/update-02/`)**:
   - `provision.sh`: Vault 정책/롤/시크릿(`github_token`) 주입 자동화 (`--apply`, `--check`, `--destroy`)
   - `verify-live.sh`: GitHub API 권한, 설정 선언, 단발 CronJob canary 실행, PR #16 (`chore(deps): update dependency boto3 to v1.43.72`) 생성 확인, 용량/자원 기준 점검, canary PR/branch/Job 자동 정리 완료

## 완료 증거 요약

| 검증 항목 | 기준 | 실측 결과 | 판정 |
|---|---|---|---|
| Vault Secret 주입 | `kv/renovate/runtime`의 `github_token` 조회 | JSON key `github_token` 정상 반환 | PASS |
| GitHub API 권한 | `ktcloud4-bean/hr-system` 푸시 권한 확인 | target=`ktcloud4-bean/hr-system`, push=`true`, private=`true` | PASS |
| Renovate 설정 선언 | 단일 저장소, 매니저 allowlist, automerge 비활성 | `platform: 'github'`, `repositories: ['ktcloud4-bean/hr-system']`, `enabledManagers: ['npm', 'pip_requirements']`, `automerge: false`, `platformAutomerge: false`, `allowScripts: false`, concurrent limit `1` | PASS |
| CronJob Canary 실행 | CronJob 원본 기반 단발 Job 실행 | `update02-canary-1786797997` Job `Complete`, `succeeded=1` | PASS |
| GitHub Canary PR 생성 | 단일 open/non-merged/renovate PR 생성 | PR `#16` (`chore(deps): update dependency boto3 to v1.43.72`), branch `renovate/boto3-1.x`, state `open`, merged `false` | PASS |
| 용량 및 자원 점검 | Proxmox/Guest 메모리, root 디스크, PVC 예산 | host available `15510 MiB` / total `64026 MiB`, guest memory `11077 MiB` / `31835 MiB`, root `30%`, PVC `13개/113792 MiB` (120 GiB 정지선 이하), 판정 `GO` | PASS |
| Canary 자원 정리 | 검증 종료 시 test Job 및 Canary PR/branch 정리 | open PR `0개`, test Job 삭제 완료, 잔여 renovate 브랜치 `0개` | PASS |

## 검증 로그 발췌

```text
=== UPDATE-02 검증 1: Vault runtime secret 조회 ===
UPDATE-02 Vault KV github_token 확인 완료
=== UPDATE-02 검증 2: GitHub API 권한 확인 ===
UPDATE-02 GitHub repo 권한: target=ktcloud4-bean/hr-system push=true private=true
=== UPDATE-02 검증 3: Renovate 설정 선언 검증 ===
UPDATE-02 Renovate config.js 선언(단일 권위 저장소, manager allowlist, automerge/script 비활성, concurrent limit 1) 확인 완료
=== UPDATE-02 검증 4: Renovate CronJob 기반 단발 Job 실행 canary ===
UPDATE-02 실행 전 기존 open PR 수: 0
UPDATE-02 test Job 생성: update02-canary-1786797997
UPDATE-02 Pod 실행 중: update02-canary-1786797997-26qjg
UPDATE-02 Renovate test Job 정상 완료 (succeeded=1)
UPDATE-02 실행 후 open PR 수: 1
UPDATE-02 Renovate Canary PR: #16 title='chore(deps): update dependency boto3 to v1.43.72' branch='renovate/boto3-1.x' state=open merged=false
=== UPDATE-02 검증 6: 용량 및 자원 기준 점검 ===
UPDATE-02 자원: node=k3s-01.imcherry5778.xyz cpu=1489m/18% memory=20299Mi/63%
UPDATE-02 자원: running_pods=73 aggregate=216m/15447Mi
UPDATE-02 자원: host_memory=15510/64026Mi pvc=13/113792Mi guest_memory=11077/31835Mi root=61125876/208520172Ki available=147394296Ki used=30% 판정=GO
=== UPDATE-02 검증 7: Canary PR 및 임시 자원 정리 ===
UPDATE-02 정리 후 open PR 수: 0
UPDATE-02 cleanup: test Job 및 Canary PR/branch 정리 완료
UPDATE-02 live evidence PASS
```
