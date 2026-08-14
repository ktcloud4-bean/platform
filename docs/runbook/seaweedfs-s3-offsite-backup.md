# SeaweedFS 로컬 S3 → AWS S3 오프사이트 사본 운영 런북

작업: `BKP-04`
검증일: 2026-07-31
전송 호스트: `object-01.imcherry5778.xyz` (VMID 151, DATA VLAN)
원본 endpoint: `https://s3.imcherry5778.xyz:8333`

이 문서는 로컬 SeaweedFS S3의 오프사이트 사본 경로를 실제로 만들고 검증한 절차와
증거를 소유한다. 로컬 S3 자체는 [seaweedfs-s3.md](seaweedfs-s3.md), 계층별 백업 결정은
[ADR-0005](../adr/0005-backup-and-offsite-recovery.md), state 경계는
[ADR-0008](../adr/0008-opentofu-provider-and-state-boundary.md)를 따른다. 주소는
[ip-plan.md](../ip-plan.md)가 소유한다.

AWS 계정 ID, bucket 전체 이름, ARN과 access key는 이 문서에 적지 않는다. 값의 단일
원본은 `infra/aws/tofu`의 output이고, 실제 변수와 자격증명은 저장소 밖 mode `0600`
파일에만 있다.

## 전송 계약

| 항목 | 값 | 근거 |
|---|---|---|
| 전송 호스트 | `object-01` | 원본과 같은 host라 8333용 신규 방화벽 규칙이 필요 없고, 필요한 것은 outbound 443뿐이다 |
| 전송 도구 | rclone 1.74.4 `linux-amd64` | 고정 버전·digest, S3→S3 스트리밍 |
| 방향 | push, `rclone copy` 전용 | `sync`와 `--delete-*`를 쓰지 않는다 |
| 사본 검증 | `rclone check --download --one-way` | 양쪽 object 본문을 내려받아 source 기준 byte 차이 0을 강제한다 |
| AWS 착지 경로 | `s3://<bucket>/seaweedfs/<로컬 bucket>/<key>` | 원본 bucket 이름이 한 단계 아래에 그대로 보존된다 |
| liveness 경로 | `s3://<bucket>/_heartbeat/<host FQDN>.txt` | 매 실행이 AWS 자격증명·네트워크·쓰기 권한을 실제로 사용한다 |
| 암호화 | SSE-S3 `AES256` | bucket 기본 암호화 + rclone이 헤더를 명시 |
| versioning | `Enabled` | 덮어쓰기·손상에서 되돌릴 창 |
| 보존 | 구버전 30일, 미완료 multipart 7일 | lifecycle rule 2개 |
| 실행 주기 | 매일 03:20 + 최대 10분 분산, `Persistent=true` | `offsite-backup.timer` |
| 실패 경보 | systemd `OnFailure=` → SNS `Publish` | job 자체의 실패 |
| 부재 경보 | CloudWatch alarm, `treat_missing_data=breaching` | job이 아예 돌지 않는 실패 |

`rclone copy`는 원본 삭제를 따라가지 않는다. 규칙만으로 두지 않고 AWS IAM policy에
삭제 action을 아예 넣지 않아 권한으로도 막는다. Ansible role은 `offsite_allow_delete`가
참이면 적용을 거부한다.

## 고정 입력과 공급망

| 입력 | 값 |
|---|---|
| rclone release | 1.74.4, `rclone-v1.74.4-linux-amd64.zip` |
| archive SHA-256 | `fe435e0c36228e7c2f116a8701f01127bb1f694005fc11d1f27186c8bca4115d` |
| license | MIT |
| license SHA-256 | `8cd2e9e750b90a04b7d82dbbca3930c696ae0309d7c10464f90a44f45754cd04` |
| OpenTofu | 1.12.5 |
| AWS provider | `hashicorp/aws` 6.56.0 (정확히 고정) |

