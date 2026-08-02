# 통합 재해복구 drill (`BKP-05`)

- 작업: `BKP-05`
- 검증일: 2026-08-02
- 잠금: `K3S-BOOTSTRAP`
- 설계: [ADR-0005](../adr/0005-backup-and-offsite-recovery.md)
- 계층별 입력: [k3s SQLite](k3s-sqlite-datastore-backup-restore.md),
  [Velero local PV](velero-local-pv-backup-restore.md),
  [PostgreSQL·Vault](postgres-vault-native-backup.md),
  [SeaweedFS→AWS S3](seaweedfs-s3-offsite-backup.md)

이 문서는 계층별 backup 생성·암호화·보존·최소권한을 다시 판정하지 않는다. Git revision과
AWS S3 오프사이트 사본만으로 실제 복구 체인이 이어지는지, 단계별 RPO/RTO, 저장소 밖
필수 입력과 사람이 수행할 절차를 한 번의 순차 drill로 기록한다.

## 목적·전제와 접근 권한

목적은 다음 순서가 성립하는지 확인하는 것이다.

1. 고정 Git revision에서 빈 k3s 제어면을 SQLite datastore와 server token으로 복원한다.
2. 복원한 cluster에서 Velero filesystem backup으로 PVC를 복원한다.
3. PostgreSQL physical archive를 격리 cluster로, Vault Raft snapshot을 격리 namespace로
   복원한다.
4. 복원 대상의 서비스 수준 판정 하나씩을 얻고, 불가능하면 정확한 중단 입력을 남긴다.

이번 실행은 `origin/main`의 `13382b46cbe2f82e8807d28b792beaa284601e53`을 Git 입력으로
사용했다. 시작 전 `platform-root`와 7개 child Application은 모두 `Synced/Healthy`,
`platform-root.targetRevision=main`, Node는 `Ready=True`·`DiskPressure=False`, Vault는
`initialized=true`·`sealed=false`였다.

복구 작업자는 strict SSH의 관리 key·known_hosts, Git 읽기 권한, AWS S3 오프사이트
read credential, 그리고 아래 표의 GPG/Vault 입력을 별도 안전 보관소에서 가져와야 한다.
그 값은 Git, S3 object key, shell history, 일반 log에 넣지 않는다.

## 예상 영향·잠금과 중단 조건

이 drill은 `K3S-BOOTSTRAP` 잠금을 단독 소유한다. live k3s, live PostgreSQL, live Vault,
기존 PVC/PV, 기존 S3 bucket·identity·AWS object는 변경·정지·삭제하지 않는다. 복원은
폐기 가능한 VM, namespace, PGDATA만 대상으로 한다.

다음이면 해당 단계를 시작하지 않고 시작·종료 시각, 응답, 필요한 입력만 기록한 뒤 다음
독립 계층으로 진행한다.

- Argo Application, Node, Vault unseal 상태가 사전 기준과 다름
- 정확한 AWS S3 prefix가 비었거나 대상 object가 없음
- GPG private key/passphrase, S3 read credential, Vault threshold unseal key처럼 복구에
  필요한 저장소 밖 입력이 없음
- 임시 VMID·namespace·port·PGDATA 경로가 이미 존재하거나 격리 조건을 만족하지 않음

실패한 단계를 live 서비스 중단, local S3 fallback, 자격증명 교체, 추정 수정으로 재실행하지
않는다. local SeaweedFS는 물리 장애 도메인이 같으므로 이 통합 drill의 오프사이트 대체물이
아니다.

## 2026-08-02 실행 순서와 결과

모든 시각은 UTC다. AWS object 존재 여부는 `object-01`의 root-only systemd
`EnvironmentFile`을 읽는 일회성·자동 수거 transient unit으로만 조회했다. 이 방법은
credential 값을 출력하거나 파일로 복사하지 않는다.

| 순서 | 시작 → 종료 | 입력·실행 | 서비스 수준 판정 | 결과 |
|---|---|---|---|---|
| 사전 기준 | 02:36:04 → 02:36:05 | Argo, Node, Vault, `platform-root=main` 조회 | 전제 전부 충족 | 통과 |
| k3s control plane | 02:36:59 → 02:36:59 | AWS `seaweedfs/bkp-01-k3s-datastore/` 열거 | 복호화 archive를 꺼내 격리 VM API object를 조회해야 함 | **중단**: object 0개, controller GPG recovery private key도 부재 |
| PostgreSQL | 02:39:38 → 02:39:49 | AWS `postgres-base-20260801T171906Z.tar.gz`를 `/var/tmp/bkp05-pg-20260802`로 stream | 격리 Unix socket cluster에서 `keycloak_user` 1개와 Keycloak public table 100개, TCP listener 0개 | 통과, 11초 |
| Velero PVC | 02:40:10 → 02:40:10 | AWS `seaweedfs/bkp-02-velero/` 크기 조회 | 복원 PVC의 파일 1개를 조회해야 함 | **중단**: object 0개 |
| Vault | 02:40:10 → 02:40:10 | AWS에는 `vault-raft-20260801T175022Z.snap` 존재 | 격리 Vault unseal 뒤 KV read 1건을 해야 함 | **중단**: `KTC_SECRET_ROOT` 미설정으로 threshold Shamir key 입력을 찾을 수 없음; namespace를 만들지 않음 |

순차상 k3s 단계가 먼저 중단되어 이후 cluster 의존 PVC·Vault 복원은 성공 판정을 시도하지
않았다. PostgreSQL은 그 의존성이 없는 별도 host의 AWS archive 경로를 이어서 판정했다.
각 중단은 복구 단절의 증거이며 local S3에서 다시 시도하지 않았다.

