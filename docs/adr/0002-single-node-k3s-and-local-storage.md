# ADR-0002: 단일 k3s와 local storage

- 상태: `Accepted`
- 날짜: 2026-07-30
- 관련 작업: `K3S-01`, `STOR-01`, `BKP-01`, `BKP-02`, `CAP-02`

## 배경

물리 Proxmox가 한 대이므로 여러 Kubernetes VM을 만들어도 전원, CPU, 메모리와 NVMe 장애를 공유한다. 같은 물리 장치 안의 복제는 노드 장애나 디스크 장애에 대한 HA가 아니다. 제한된 자원에는 인증, 공급망, 백업과 관측 서비스를 함께 배치해야 한다.

## 결정

k3s는 단일 server VM과 기본 SQLite datastore를 사용한다. 기본 Traefik을 유일한 ingress controller로 두고 기본 `local-path` StorageClass로 PVC를 동적 프로비저닝한다.

한 물리 장애 도메인에서는 Longhorn과 Ceph를 사용하지 않는다. PVC 요청량은 파일시스템 하드 쿼터로 간주하지 않고 실제 사용량, 노드 여유 공간과 disk pressure를 별도로 관찰한다. Kubernetes 리소스·PVC와 k3s datastore는 서로 다른 방식으로 백업하고 실제 복원을 완료 조건으로 삼는다.

## 검토한 대안

- **동일 Proxmox의 3노드 k3s:** control-plane 형태는 흉내 낼 수 있지만 물리 HA 없이 메모리·디스크·운영 비용만 늘어난다.
- **Longhorn 또는 Ceph:** 같은 NVMe와 호스트에 복제본이 놓여 주요 장애를 견디지 못한다.
- **모든 상태를 hostPath로 직접 관리:** 단순하지만 동적 프로비저닝과 선언형 PVC 계약을 잃는다.

## 결과

- 자원 효율과 local storage의 위치·복구 모델이 단순해진다.
- k3s VM이나 NVMe 장애 시 서비스 중단을 허용한다.
- PVC를 여러 개로 나누어도 물리 용량은 공유하므로 요청량과 실제 사용량을 함께 감시해야 한다.
- 다중 replica는 애플리케이션 배포 연습에는 유효하지만 물리 가용성 보장은 아니다.

## 재검토 조건

- 서로 다른 물리 노드와 독립 디스크·전원을 확보한다.
- 외부 CSI 스토리지나 프로젝트 전용 NAS를 확보한다.
- 단일 노드에서 수용할 수 없는 자원·업그레이드·가용성 요구가 생긴다.
