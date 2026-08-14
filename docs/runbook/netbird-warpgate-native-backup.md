# NetBird·Warpgate native backup 및 격리 복원 (`BKP-08`)

- 대상: `netbird-01`의 NetBird 설정 및 SQLite DB(`store.db`, `events.db`, `idp.db`), `warpgate-01`의 Warpgate 설정, SQLite DB(`db.sqlite3`), 녹화본(`recordings`), SSH 키 및 TLS 자료
- 착지점: `object-01`의 BKP-08 전용 SeaweedFS S3 bucket (`bkp-08-netbird`, `bkp-08-warpgate`)
- 설계 경계: [ADR-0005](../adr/0005-backup-and-offsite-recovery.md)

## 1. 소유 범위와 금지 경계

`BKP-08`은 NetBird와 Warpgate의 native snapshot 생성, 정기 실행, 7세대 보존, S3 round-trip,
격리 복원, freshness 기반 실패 탐지를 소유한다. 주소와 서비스 배치는
[IP 계획](../ip-plan.md)과 [아키텍처](../architecture.md)를 단일 원본으로 사용한다.

다음 경계는 자동화보다 우선한다.

- live NetBird 서비스(`netbird-compose.service`) 및 live Warpgate 서비스(`warpgate.service`)는 중단하지 않는다.
- 백업은 SQLite native online backup API (`sqlite3 ... ".backup '...'"` 또는 `vacuum into`) 및 읽기 전용 ACL을 통해 온라인 상태에서 안전하게 snapshot을 생성한다.
- restore 검증은 live SQLite DB나 설정 파일을 직접 덮어쓰지 않고, 격리된 임시 디렉터리(`bkp03_cache_dir/verify-*`)에서 tarball 압축 해제, 파일 완전성 확인, SQLite `PRAGMA quick_check` 무결성 검증으로 수행한다.
- NetBird와 Warpgate host는 각각 전용 비로그인 system user(`netbird-backup`, `warpgate-backup`)와 group을 사용하여 서비스 실행 사용자와 백업 실행 사용자를 엄격히 분리한다.
- SeaweedFS S3 gateway는 각 백업 producer별 최소권한 S3 identity(`bkp-08-netbird`, `bkp-08-warpgate`)를 발급하며, 상대 버킷에 대한 쓰기/읽기 권한은 완전히 차단된다.
- SeaweedFS S3 gateway의 systemd drop-in(`/etc/systemd/system/seaweedfs-s3.service.d/bkp-08.conf`)을 통해 `netbird-01`(`10.10.40.10/32`) 및 `warpgate-01`(`10.10.30.10/32`)의 IP만 허용하도록 소스 IP를 제한한다.
- SeaweedFS `volume.max=30`은 기존 default·BKP-01·BKP-02·BKP-03·Harbor volume과 BKP-08의 NetBird/Warpgate volume slot을 함께 보존하는 선언이다. 이미 할당된 volume ID가 있으면 이 값을 낮추거나 volume을 제거하지 않는다.
- 기존 bucket·identity는 보존한다. 이 작업이 소유하는 이름만 갱신하거나 rollback한다.

## 2. 선언 계약

| 대상 | 전용 identity | 대상 Bucket | 허용 권한 | 정기 실행 | 보존 |
|---|---|---|---|---|---|
| NetBird producer | `bkp-08-netbird` | `bkp-08-netbird` | `Read/List/Write:bkp-08-netbird` | 매일 03:00, 최대 10분 분산 | 최신 7세대 |
| Warpgate producer | `bkp-08-warpgate` | `bkp-08-warpgate` | `Read/List/Write:bkp-08-warpgate` | 매일 03:30, 최대 10분 분산 | 최신 7세대 |

### 보안 및 격리

1. **최소권한 S3 Identity**:
   - `bkp-08-netbird`는 `bkp-08-netbird` 버킷에만 `Read/List/Write` 가능.
   - `bkp-08-warpgate`는 `bkp-08-warpgate` 버킷에만 `Read/List/Write` 가능.
   - 교차 쓰기/읽기는 SeaweedFS S3 ACL 수준에서 완전히 거부됨.
2. **최소권한 OS 계정**:
   - `netbird-backup` (비로그인 `/sbin/nologin`, shell 없음)
   - `warpgate-backup` (비로그인 `/sbin/nologin`, shell 없음)
   - 원본 데이터 디렉터리는 POSIX ACL(`setfacl -m u:<backup-user>:rx`)로 읽기 전용 접근만 허용.
3. **무결성 및 Freshness 검증**:
   - 백업 완료 시 로컬 및 S3 SHA-256 round-trip 다운로드 검증 수행.
   - 실패 시 systemd `OnFailure` handler로 failure marker 기록.
   - 36시간 freshness timer(`*-native-backup-health.timer`)로 백업 누락 및 지연 자동 탐지.

## 3. 선언 적용

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 known_hosts> -o PasswordAuthentication=no"

# 문법 및 check 실행
ansible-playbook -i <inventory> playbooks/bkp-08-native-backup.yml --syntax-check
ansible-playbook -i <inventory> playbooks/bkp-08-native-backup.yml --check --diff

# 실제 적용
ansible-playbook -i <inventory> playbooks/bkp-08-native-backup.yml

# 멱등성 검증 (changed=0, failed=0 확인)
ansible-playbook -i <inventory> playbooks/bkp-08-native-backup.yml
```

## 4. 수동 백업 및 복원 검증

### NetBird 수동 백업 및 복원 검증

```bash
# 백업 서비스 즉시 실행
sudo systemctl start netbird-native-backup.service

# 백업 상태 및 로그 확인
sudo systemctl status netbird-native-backup.service
sudo cat /var/lib/netbird-native-backup/last-run.log

# 격리 복원 검증 스크립트 실행
sudo /usr/local/sbin/netbird-native-restore-verify

# Freshness 헬스체크 실행
sudo systemctl start netbird-native-backup-health.service
sudo systemctl status netbird-native-backup-health.service
```

### Warpgate 수동 백업 및 복원 검증

```bash
# 백업 서비스 즉시 실행
sudo systemctl start warpgate-native-backup.service

# 백업 상태 및 로그 확인
sudo systemctl status warpgate-native-backup.service
sudo cat /var/lib/warpgate-native-backup/last-run.log

# 격리 복원 검증 스크립트 실행
sudo /usr/local/sbin/warpgate-native-restore-verify

# Freshness 헬스체크 실행
sudo systemctl start warpgate-native-backup-health.service
sudo systemctl status warpgate-native-backup-health.service
```

## 5. 비상 복구 절차 (Disaster Recovery)

호스트 완전 손실 또는 데이터베이스 오염 발생 시 백업본으로부터 복구하는 절차:

1. **S3 버킷에서 복원 대상 아카이브 다운로드**:
   ```bash
   rclone copyto local:bkp-08-netbird/netbird/<아카이브파일명> /tmp/restore.tar.gz \
     --config /etc/netbird-native-backup/rclone.conf \
     --ca-cert /etc/netbird-native-backup/s3.crt
   ```
2. **서비스 정지**:
   ```bash
   sudo systemctl stop netbird-compose.service
   ```
3. **아카이브 압축 해제 및 파일 복원**:
   ```bash
   sudo tar -xzvf /tmp/restore.tar.gz -C /
   ```
4. **SQLite 무결성 확인 및 서비스 재기동**:
   ```bash
   sqlite3 /var/lib/netbird/store.db "PRAGMA quick_check;"
   sudo systemctl start netbird-compose.service
   sudo systemctl status netbird-compose.service
   ```
