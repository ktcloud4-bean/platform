# ADR-0005: 계층별 백업과 S3 오프사이트

- 상태: `Accepted`
- 날짜: 2026-07-30
- 관련 작업: `BKP-01`, `BKP-02`, `BKP-03`, `BKP-04`, `BKP-05`, `PVE-BKP-01`

## 배경

하나의 Proxmox와 NVMe에 있는 VM·MinIO·스냅샷은 빠른 논리 복구에는 유용하지만 화재, 분실, 디스크와 호스트 장애를 함께 겪는다. Kubernetes 객체, local PVC, k3s datastore, PostgreSQL과 Vault는 동일한 도구로 일관되게 복구되지 않는다.

## 결정

백업은 데이터 소유 계층별로 수행한다. k3s SQLite와 server token은 전용 절차로, Kubernetes 리소스와 local PVC는 Velero와 파일 백업으로, PostgreSQL은 DB 네이티브 방식으로, Vault는 Raft snapshot과 구성으로 보호한다. NetBird와 Warpgate는 제품 DB·구성을 별도로 백업한다.

로컬 백업은 MinIO에 모으고 버킷 단위로 AWS S3에 오프사이트 사본을 둔다. MinIO를 오프사이트로 간주하지 않는다. 두 번째 SSD가 추가되면 Proxmox VM backup을 빠른 복구 수단으로 추가하되 애플리케이션 백업과 S3 사본을 대체하지 않는다.

완료 기준은 백업 파일 생성이 아니라 격리된 대상에 대한 복원이다. 통합 drill에서 실제 RPO/RTO, 누락된 비밀과 수동 단계를 기록한다. 로그는 백업 자산이 아니라 보존기간과 용량 상한을 가진 운영 데이터로 다룬다.

## 검토한 대안

- **Proxmox VM backup만 사용:** 복구는 빠르지만 애플리케이션 단위 복원과 오프사이트 장애 분리가 부족하다.
- **Velero로 k3s 전체를 보호:** Kubernetes 리소스와 PVC는 다루지만 SQLite datastore와 server token을 대체하지 않는다.
- **MinIO 사본만 유지:** 원본과 같은 물리 장애 도메인에 있어 재해 복구가 아니다.

## 결과

- 백업 종류와 복원 순서가 늘어나 운영 비용이 생긴다.
- Git과 S3만으로 핵심 서비스를 재구축하는 목표를 검증할 수 있다.
- MinIO 또는 k3s 장애가 모든 백업 사본의 상실로 이어지지 않는다.
- 복구 자격증명은 복구 대상인 Vault에만 저장할 수 없다.

## 재검토 조건

- 독립 NAS, Proxmox Backup Server 또는 두 번째 물리 사이트를 확보한다.
- CSI snapshot을 신뢰할 수 있는 외부 스토리지를 도입한다.
- 통합 복구 drill에서 목표 RPO/RTO를 충족하지 못한다.
