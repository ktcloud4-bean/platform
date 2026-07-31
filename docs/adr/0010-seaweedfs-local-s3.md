# ADR-0010: 로컬 S3 구현을 SeaweedFS로 전환

- 상태: `Accepted`
- 날짜: 2026-07-31
- 관련 작업: `S3-DESIGN-01`, `S3-01`, `BKP-01`, `BKP-02`, `BKP-03`, `BKP-04`
- 부분 대체: ADR-0003·0005·0008의 MinIO 제품 지정만 대체하며 VM 분리, 로컬 착지점과 AWS S3 오프사이트 경계는 유지한다.

## 배경

초기 설계는 전용 DATA VM의 로컬 S3 구현으로 MinIO를 선택했다. `VM-01`은 그
계획에 따라 `minio-01` 이름의 빈 VM과 디스크를 만들고 내부 DNS를 등록했지만,
백로그와 Git 선언상 `MINIO-01` 서비스 배포는 시작하지 않았다. 이번 설계 작업의
라이브 조회는 VM identity에 한정하며 게스트 내부 설치 여부를 새 증거로 만들지 않는다.

그 사이 MinIO 공식 저장소는 2026-04-25 archived·read-only가 됐고 커뮤니티판은
소스 전용 배포로 바뀌어 과거 바이너리가 더는 갱신되지 않는다. 아직 운영 데이터를
넣지 않은 시점에 유지되는 오픈소스 구현으로 바꾸는 편이 장기 운영과 공급망 검증에
유리하다. 다만 S3 호환 제품은 Amazon S3의 모든 API와 동작을 같다고 가정할 수 없다.

현재 OpenTofu state의 모듈 키, Proxmox VM 이름과 내부 DNS는 `minio-01`이다. 이름만
성급히 바꿔도 새 VM 생성과 기존 VM 삭제로 계획될 수 있으므로 제품 선택과 라이브
마이그레이션을 분리한다.

## 결정

로컬 S3 구현은 Apache-2.0의 SeaweedFS를 사용한다. k3s 장애와 백업 착지점을
분리하는 전용 DATA VM 경계는 유지하며, 목표 canonical VM 이름은 제품에 중립적인
`object-01`, 내부 S3 service alias는 `s3`로 한다. 기존 VMID·주소·200 GiB 디스크를
그대로 사용하는 제자리 전환이며 두 번째 VM이나 디스크를 추가하지 않는다.

`S3-DESIGN-01`은 문서만 바꾸고 라이브 VM, DNS와 OpenTofu state를 변경하지 않는다.
실제 전환은 `S3-01` 한 세션이 `TOFU-STATE`·`PVE-LIVE`·`OPNSENSE-LIVE` 잠금을 함께
소유해 수행한다. 적용 전 state 복구 사본과 SHA-256을 남기고 OpenTofu `moved` 선언으로
모듈 주소를 옮긴다. plan에 destroy/create 또는 VM·디스크 교체가 하나라도 보이면
적용하지 않는다. 성공한 라이브 전환과 재부팅 검증 뒤에만 주소 계획의 현재 이름과
DNS를 `object-01`로 승격하고 이전 이름을 제거한다.

단일 VM에서도 master, volume server, filer와 S3 gateway의 역할·데이터 경로를
명시적으로 선언한다. 개발용 일괄 실행 명령을 운영 선언으로 사용하지 않는다.
애플리케이션에는 hostname 검증이 되는 TLS S3 endpoint만 제공하고 master·volume·
filer·관리 endpoint는 관리 경로로 제한한다. 한 물리 노드와 한 디스크 안의 복제나
erasure coding을 HA 또는 오프사이트 사본으로 간주하지 않는다.

SeaweedFS의 S3 호환성은 문서 표만으로 완료 처리하지 않는다. `S3-01`은 고정한
버전에서 최소권한 계정·bucket policy, object versioning, multipart upload, presigned
URL, 삭제·목록·checksum, 재부팅 후 데이터 보존을 제한된 시험으로 확인한다.
Velero node-agent/Kopia와 각 백업 생산자의 실제 백업·복원은 `BKP-01`–`BKP-03`이
검증한다. SeaweedFS가 Amazon S3의 bucket replication API를 지원한다고 가정하지 않고,
`BKP-04`가 별도 검증한 도구와 자격증명으로 로컬 S3에서 AWS S3로 사본을 만들고
AWS S3에서 복원한다.

제품 바이너리·컨테이너는 `S3-01` 시작 시 최신 안정 릴리스를 다시 조사해 정확한
버전과 digest를 고정한다. 자격증명과 TLS private key는 Git에 두지 않고 서비스별
최소권한 입력으로 주입한다.

## 검토한 대안

- **MinIO Community 유지:** S3 사용 경험은 풍부하지만 공식 저장소가 유지 중단됐고
  과거 사전 빌드 바이너리는 보안·버그 수정을 받지 않는다. 아직 미배포이므로 이
  시점에 기술 부채를 채택하지 않는다.
- **AWS S3만 사용:** 물리 장애 분리는 가장 명확하지만 로컬 복구 착지점과 제한된
  네트워크에서도 가능한 빠른 복구 사본이 사라진다.
- **Ceph·Longhorn:** 서로 다른 물리 장애 도메인이 없는 단일 노드에서는 복잡성과
  자원 사용만 늘고 이 설계가 요구하는 HA를 만들지 못한다.
- **기존 이름을 유지하고 구현만 교체:** 적용은 단순하지만 제품명이 인프라 식별자에
  남아 다음 구현 변경도 state·DNS 마이그레이션으로 만든다.

## 결과

- 로컬 S3 제품은 SeaweedFS이고 VM·DNS 목표 이름은 제품 중립적으로 바뀐다.
- 기존 VM·주소·디스크와 용량 예산은 유지되므로 새 자원 배정은 없다.
- 이름과 OpenTofu 주소를 안전하게 옮기는 별도 라이브 작업이 필요하다.
- S3 API 차이를 클라이언트별 복구 시험으로 부담해야 한다.
- 로컬 S3 장애가 AWS S3 사본의 상실로 이어지지 않도록 `BKP-04`가 계속 필수다.

## 재검토 조건

- SeaweedFS의 유지 상태, 라이선스 또는 배포 산출물 제공 방식이 크게 바뀐다.
- Velero/Kopia, PostgreSQL, Vault 또는 접근 서비스 백업이 필요한 S3 동작을 통과하지
  못한다.
- 독립 NAS, 두 번째 물리 노드나 별도 사이트의 오브젝트 저장소를 확보한다.
- 실제 용량·성능·복구 시간 측정이 현재 단일 VM 예산을 넘는다.

## 근거

- [MinIO 공식 저장소](https://github.com/minio/minio)
- [SeaweedFS 공식 저장소](https://github.com/seaweedfs/seaweedfs)
- [SeaweedFS Amazon S3 API 지원표](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)