PostgreSQL 검증은 `listen_addresses=''`와 전용 Unix socket만 썼다. archive·임시 PGDATA·socket은
trap으로 제거했고, 종료 확인에서 `/var/tmp/bkp05-pg-20260802`,
`bkp-03-vault-restore` namespace, TCP 18200, VMID 9901은 모두 부재였다. 종료 뒤에도 Node는
`Ready=True`, 모든 Application은 `Synced/Healthy`, Vault는 unsealed였다.

## RPO·RTO 실측

RPO는 각 단계 시작 시점에 AWS S3에서 선택 가능한 가장 최근 asset의 나이이며, asset 자체가
없으면 유한한 RPO를 주장하지 않는다. RTO는 단계 시작부터 성공 판정 또는 결정적 중단까지의
실측 시간이다.

| 계층 | AWS S3 asset | 실측 RPO | 실측 RTO | 판정 |
|---|---|---:|---:|---|
| k3s SQLite·token | 0 object | 무한대 | 0초 | 오프사이트 복구 시작 불가 |
| Velero local PV | 0 object | 무한대 | 0초 | 오프사이트 PVC 복구 시작 불가 |
| PostgreSQL | `2026-08-01T17:19:06Z` physical archive | 9시간 20분 32초 | 11초 | 격리 DB query 통과 |
| Vault Raft | `2026-08-01T17:50:22Z` snapshot | 8시간 49분 48초 (asset 기준) | 무한대 | unseal key 입력 부재로 unseal·KV read 불가 |
| 핵심 서비스 전체 | 일부 계층 asset/입력 부재 | 무한대 | 무한대 | Git+AWS S3만으로 완결 복구 불가 |

ADR-0005에는 수치 목표가 따로 없지만, 이 drill은 핵심 서비스 전체에 유한한 RPO/RTO를
제시하지 못했다. 따라서 ADR-0005의 **통합 drill에서 목표 RPO/RTO를 충족하지 못한 경우**라는
재검토 조건에 해당한다.

## Git+S3 밖 필수 입력과 수동 단계

| 구분 | Git+S3 밖 필수 입력 | 이번 drill에서 확인한 영향 |
|---|---|---|
| 접근 | Git read credential, 복구 host SSH private key와 trusted known_hosts | 새 recovery environment에서 Git checkout과 strict 관리 접속이 멈춘다 |
| S3 | AWS S3 offsite read credential과 CA/endpoint 설정 | 이번 PostgreSQL download는 기존 `object-01`의 mode `0600` systemd 입력에 의존했다. 그 host를 잃으면 별도 보관본이 필요하다 |
| k3s | BKP-01 recovery GPG private key와 passphrase, S3 read identity | private key가 controller에 없고 AWS prefix도 비어 있어 SQLite·server token archive를 복호화할 수 없다 |
| Vault | 원본 Shamir threshold(3개) unseal key와 복구 절차용 mode `0600` key file | `KTC_SECRET_ROOT`가 설정되지 않아 격리 Vault unseal 전 중단했다 |
| 기반 | 폐기 가능한 recovery VM/OS image와 그 관리 접근 | 기존 BKP-01 절차는 Proxmox template 9000을 전제한다. 그 template도 Git+AWS S3에 없으면 새 복구 환경 생성이 멈춘다 |

수동으로 해야 하는 일은 다음과 같다.

1. 복구 환경에서 고정 Git SHA를 checkout하고, AWS S3 read credential과 TLS 신뢰 입력을
   root-only `0600` 경로에 준비한다.
2. k3s는 빈 VM을 만들고 GPG private key로 datastore/token archive를 복호화한 뒤 격리한
   상태에서 API ready와 `platform-root` object를 확인한다.
3. k3s가 준비된 뒤 Velero backup/Restore와 local PV filesystem restore를 실행한다.
4. Vault는 격리 namespace에 snapshot-force한 뒤 원본 threshold unseal key 3개를 요청 본문으로
   전달하고 KV read를 확인한다.
5. 각 임시 VM, namespace, PGDATA, archive와 port-forward를 제거하고 부재를 확인한 뒤에만
   서비스 전환을 검토한다.

## 성공 판정과 실패 시 원상복구

성공은 k3s API object, Velero PVC 파일, PostgreSQL query, Vault KV read가 각각 한 번씩
통과하고 전체 RPO/RTO가 유한하게 기록된 경우다. 2026-08-02에는 PostgreSQL만 통과했으므로
**통합 복구 성공이 아니다**. 이 runbook은 한 번의 drill 결과를 기록한 것이며, 누락 asset과
외부 입력을 보완하는 별도 작업 없이 성공으로 해석하지 않는다.

실패·중단 시에는 live 서비스에 restore하지 않는다. 해당 단계의 임시 VM·PGDATA·namespace·
port-forward·download archive만 삭제하고, 기존 bucket·identity·PVC/PV·AWS object와 live
datastore/DB/Vault는 보존한다. 이번 실행은 PostgreSQL 임시 경로만 만들었고 제거를 확인했다.

## 남기면 안 되는 출력

다음은 Git, 문서, chat, 일반 journal, command line에 남기지 않는다: AWS/S3 secret key,
GPG private key와 passphrase, k3s server token, Vault root token과 Shamir unseal key,
복호화 archive·snapshot 원문, PostgreSQL backup credential, root-only `0600` input 파일 내용.
실행 기록에는 object timestamp, SHA-256, byte count, 결과 코드, service-level count처럼
비밀이 아닌 메타데이터만 남긴다.
