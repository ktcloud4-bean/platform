# PostgreSQL·Vault native backup 및 격리 복원 (`BKP-03`)

- 대상: `postgres-01`의 PostgreSQL physical base backup, `k3s-01`의 Vault Raft snapshot
- 로컬 착지점: `object-01`의 BKP-03 전용 SeaweedFS S3 bucket
- 오프사이트 착지점: `BKP-04`가 소유하는 AWS S3 bucket
- 설계 경계: [ADR-0005](../adr/0005-backup-and-offsite-recovery.md),
  [ADR-0006](../adr/0006-vault-seal-and-bootstrap-boundary.md)

## 1. 소유 범위와 금지 경계

`BKP-03`은 두 제품의 native snapshot 생성, 정기 실행, 7세대 보존, S3 round-trip,
격리 복원, freshness 기반 실패 탐지를 소유한다. 주소와 서비스 배치는
[IP 계획](../ip-plan.md)과 [아키텍처](../architecture.md)를 단일 원본으로 사용한다.

다음 경계는 자동화보다 우선한다.

- live PostgreSQL은 `pg_basebackup`의 read 대상이다. 서비스는 재시작하지 않고 backup
  전용 local peer replication rule만 `reload`한다.
- `keycloak` DB와 `keycloak_user`는 조회·백업만 하며 삭제·변경하지 않는다. 검증 marker는
  `verify_db`에만 만들고 검증 후 제거한다.
- live `vault/vault-0`에는 인증된 snapshot GET과 폐기형 KV marker write/delete만 수행한다.
  snapshot restore API를 호출하지 않는다.
- live Vault가 sealed이거나 leader가 아니면 즉시 중단한다. live init·unseal·seal migration은
  이 런북의 범위가 아니다.
- Vault restore는 `bkp-03-vault-restore` namespace의 Service 없는 Pod, loopback listener,
  별도 `emptyDir`, ingress·egress default-deny에서만 수행한다. `platform-root`의
  `targetRevision`과 `gitops/root/kustomization.yaml`은 바꾸지 않는다.
- k3s server와 live Vault Pod를 정지·재시작하지 않는다. SeaweedFS bucket·identity만 바뀌면
  S3 gateway만 재시작한다. 다만 BKP-03용 volume slot 확보를 위해 별도 승인한
  `volume.max=10` 변경은 systemd `Requires` 연쇄로 volume → filer → S3를 재시작한다.
  master는 계속 실행하며 기존 volume을 삭제하거나 `volume.max`를 낮추지 않는다.
- 기존 bucket·identity는 보존한다. 이 작업이 소유하는 이름만 갱신하거나 rollback한다.

## 2. 선언 계약

| 대상 | 전용 identity | 허용 권한 | 정기 실행 | 보존 |
|---|---|---|---|---|
| PostgreSQL producer | `bkp-03-postgres` | 자기 bucket `Read/List/Write` | 매일 02:10, 최대 10분 분산 | 최신 7세대 |
| Vault producer | `bkp-03-vault` | 자기 bucket `Read/List/Write` | 매일 02:40, 최대 10분 분산 | 최신 7세대 |
| BKP-04 reader | `bkp-03-offsite-reader` | 두 bucket `Read/List` | 기존 BKP-04 timer | AWS에는 삭제 없이 사본 추가 |

producer에는 bucket 생성·삭제, 다른 bucket 접근, global admin 권한이 없다. 최초 bucket 생성에만
두 대상 bucket으로 제한한 무작위 bootstrap identity를 메모리에서 만들고, 생성 직후 static
S3 설정에서 제거한다. 장기 자격증명은 저장소 밖 mode `0600` 파일과 각 host의 root-only
systemd `EnvironmentFile`에만 둔다.

공통 실패 경로는 main job의 `OnFailure`와 36시간 freshness timer다. 실패 시 전용 state
directory의 `last-failure`와 journal `daemon.err`에 unit·시각만 기록하며 secret은 기록하지
않는다. 오프사이트 전송 실패는 BKP-04의 SNS·CloudWatch 경보 경로가 이어서 소유한다.

SeaweedFS `volume.max=10`은 기존 default·BKP-01·BKP-02 volume과 BKP-03의 PostgreSQL
archive/manifest, Vault snapshot/manifest용 slot을 함께 보존하는 선언이다. 이미 할당된 volume
ID가 있으면 이 값을 낮추거나 volume을 제거하지 않는다.

## 3. 선언 적용

