# OPS-DRIFT-01 완료 증거

## 판정

`OPS-DRIFT-01`은 플랫폼 4대 인프라 계층(Argo CD Application, OPNsense config XML, AWS OpenTofu, Proxmox OpenTofu)에 대한 Read-only 정기 drift 판정과 종합 통지 도구 및 Jenkins 파이프라인(`ops-drift-check`)을 구성하고 실측·회귀 검증을 완료했다.

| 항목 | 증거 | 결과 |
|---|---|---|
| OPNsense 라이브 | `check-drift.sh` 실행 시 `드리프트 없음 ✓` (exit 0) 및 `--update` 미호출 확인 | PASS |
| Proxmox OpenTofu 라이브 | gate 변수 및 state 지정 `tofu plan -detailed-exitcode` 무변경(`No changes`, exit 0) 및 `apply` 미호출 확인 | PASS |
| Lock skip 모드 | `--skip-if-locked true` 시 `SKIPPED` 상태 반환 및 실행 생략 | PASS |
| Argo Fixture Drift | `fixtures/argo-outofsync.json` 주입 시 `fixture-app-demo` OutOfSync 정확 감지 (exit 2) | PASS |
| OPNsense Fixture Drift | `fixtures/opnsense-diff.diff` 주입 시 XML diff 정확 감지 및 민감 문자열 마스킹 (exit 2) | PASS |
| AWS OpenTofu Fixture Drift | `fixtures/tofu-aws-plan-drift.txt` 주입 시 `Plan: 1 to add` 감지 및 요약 파싱 (exit 2) | PASS |
| Proxmox OpenTofu Fixture Drift | `fixtures/tofu-pve-plan-drift.txt` 주입 시 `Plan: 0 to add, 1 to change` 감지 (exit 2) | PASS |
| 통합 Runner Fixture | `run-drift-check.sh --fixture-drift argo` 단일 계층 fixture drift 통합 JSON 파싱 및 종합 보고 (exit 2) | PASS |
| 안전성 및 불변성 | 코드 내 `check-drift.sh --update` 및 `tofu apply` 호출 0건, 민감값 유출 0건 검증 | PASS |
| Jenkins JCasC 선언 | `gitops/apps/jenkins/jenkins.yaml`에 `ops-drift-check` Cron(`H 4 * * *`) 및 Job 선언 추가 | PASS |
| 정적 검사 | `shellcheck gitops/tools/ops-drift-01/*.sh` 경고 0건, `scripts/check-backlog.sh` 통과 | PASS |

## 보안 및 실행 경계

1. **순수 Read-only 보장**:
   - OPNsense: 자동 수정 또는 스냅샷 강제 갱신 금지 (`--update` 절대 미호출).
   - OpenTofu: 인프라 자동 적용 금지 (`apply` 절대 미호출, `-detailed-exitcode` 기반 판정).
   - Argo CD: Application sync status read-only 조회.
2. **비밀 원문 부재**:
   - `tofu plan` 출력 및 OPNsense XML diff에서 비밀번호, 토큰, 암호화 키, PSK 등 민감 정보가 로그 또는 알림 payload에 노출되지 않도록 엄격하게 마스킹(`actions=summary-redacted sensitive-output=0`).
3. **유지보수·공유 잠금 Skip**:
   - `ARGO-ROOT`, `OPNSENSE-LIVE`, `PVE-LIVE`, `TOFU-STATE` 등의 공유 잠금이 걸려 있거나 유지보수 작업 중일 때(`--skip-if-locked true`), drift 검사를 실행하지 않고 `SKIPPED` 상태로 정상 종료하여 오탐을 방지한다.
4. **중복 통지 방지**:
   - 개별 도구가 산발적으로 경보를 발송하지 않고, `run-drift-check.sh`가 4대 계층의 상태를 단일 종합 보고서로 취합하여 1회의 단일 요약 알림으로 전달한다.
