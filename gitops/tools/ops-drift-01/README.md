# OPS-DRIFT-01: 플랫폼 정기 Drift 감지 및 통지 도구

이 디렉터리는 `OPS-DRIFT-01`의 플랫폼 4대 인프라 계층(Argo CD Application, OPNsense config XML, AWS OpenTofu, Proxmox OpenTofu)에 대한 Read-only 정기 drift 판정 및 요약 통지 자동화를 소유한다.

## 1. 기본 원칙과 보안 경계

1. **절대적인 Read-only 원칙**:
   - OPNsense: `infra/opnsense/scripts/check-drift.sh` 호출 시 `--update` 플래그는 절대 전달되지 않으며 자동 수정·스냅샷 갱신을 금지한다.
   - OpenTofu (AWS/Proxmox): `tofu plan -detailed-exitcode` 만 수행하며 `tofu apply` 는 절대 호출하지 않는다.
   - Argo CD: Application 동기화 상태(`status.sync.status`)만 조회하며 자동 sync/rollback을 trigger하지 않는다.
2. **유지보수·공유 잠금 Skip**:
   - `ARGO-ROOT`, `OPNSENSE-LIVE`, `PVE-LIVE`, `TOFU-STATE` 등의 공유 잠금이 걸려 있거나 유지보수 작업 중일 때(`--skip-if-locked true` 또는 `SKIP_IF_LOCKED=true`), drift 검사를 실행하지 않고 `SKIPPED` 상태로 정상 종료하여 오탐을 방지한다.
3. **민감 정보 마스킹 및 출력 방지**:
   - `tofu plan` 출력 및 OPNsense XML diff에서 비밀번호, 토큰, 암호화 키, PSK 등 민감 정보가 로그 또는 알림 payload에 노출되지 않도록 엄격하게 마스킹(`actions=summary-redacted sensitive-output=0`)한다.
4. **중복 통지 방지**:
   - 개별 도구가 산발적으로 경보를 발송하지 않고, `run-drift-check.sh`가 4대 계층의 상태를 단일 종합 보고서로 취합하여 1회의 단일 요약 알림으로 전달한다.

## 2. 구성 도구 목록

| 파일 | 역할 및 소유 범위 |
|---|---|
| [`check-argo-drift.sh`](check-argo-drift.sh) | Argo CD Application들의 `OutOfSync` 상태 판정 (live / fixture 지원) |
| [`check-opnsense-drift.sh`](check-opnsense-drift.sh) | OPNsense 라이브 XML과 Git `config.xml` 간 정규화 diff 판정 (read-only) |
| [`check-aws-tofu-drift.sh`](check-aws-tofu-drift.sh) | AWS OpenTofu 4개 root(`tofu-app-network`, `tofu-app-ecr`, `tofu-account-baseline`, `tofu-app-security`) plan drift 판정 |
| [`check-pve-tofu-drift.sh`](check-pve-tofu-drift.sh) | Proxmox OpenTofu VM 리소스 plan drift 판정 (gate 변수 및 state 지정) |
| [`run-drift-check.sh`](run-drift-check.sh) | 4개 계층 통합 검사 실행기, 종합 JSON/텍스트 보고서 생성, 알림 발송 및 skip 처리 |
| [`Jenkinsfile`](Jenkinsfile) | Jenkins CI 파이프라인 스크립트 (`ops-drift-check` job) |
| [`test-drift-check.sh`](test-drift-check.sh) | 오프라인 및 fixture 기반 회귀/안전성 테스트 스위트 (7개 테스트 통과) |
| `fixtures/` | 비밀 없는 테스트 fixture 디렉터리 (Argo JSON, OPNsense diff, AWS/PVE plan diff) |

## 3. 실행 방법

### 로컬 단독 실행
```bash
# 전체 계층 점검 (JSON 형식)
bash gitops/tools/ops-drift-01/run-drift-check.sh --json

# 특정 계층만 점검
bash gitops/tools/ops-drift-01/run-drift-check.sh --target-layer argo

# 잠금/유지보수 skip 검증
bash gitops/tools/ops-drift-01/run-drift-check.sh --skip-if-locked true
```

### Fixture 기반 시뮬레이션 검증
```bash
# Argo OutOfSync fixture 주입 검출
bash gitops/tools/ops-drift-01/run-drift-check.sh --fixture-drift argo

# OPNsense diff fixture 주입 검출
bash gitops/tools/ops-drift-01/run-drift-check.sh --fixture-drift opnsense

# AWS OpenTofu plan fixture 주입 검출
bash gitops/tools/ops-drift-01/run-drift-check.sh --fixture-drift aws-tofu

# Proxmox OpenTofu plan fixture 주입 검출
bash gitops/tools/ops-drift-01/run-drift-check.sh --fixture-drift pve-tofu
```

### 회귀 테스트 스위트 실행
```bash
bash gitops/tools/ops-drift-01/test-drift-check.sh
```