실제 inventory, 생성된 S3 자격증명, BKP-04 입력은 모두 저장소 밖에 둔다.

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 known_hosts> -o PasswordAuthentication=no"
export BKP03_SECRET_DIR=<저장소 밖 mode-0700 디렉터리>
export BKP03_OFFSITE_VARS_FILE=<BKP-04 mode-0600 offsite-vars.yml>

ansible-playbook -i <저장소 밖 inventory> playbooks/native-backup.yml --syntax-check
ansible-playbook -i <저장소 밖 inventory> playbooks/native-backup.yml --check --diff
# 아래 실제 적용은 대상·영향·rollback 승인 뒤에만 실행한다.
ansible-playbook -i <저장소 밖 inventory> playbooks/native-backup.yml
ansible-playbook -i <저장소 밖 inventory> playbooks/native-backup.yml
```

마지막 재실행은 `changed=0`, `failed=0`이어야 한다. S3 static config 전체와 자격증명 값은
출력하지 않고 identity 이름·action·credential 개수만 구조적으로 확인한다.

Vault snapshot policy와 periodic orphan token은 live Vault가 unsealed leader임을 확인한 뒤
별도 스크립트로 선언한다. root token은 이 일회성 선언에만 stdin으로 쓰며 정기 job에는
저장하지 않는다.

```bash
export VAULT_ROOT_TOKEN_FILE=<저장소 밖 mode-0600 root token 파일>
infra/vault/scripts/configure-bkp03-snapshot.sh
infra/vault/scripts/configure-bkp03-snapshot.sh
```

두 번째 실행은 기존 token의 유효성과 정확한 snapshot capability를 확인하고 재사용해야 한다.

## 4. PostgreSQL backup과 격리 복원

`postgres-native-backup.service`는 전용 비로그인 OS user와 `REPLICATION`만 가진 DB role로
Unix socket에 연결한다. `pg_basebackup --format=plain --wal-method=stream`으로 실행 중인
전체 cluster의 일관된 physical snapshot을 만들고 `pg_verifybackup`으로 manifest를 검증한다.
그 뒤 tar archive와 SHA-256 manifest를 전용 S3 bucket에 올리고 다시 다운로드해 digest를
대조한다.

격리 복원 검증은 root가 다음 wrapper 하나를 실행한다.

```bash
ssh <postgres-01> sudo /usr/local/sbin/postgres-native-restore-verify
```

wrapper는 다음 순서를 강제한다.

1. `verify_db`에 무작위 marker를 만들고 SHA-256만 state에 기록한다.
2. physical backup과 S3 round-trip을 실행한 뒤 live marker table을 삭제한다.
3. archive를 새 임시 PGDATA로 풀고 `postgres-backup` user로 별도 cluster를 시작한다.
4. `listen_addresses=''`, 전용 Unix socket, 폐기형 port만 사용하며 TCP listener 0을 확인한다.
5. 복원본 marker SHA-256 일치와 `keycloak_user` 존재를 확인한다.
6. 격리 cluster를 정상 종료하고 임시 PGDATA·socket·marker를 제거한다.
7. live `keycloak` DB/role 구조 hash가 검증 전후 같음을 확인한다.

restore worker는 라이브 PGDATA를 경로나 설정 대상으로 받지 않는다. 복원 실패 시 merge하지
않고 임시 cluster를 종료·제거한 뒤 원인을 보고한다.

## 5. Vault snapshot과 격리 복원

`vault-raft-backup.service`는 `sys/storage/raft/snapshot` read, 자기 token 조회·갱신만 가진
periodic token으로 TLS를 검증해 snapshot API를 호출한다. snapshot과 SHA-256 manifest를
전용 S3 bucket에 올리고 다시 내려받아 digest를 대조한다.

격리 restore에는 live cluster의 원래 Shamir unseal key 중 threshold 3개가 필요하다. 값을
채팅·명령 인자·환경변수에 넣지 않고, 저장소 밖 mode `0600` 파일에 한 줄에 하나씩 둔다.
다음 실행은 사용자의 restore 승인과 key 파일 준비 뒤에만 수행한다.

```bash
export VAULT_ROOT_TOKEN_FILE=<저장소 밖 mode-0600 root token 파일>
export VAULT_UNSEAL_KEYS_FILE=<저장소 밖 mode-0600 원본 key 파일>
infra/vault/scripts/verify-bkp03-isolated-restore.sh
```

스크립트는 restore endpoint의 방향을 세 겹으로 고정한다.

1. 고정 namespace가 이미 있으면 소유권을 판정하지 않고 중단한다.
2. restore Pod는 Service·ServiceAccount token·egress가 없고 listener는 loopback뿐이다.
3. snapshot-force URL은 그 Pod의 API-server port-forward에 연결된 `127.0.0.1`로만 구성한다.

live Vault에 무작위 KV marker를 넣어 snapshot을 만든 뒤 곧바로 live marker metadata를
삭제한다. 격리 인스턴스를 임시 init·unseal하고 snapshot-force한 뒤 원본 key 3개를 요청
본문으로만 전달해 연다. 복원본에서 marker SHA-256, Kubernetes auth role의 고정 필드,
`keycloak` policy, KV·auth mount를 실제 조회해 원본 hash와 대조한다. 검증 shell은
`set -eu`로 조회 실패를 즉시 전파하고, 요청마다 달라지는 API 응답 필드는 hash에서 제외한다.
결과는 controller의 root-only report에 SHA-256과 격리 조건만 남긴다. 끝나면 namespace,
port-forward, snapshot 입력, 임시 init 출력과 curl 설정을 제거하고 live marker 부재를 확인한다.

## 6. 실패 탐지 시험

각 제품의 정상 backup 뒤 `last-success.epoch`를 안전하게 보관하고 과거 값으로 바꿔 freshness
service를 한 번 실패시킨다. 다음을 모두 확인한 뒤 원래 epoch를 복원해 health를 재성공시킨다.

- health service `Result=exit-code`
- 대응 failure template의 새 `InvocationID`
- `last-failure`에는 unit·UTC 시각만 존재
- secret 문자열은 journal과 state log에 0건
- 정상 복구 뒤 main job과 health service가 모두 성공

검증을 위해 producer의 자격증명을 잘못 바꾸거나 live Vault를 seal하거나 PostgreSQL을
중단하지 않는다.

## 7. 2026-08-01 라이브 검증 증거

최신 `origin/main` rebase 뒤 전체 선언과 복원을 다시 실행한 최종 증거다.

- PostgreSQL: S3에서 내려받은 physical archive의 `pg_verifybackup`을 통과했고,
  archive SHA-256은 `6988b3c67eaf232e790fdc8cb5df598c9c9db5539d1c4762f016aadee53e2050`,
  `verify_db` marker SHA-256은 `a16e36c7442722e6f9ec585b20e2b11525d4115ca11522d595b90f1e9009ada9`으로
  live와 격리 cluster가 일치했다. 복원본의 `keycloak_user`는 1개, TCP listener는 0개였고
  live Keycloak DB·role 구조 SHA-256은 검증 전후
  `50ecb652acb1848f7ae061c3b300692c686fab8836a64cca189c4765c7981a2a`로 같았다.
- Vault: snapshot-force 대상은 격리 Pod의 loopback뿐이었고, 복원본의 KV marker
  `fd9035cd80cda74b8c6e70dfa79a8b8d575dcc8832212a9116f8b47c0fb2f85a`, Kubernetes auth role
  `4dbf02f0a57216ac5c7fc5ec99d13f3aee76fbf15178c3126519cb2246f3a557`, `keycloak` policy
  `c7c41dcb4339639fa86699a50d9c482bfede539b977bf3de3170d27f7227526a`가 live hash와 일치했다.
  snapshot SHA-256은 `ad1c4418c1eb4ce300015bf9df78f798eb577f7293288bbb5eb845f537137d25`였다.
  Service와 ServiceAccount token mount는 각각 0개였고 종료 뒤 namespace·listener·port-forward·
  restore input도 모두 0개였다. snapshot policy를 가진 periodic orphan token은 정확히 1개다.
- 두 producer의 상대 bucket List/Write는 거부됐고, 각 bucket의 archive/snapshot과 sidecar는
  7세대였다. 8번째 생성을 통해 가장 오래된 세대가 실제 삭제됨을 확인했다.
- BKP-04 전송은 두 source에 `rclone check --download --one-way`를 실행해 차이 0건을
  확인했다. freshness 실패 주입은 PostgreSQL
  `006b41d41b1e4bfaa198ad399c17b31a`, Vault
  `5c435c595a1f40039d2f34c32c177b80`의 새 failure `InvocationID`를 만들었고, 정상 main/health
  성공 뒤 `last-failure`는 모두 제거됐다.
- 전체 Ansible 재실행은 `localhost 6`, `object-01 53`, `postgres-01 34`, `k3s-01 34` task에서
  모두 `changed=0`, `failed=0`이었다. 두 backup timer와 freshness timer는 enabled·active다.
- 검증 중 orchestration 출력에 당시 root token 원문이 한 번 노출된 사고가 있었다. 즉시 새
  root token을 생성해 저장소 밖 mode `0600` 파일을 원자적으로 교체하고, 구 token accessor와
  중복 snapshot token을 revoke해 구 token 거부와 유효 snapshot token 1개를 확인했다.
  최종 secret scan 명령의 파이프 범위 오류로 당시 PostgreSQL S3 secret key도 orchestration
  출력에 한 번 노출됐다. 사용자 승인 뒤 `bkp-03-postgres` credential pair를 새로 발급해 S3
  gateway와 PostgreSQL EnvironmentFile에 적용했고, 구 pair의 자기 bucket 접근 거부와 새 pair의
  자기 bucket 성공·Vault bucket 거부를 같은 시점에 확인했다. 구 credential 격리 파일은 제거했다.
  현재 유효한 token·secret key·unseal key 원문은 Git과 대상 host journal/state log에서 0건이다.
  비밀이 아닌 PostgreSQL access-key 식별자는 교차 권한 음성 시험의 SeaweedFS journal에 6회
  남았고, 대응 secret key 일치는 0건이다.
- SeaweedFS는 승인된 `volume.max=10`과 연쇄 재시작 뒤 master·volume·filer·S3가 모두 active이고,
  기존 volume ID `1`, `10`~`18`을 보존했다. live Vault는 unsealed Raft leader, Node는 Ready,
  Argo Application은 7/7 `Synced/Healthy`, `platform-root`는 계속 `targetRevision: main`이다.
  credential 교체 때는 S3 gateway만 재시작했고 master·volume·filer는 재시작하지 않았다.
  live restore는 호출하지 않았다.

## 8. 완료·정리 판정

- 두 producer가 자기 bucket에서는 upload/download에 성공하고 상대 bucket read/write는
  S3 API에서 거부된다.
- PostgreSQL 복원 marker SHA-256, Vault 복원 marker·auth·policy SHA-256이 일치한다.
- 두 timer와 두 freshness timer가 enabled·active이고 마지막 job이 성공한다.
- BKP-04 job이 두 bucket을 AWS prefix로 복사하고 양쪽 object 본문을 byte 단위로 대조한다.
- `bkp-03-vault-restore` namespace, 임시 PGDATA·socket·marker, bootstrap identity,
  restore input, 임시 자격증명은 모두 부재다.
- 기존 S3 identity·bucket, live `keycloak` DB/role, live Vault 상태, k3s Node/Argo 상태는
  검증 전후 불변이다.
- tracked Git 파일과 대상 host journal/state log에서 **현재 유효한 비밀 값**인 token·secret
  key·unseal key 원문은 0건이어야 한다. access-key 식별자는 secret key와 구분한다. 과거 노출
  사고는 삭제해 숨기지 않고 폐기·교체 증거와 함께 기록한다.

## 9. rollback

적용 전 확보한 현재 S3 config를 기준으로 **BKP-03이 소유한 이름만** 되돌린다.

1. `postgres-native-backup*`, `vault-raft-backup*` timer를 disable하고 exact unit·script·config·
   state/cache를 제거한다.
2. PostgreSQL의 `bkp03_backup` role, 전용 `pg_ident.conf`/`pg_hba.conf` line만 제거하고 reload한다.
   PostgreSQL service 재시작, live PGDATA 삭제, `keycloak` 객체 변경은 금지한다.
3. Vault의 `bkp-03-snapshot` token을 accessor로 revoke하고 policy만 삭제한다. live snapshot
   restore, seal, Pod 재시작은 금지한다.
4. `bkp-03-postgres`, `bkp-03-vault`, `bkp-03-offsite-reader` identity와 두 전용 bucket만
   제거한다. bucket 삭제는 object가 없음을 확인하고 별도 승인한 경우에만 한다.
5. `object-01`의 BKP-03 S3 source drop-in만 제거하고 S3 gateway를 재시작한다. 이미 할당된
   volume ID 15~18은 삭제하지 않고 `volume.max=10`도 낮추지 않는다. 기존 identity·bucket과
   master·volume·filer는 보존한다.

병합 후 결함은 공개된 `main`을 다시 쓰지 않고 별도 FIX 작업으로 보정한다.