digest는 [공식 릴리스의 `SHA256SUMS`](https://github.com/rclone/rclone/releases/tag/v1.74.4)에서
가져왔고, 그 파일의 PGP 서명을 [`rclone.org/KEYS`](https://rclone.org/KEYS)의 유지자 키
`FBF737EC E9F8AB18 604BD2AC 93935E02 FF3B54FA`로 검증해 `Good signature`를 확인했다.
Ansible `get_url checksum`이 archive와 license를 강제한다. mutable `latest`나 배포판
패키지를 쓰지 않는다.

AWS provider는 6.57.x가 릴리스 당일 패치를 낸 계열이라 후속 패치 없이 일주일을 넘긴
6.56.0을 고정했다.

## AWS 착지점 경계

`infra/aws/tofu`가 bucket, bucket policy, IAM user·policy·access key, SNS topic·구독,
CloudWatch alarm 12개를 소유한다. Proxmox state와 분리된 별도 root이며 local backend를
쓴다. 이 state에는 access key secret이 들어가므로 저장소 밖 mode `0600` 사본으로만
보관한다.

| 경계 | 선언 |
|---|---|
| public access | `BlockPublicAcls`·`IgnorePublicAcls`·`BlockPublicPolicy`·`RestrictPublicBuckets` 모두 true |
| ACL | `BucketOwnerEnforced`로 ACL 경로 자체를 닫음 |
| 전송 구간 | `aws:SecureTransport=false`인 모든 요청 `Deny` |
| 암호화 강제 | SSE 헤더가 있으면서 `AES256`이 아닌 `PutObject` `Deny` (헤더 부재는 `Null` guard로 제외) |
| bucket 삭제 | `prevent_destroy = true` |
| 계정 오적용 | provider `allowed_account_ids` |

전송 identity에 준 권한은 bucket 단위 `ListBucket`·`ListBucketVersions`·
`ListBucketMultipartUploads`·`GetBucketLocation`, object 단위 `PutObject`·`GetObject`·
`GetObjectVersion`·`AbortMultipartUpload`·`ListMultipartUploadParts`, 그리고 topic
하나의 `sns:Publish`와 namespace 하나로 제한한 `cloudwatch:PutMetricData`뿐이다.
삭제와 보호 설정 변경 action에는 명시적 `Deny`를 함께 걸어 나중에 더 넓은 policy가
붙어도 열리지 않게 했다.

`aws:SecureTransport` Deny 문에서 암호화 조건에 `Null` guard를 뺐다면 헤더 없는 정상
업로드까지 거부되어 백업이 조용히 멈춘다. 이 guard는 의도한 것이다.

## host 배치와 비밀 경계

`offsite-backup` 비로그인 system 계정이 두 oneshot unit과 하나의 timer를 실행한다.
계정은 SeaweedFS leaf 인증서를 읽기 위한 `seaweedfs` 보조 그룹만 갖는다. `s3.key`와
`s3.json`은 mode `0600` `seaweedfs` 소유이므로 이 그룹으로도 읽히지 않는다.

| 경로 | 소유·mode | 내용 |
|---|---|---|
| `/etc/offsite-backup/offsite.env` | `root:root` `0600` | 유일한 비밀 원본. systemd가 `EnvironmentFile`로만 읽는다 |
| `/etc/offsite-backup/rclone.conf` | `root:offsite-backup` `0640` | 의도적으로 비어 있다 |
| `/usr/local/bin/offsite-backup.sh` | `root:offsite-backup` `0750` | 전송 실행기 |
| `/usr/local/bin/offsite-backup-alert.sh` | `root:offsite-backup` `0750` | 실패 경보 발행 |
| `/usr/local/bin/aws-sigv4-post.py` | `root:root` `0755` | SigV4 서명 POST |
| `/var/lib/offsite-backup/last-run.log` | `offsite-backup` `0750` 디렉터리 | 경보 본문에 담는 마지막 실행 로그 |

rclone remote는 설정 파일이 아니라 `RCLONE_CONFIG_*` 환경변수로 정의한다. 비밀의 사본을
늘리지 않기 위해서다. 스크립트는 어떤 파일도 셸로 `source` 하지 않는다.

SNS `Publish`와 CloudWatch `PutMetricData` 두 호출 때문에 AWS CLI나 boto3를 설치하지
않았다. 표준 라이브러리만 쓰는 SigV4 서명기로 대신했고 자격증명은 환경변수로만 받는다.
경보 본문은 journal 대신 마지막 실행 로그의 끝부분을 담는다. 경보를 보내려고 이 계정에
전체 journal 읽기 권한을 주지 않기 위해서다.

두 unit은 비-root, 빈 capability set, `NoNewPrivileges`, `ProtectSystem=strict`,
`ProtectProc=invisible`, `SystemCallFilter=@system-service` 등을 선언한다. `IPAddressAllow`로
목적지를 좁히지는 않았다. AWS endpoint 대역이 고정되어 있지 않아 목록이 곧 낡고, 낡은
목록은 조용한 백업 중단이 되기 때문이다.

## 실제 전송·복원 시험

검증 identity 두 개를 로컬 S3에 한시적으로 넣었다. 사본을 만드는 identity에는 검증
bucket 하나의 `Read`·`List`만 주었고, payload를 올리는 producer identity는 시험이 끝난 뒤
제거했다. 전송 job이 쓰는 권한이 읽기 전용임을 그대로 보인다.

| 시험 | 비밀 아닌 결과 |
|---|---|
| 전송 | 객체 3개 25,165,896 bytes, 전부 `Copied (new)` |
| AWS 측 암호화 | 세 객체 모두 `ServerSideEncryption=AES256` |
| prefix 보존 | `nested/deep/path.txt` 경로가 그대로 유지 |
| marker v1 | SHA-256 `26bc2eb2b0dbd398f93bc73dec7060d9bb5e0d18ff5f59741920b7fe39b155c0` |
| marker v2 | SHA-256 `ca659dfd64385b23db598da510e39750859d93d2dcfdc70357cc0374e494c5ec` |
| nested 객체 | SHA-256 `55e4c9ff5ffa172244a5a960c3dbd392caf0735f5b1b8f1fcc5b262e308b91af` |
| 24 MiB 객체 | SHA-256 `becce75e50235ab51a5b3e27ac4b66bfc42f19dbf28d969067ac6b6d1ab956d9` |
| versioning | 같은 key에 version 2개, 최신·이전 모두 조회 성공 |
| 멱등성 | 변경 없이 재실행 시 `0 B / 0 B`, 재업로드 0 |
| multipart | 24 MiB 업로드가 ETag `"...-3"` 3파트로 완료, SSE 유지 |

복원은 **원본 host도 AWS도 아닌 별도 워크스테이션**에서, 전송 전용 최소권한 자격증명만
써서 수행했다. 최신 객체 3개와 marker의 이전 version 1개를 내려받아 업로드 전 기록한
SHA-256과 대조했고 **4개 모두 일치**했다. multipart ETag는 SHA-256으로 취급하지 않고
payload 해시를 직접 비교했다.

## 최소권한 음성 시험

전송 identity로 다음을 시도해 모두 `AccessDenied`를 확인했다.

| 시험 | 결과 |
|---|---|
| `DeleteObject` (최신) | 거부 |
| `DeleteObject` (특정 version) | 거부 |
| 다른 bucket에 `PutObject` | 거부 |
| 다른 bucket 목록 조회 | 거부 |
| `ListAllMyBuckets` | 거부 |
| versioning 중단 시도 | 거부 |
| lifecycle 삭제 시도 | 거부 |
| 다른 SNS topic `Publish` | 거부 |
| 다른 namespace `PutMetricData` | 거부 |
| 평문 HTTP presigned GET | HTTP 403 (같은 URL의 HTTPS는 200) |
| 잘못된 secret | HTTP 403 |

허용된 bucket의 `PutObject`·`GetObject`는 같은 시점에 성공해 양성 통제를 함께 두었다.
timeout이나 connection refused만으로 차단을 단정하지 않고 AWS가 돌려준 오류 코드를 근거로
삼았다.

## 실패 경보 시험

존재하지 않는 원본 bucket을 주입해 실제 실패를 만들었다.

1. `rclone`이 `ListObjects` 403으로 3회 재시도 후 실패했다.
2. 스크립트가 exit 1로 끝났고 unit이 `Result=exit-code`가 되었다.
3. systemd가 `OnFailure=` 의존을 발동해 경보 unit을 실행했다.
4. 경보 unit이 SNS `Publish`에 성공했다. MessageId `b7c9b99a-94ef-5576-8f2c-db7cf32065de`.
5. 정상 설정으로 되돌린 뒤 job이 다시 성공해 회복을 확인했다.

CloudWatch heartbeat alarm은 metric 발행 후 `OK`로 전이했다. 이 alarm은 host나 timer가
죽어 job이 실행조차 되지 않는 경우를 맡는다. `treat_missing_data`를 기본값으로 두면
데이터가 없을 때 영원히 침묵하므로 `breaching`으로 선언했다.

email 구독이 확인된 뒤 같은 시험을 한 번 더 돌려 마지막 구간까지 확인했다. 구독 속성의
`PendingConfirmation`이 `false`가 된 상태에서, 임시 systemd drop-in으로 원본 bucket만
바꿔 job을 실패시켰다. unit은 `ExecMainStatus=78`로 끝났고 `OnFailure=`가 경보 unit을
**새 `InvocationID`로** 실행했으며 MessageId `efded8b2-20d0-579c-b313-ba5450d9b294`가
발행됐다. drop-in을 제거하고 `daemon-reload` 한 뒤 job은 다시 성공했다.

SNS의 `NumberOfNotificationsDelivered`가 같은 창에서 **2, `NumberOfNotificationsFailed`는
0**이었다. 발행 성공만이 아니라 실제 전달까지 확인한 근거다.

drop-in으로 `Environment=`만 덮어쓰는 방법은 통하지 않는다. 유닛의 `EnvironmentFile=`이
같은 key를 다시 덮어써 job이 그대로 성공해 버린다. 실패를 주입하려면 `ExecStart=`를 비우고
다시 선언해야 한다. 경보 unit의 `InvocationID`가 바뀌었는지 보지 않으면 이전 실행의 로그를
새 증거로 착각하기 쉽다.

## 멱등성과 현재 gate

Ansible은 syntax-check, check/diff, 실제 적용을 모두 실행했다. check/diff는
`ok=16 changed=9`, 최초 적용은 `ok=26 changed=15`, 같은 입력의 2회차는
`ok=23 changed=0`이다. 설치된 rclone이 고정 버전인지 role assertion이 확인한다.

`BKP-03` 완료 뒤 `offsite_source_buckets`에는 `bkp-03-postgres`와 `bkp-03-vault`가 들어 있었고,
2026-08-14 `BKP-09`에서 `bkp-01-k3s-datastore`와 `bkp-02-velero`가 추가되어 총 4개 bucket이
오프사이트 동기화 대상으로 확장되었다. `bkp-03-offsite-reader` identity는 네 bucket의 `Read/List`만
가진 최소권한으로 관리된다. 매 실행은 `rclone copy` 뒤 `rclone check --download --one-way`를
수행하며, 2026-08-14 라이브 실행에서 네 source 모두 AWS destination과 byte 차이 0건(postgres 14개,
vault 14개, k3s-datastore 15개, velero 114개)이었고, AWS 측 격리 위치 샘플 복원 검증에서도
SHA-256이 완벽히 일치했다. heartbeat와 성공 metric 경로도 그대로 유지한다.

후속 backup producer를 추가할 때는 다음 두 가지를 함께 넣고 playbook을 다시 적용한다.
하나만 넣으면 job이 403으로 실패하고 경보가 울린다.

1. `offsite_source_buckets`에 로컬 bucket 이름 추가
2. 같은 bucket에 `Read`·`List`만 가진 SeaweedFS identity와 그 credential

## 운영 명령

```bash
# 상태
systemctl list-timers offsite-backup.timer
systemctl status offsite-backup.service
journalctl -u offsite-backup.service -n 100

# 수동 실행
sudo systemctl start offsite-backup.service

# 경보 경로만 점검
sudo systemctl start offsite-backup-alert.service
```

```bash
# 착지점 재적용 (계정 guard가 잘못된 계정을 막는다)
cd infra/aws/tofu
tofu plan  -var-file=<저장소 밖 tfvars>
tofu apply -var-file=<저장소 밖 tfvars>
```

## rollback

이 작업이 만든 것만 대상으로 한다.

- host: `offsite-backup.timer`를 disable·stop 하면 정기 실행이 멈춘다. 원본 데이터는
  건드리지 않는다. 완전히 걷어내려면 두 unit, `/etc/offsite-backup`,
  `/var/lib/offsite-backup`, 세 실행 파일과 `offsite-backup` 계정을 제거한다.
- 로컬 S3: 이 작업은 검증 identity를 넣었다가 제거했다. 최종 `s3.json`은 disabled
  sentinel 하나뿐이며 장기 consumer credential은 0개다.
- AWS: `enable_heartbeat_alarm`을 닫으면 alarm만 사라진다. bucket에는
  `prevent_destroy = true`가 걸려 있어 `tofu destroy`로 지워지지 않는다. 오프사이트
  사본을 실제로 폐기하는 것은 별도 결정이며 사람이 그 줄을 내리고 plan을 본 뒤에만 한다.
- 전송 자격증명을 폐기하려면 IAM access key를 비활성화·삭제하고 `create_backup_access_key`로
  새 key를 만든 뒤 저장소 밖 파일과 `offsite.env`를 갱신한다.

state 원문, access key secret, S3 secret은 기록·Git·일반 log에 넣지 않는다.

## 한계

- 30일 보존 만료는 시간이 지나야 관측된다. 지금은 lifecycle rule의 라이브 선언까지만
  확인했다.
- 재부팅 후 timer 자동 시작은 `enabled` 상태와 `Persistent=true` 선언으로만 확인했다.
  `object-01`은 다른 작업자가 함께 쓸 수 있는 host라 이 작업에서 재부팅하지 않았다.
- 현재 오프사이트 사본은 BKP-01(k3s datastore), BKP-02(Velero), BKP-03(PostgreSQL·Vault) 백업 자산을 포함한다. 전체 플랫폼을
  얼마나 빨리 복구하고 무엇을 잃을 수 있는지는 `BKP-05`의 통합 drill이 답한다.
- AWS 착지점은 단일 region 단일 bucket이다. region 장애나 계정 자체의 상실은 이 구성이
  다루지 않는다.

