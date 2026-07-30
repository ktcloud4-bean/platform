# 아키텍처 결정 기록

ADR(Architecture Decision Record)은 목표 구조를 선택한 이유, 검토한 대안과 재검토 조건을 보존한다. 최종 구조는 [`architecture.md`](../architecture.md), 작업 상태와 의존성은 [`backlog.md`](../backlog.md), 주소는 [`ip-plan.md`](../ip-plan.md)가 계속 소유한다.

## 기록 원칙

- 확정한 결정만 `Accepted`로 기록한다. 미결정 항목은 백로그의 `DEFERRED`와 재검토 조건으로 남긴다.
- 주소, 제품 버전, 명령, 비밀과 라이브 상태를 ADR에 복제하지 않는다.
- 구현이 바뀌어도 과거 ADR을 소급 수정하지 않는다. 새 ADR이 기존 ADR을 `Superseded`로 대체한다.
- 백로그 작업자는 작업 범위에 연결된 ADR을 읽고, 라이브 전제가 다르면 적용하지 않고 보고한다.
- 한 ADR은 하나의 결정을 다루고 1페이지 안팎으로 유지한다.

## 목록

| ID | 결정 | 상태 | 주요 재검토 조건 |
|---|---|---|---|
| [ADR-0001](0001-proxmox-bootstrap-reproducibility.md) | Proxmox 수동 기준 설치 후 자동설치 PoC | `Accepted` | 동일 사양 테스트 장비·두 번째 물리 노드 확보 |
| [ADR-0002](0002-single-node-k3s-and-local-storage.md) | 단일 k3s와 local storage | `Accepted` | 서로 다른 물리 장애 도메인 확보 |
| [ADR-0003](0003-service-vm-boundaries.md) | 서비스 VM 경계 | `Accepted` | 물리 노드·전용 NAS·제품 요구사항 변화 |
| [ADR-0004](0004-zero-trust-identity-and-management-access.md) | 통합인증과 관리 접근 | `Accepted` | 관리 클러스터 증가·운영자 역할 확대 |
| [ADR-0005](0005-backup-and-offsite-recovery.md) | 계층별 백업과 S3 오프사이트 | `Accepted` | 외부 NAS·PBS·두 번째 물리 사이트 확보 |
| [ADR-0006](0006-vault-seal-and-bootstrap-boundary.md) | Vault Shamir Day 1과 bootstrap 경계 | `Accepted` | 복구 drill 완료 후 AWS KMS 적용 |
| [ADR-0007](0007-detection-and-observability-staging.md) | 탐지·관측의 역할과 배포 순서 | `Accepted` | 자원 gate 통과·경보 품질과 대응 절차 검증 |
| [ADR-0008](0008-opentofu-provider-and-state-boundary.md) | OpenTofu provider와 state 경계 | `Accepted` | 원격 state 착지점 확보·provider 1.0·NetBox 전환 |

## 형식

새 ADR은 `배경`, `결정`, `검토한 대안`, `결과`, `재검토 조건`을 포함한다. 관련 백로그 ID는 탐색을 돕는 참조일 뿐 상태를 소유하지 않는다.
