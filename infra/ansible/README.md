# Ansible 공통 Baseline (`infra/ansible`)

이 디렉터리는 Proxmox cloud-init template 기반으로 생성되는 모든 Rocky Linux 9 VM에 적용되는 공통 baseline 플레이북과 구성을 소유한다.

- 검증일: 2026-07-31 (`VM-01`에서 실제 VM 5대에 적용·재부팅 후 멱등성 확인)
- 상태: `DONE` (작업 `OS-01`, `VM-01`에서 보정)

## 소유 범위 및 항목

- **cloud-init 및 qemu-guest-agent**: 게스트 에이전트 및 cloud-init 패키지 설치·활성화
- **시간대**: `/etc/localtime` 심볼릭 링크를 `system_timezone`으로 선언
- **시간 동기화**: `chronyd` 활성화와 VLAN gateway NTP source 배치
- **패키지 저장소**: 공식 Rocky Linux 9 저장소 (`baseos`, `appstream`) 접근·활성 상태 검증
- **SSH 접속**: cloud-init을 통해 주입된 `rocky` 사용자 SSH 공개키 기반 접속 및 authorized_keys 검증
- **Swap 비활성화**: 게스트 swap 비활성화 (`swapoff -a` 및 `/etc/fstab` 주석 처리) - k3s 요구사항 및 `capacity-plan.md` 준수
- **시스템 상태**: `systemctl --failed`로 실패한 systemd 유닛 0개 확인

서비스별 방화벽, Kubernetes, PostgreSQL, S3 오브젝트 저장소 등의 특정 설정이나 임의의 자동 업데이트/CIS hardening은 이 공통 baseline에 넣지 않는다.

## k3s 단일 노드 기준선

`playbooks/k3s-baseline.yml`과 `roles/k3s_baseline/`은 `K3S-01`의 단일 server
k3s bootstrap을 소유한다. `update.k3s.io`의 `stable` 채널이 가리킨 실제 버전을
defaults에 정확히 고정하고, 공식 release binary SHA-256과 고정 commit의 install
script SHA-256을 검증한다. RHEL 계열은 Rancher GPG key로 검증하는
`k3s-selinux` 정책을 설치하며 SELinux enforcing을 유지한다.

이미 설치된 `k3s-selinux`는 정확한 NEVRA를 먼저 검증한다. `k3s-selinux`와
`container-selinux`가 모두 있으면 DNF를 다시 실행하지 않아, 멱등 실행이 외부
mirror metadata 갱신에 불필요하게 의존하지 않는다.

설정 파일은 SQLite 기본 datastore와 CoreDNS·Traefik·ServiceLB·local-path·
metrics-server 기본 구성을 그대로 둔다. node 주소, advertise 주소와 Pod/Service
CIDR는 저장소에 고정하지 않는다. kubeconfig와 server token은 게스트 밖으로
복사하거나 출력하지 않고 존재·경로·mode만 확인한다.

`STOR-01`부터 local-path 자체는 유지하되 k3s가 시작 때 되쓰는 packaged
`local-storage` AddOn은 비활성화하고, 동일한 provisioner 버전과 기본 StorageClass를
role 소유 manifest로 선언한다. StorageClass는 `defaultVolumeType: local`을 쓰며,
SELinux helper 전용 type은 다른 Pod의 MCS category로 재라벨된 대상만 정리할 수 있게
한다. helper는 privileged가 아니고 capability 전체 drop, 권한 상승 금지, read-only
root filesystem, RuntimeDefault seccomp, token 미마운트와 template의 임의 hostPath 금지를
함께 적용한다.

실제 inventory는 저장소 밖 mode `0600` 파일을 사용한다. 첫 적용 전에는 반드시
K3S-01 설치 승인 gate를 통과해야 한다.

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 known_hosts> -o PasswordAuthentication=no"
ansible-playbook -i <저장소 밖 inventory> playbooks/k3s-baseline.yml --syntax-check
ansible-playbook -i <저장소 밖 inventory> playbooks/k3s-baseline.yml --check --diff
# 명시적 승인 뒤에만 실제 적용
ansible-playbook -i <저장소 밖 inventory> playbooks/k3s-baseline.yml
```

설치 기준선은
[`docs/runbook/k3s-single-node-baseline.md`](../../docs/runbook/k3s-single-node-baseline.md),
local PV·capacity·SELinux helper의 적용·검증·rollback은
[`docs/runbook/k3s-local-path-storage.md`](../../docs/runbook/k3s-local-path-storage.md)가
소유한다.

## k3s SQLite datastore·server token backup

`playbooks/k3s-datastore-backup.yml`과 `roles/k3s_datastore_backup/`은 `BKP-01`의
전용 보호 계층을 소유한다. 실행 중 SQLite는 Python이 노출하는 SQLite Online Backup
API로 일관 사본을 만들고 source와 사본 모두 `quick_check=ok`인지 확인한다. server token과
선택한 API object proof를 같은 tar stream에 넣되 plaintext tar는 만들지 않고 저장소 밖
recovery GPG public key로 즉시 암호화한다.

전용 SeaweedFS bucket에는 `Read/List/Write`만 가진 전용 identity를 사용한다. bucket 생성용
`Admin` identity는 생성·versioning 직후 제거하며 기존 BKP-02 identity를 renderer 입력에서
명시적으로 보존한다. runtime credential은 root `0600`, public certificate/key는 비밀이
아니지만 일반 diff 출력을 막는다. role 적용이나 backup은 라이브 k3s를 stop/restart하지 않는다.

격리 복원 VM staging과 token 없는 음성 시험, API object 복원, Velero 경계, 임시 VM 정리는
[`BKP-01 runbook`](../../docs/runbook/k3s-sqlite-datastore-backup-restore.md)이 소유한다.

## Warpgate 특권 세션 기준선

`playbooks/warpgate-baseline.yml`과 `roles/warpgate_baseline/`은 `WG-01`의 Warpgate
배포와 `WG-02`의 Keycloak SSO·역할·세션·전용 DNS-01 인증서를 소유한다.
작업 시점의 최신 안정 릴리스를 정확히 고정하고 GitHub Release asset
digest 의 SHA-256 을 `get_url`의 `checksum`으로 강제한다. 같은 릴리스의 CycloneDX SBOM 도
checksum 검증 후 게스트에 보관한다. `floating latest`나 `curl | sh`는 쓰지 않는다.

전용 system 계정 `warpgate`로 비-root 실행하고, 바이너리는 기본 file context 가 `bin_t`인
`/usr/local/bin`에 두어 `semanage` 규칙 없이 올바른 SELinux label 을 얻는다. 데이터는
`/var/lib/warpgate` `0700`, 설정은 `/etc/warpgate.yaml` `0600`이다. systemd unit 에는
`ProtectSystem=strict`, 빈 `CapabilityBoundingSet`, `SystemCallFilter` 등을 적용한다.

Warpgate 는 role·target·user·SSO credential을 설정 파일이 아니라 제품 DB 에 둔다.
`provision.yml`이 loopback 관리 API 로 `warpgate_roles`·`warpgate_targets`·
`warpgate_users`·`warpgate_known_hosts` 선언을 반영하며 각 항목은
`state: present|absent`를 가진다. WG-02의 두 SSO role과 두 사전등록 사용자는 기본
선언이고, target·known-host와 비밀번호는 승인된 운영 대상에 맞춰 저장소 밖에서 주입한다.

로컬 break-glass 관리자 비밀번호(`warpgate_admin_password`), Keycloak client secret·
단기 Admin bearer token, Warpgate 전용 Cloudflare token은 저장소에 두지 않는다.
role은 길이와 주입 여부를 먼저 확인하고 secret 처리 task를 `no_log`로 실행한다.

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 known_hosts> -o PasswordAuthentication=no"
ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 secrets.yml>" playbooks/warpgate-baseline.yml --syntax-check
ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 secrets.yml>" playbooks/warpgate-baseline.yml --check --diff
# 명시적 승인 뒤에만 실제 적용
ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 secrets.yml>" playbooks/warpgate-baseline.yml
```

버전 선정 근거와 기준선 복구는
[`docs/runbook/warpgate-privileged-access.md`](../../docs/runbook/warpgate-privileged-access.md),
SSO·역할·인증서·IdP 장애 검증은
[`docs/runbook/warpgate-keycloak-sso.md`](../../docs/runbook/warpgate-keycloak-sso.md)가
소유한다.

## SeaweedFS 로컬 S3 기준선

`playbooks/seaweedfs-s3.yml`과 `roles/seaweedfs_s3/`은 `S3-01`의 단일 DATA VM
SeaweedFS를 소유한다. 운영 선언은 `weed mini`가 아니라 master·volume server·filer·TLS
S3 gateway 네 systemd unit이다. master metadata, volume data, filer metadata는 각각
`/var/lib/seaweedfs/master`, `/var/lib/seaweedfs/volume`, `/var/lib/seaweedfs/filer`에
분리해 영속화한다.

SeaweedFS 4.40 `linux_amd64.tar.gz`와 Apache-2.0 license 원문은 모두 SHA-256을
강제한다. 서비스는 비로그인 `seaweedfs` 계정으로 실행하며, master·volume·filer의
관리 endpoint는 loopback에만 bind한다. S3만 DATA 주소 TCP 8333에서 TLS를 제공하고,
systemd `IPAddressAllow`와 OPNsense 규칙이 검증한 소비자 `/32`만 허용한다.

S3 credential과 bucket별 action은 저장소 밖 mode `0600` extra-vars로만 넣는다. 기본
identity 목록이 비어도 SeaweedFS가 allow-all로 동작하지 않도록 disabled sentinel
identity를 생성한다. 장기 consumer credential은 소비자가 생길 때까지 만들지 않는다.
TLS private key는 guest에서 생성되어 `/etc/seaweedfs/tls/s3.key` mode `0600`에만 있고,
bootstrap leaf는 `object-01`·`s3` SAN과 DATA IP를 가진 CA:FALSE 인증서다. OPNsense
private key를 복사하지 않는다.

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 인증된 known_hosts> -o PasswordAuthentication=no"
ansible-playbook -i <저장소 밖 inventory> playbooks/seaweedfs-s3.yml --syntax-check
ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 s3-identities.yml>" playbooks/seaweedfs-s3.yml --check --diff
# 명시적 승인 뒤에만 실제 적용
ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 s3-identities.yml>" playbooks/seaweedfs-s3.yml
```

고정 입력, TLS·DNS·방화벽 경계, S3 호환성 시험, 재부팅·정리와 rollback은
[`docs/runbook/seaweedfs-s3.md`](../../docs/runbook/seaweedfs-s3.md)가 소유한다.

## SeaweedFS 오프사이트 사본

`playbooks/seaweedfs-offsite-backup.yml`과 `roles/seaweedfs_offsite_backup/`은 `BKP-04`의
AWS S3 오프사이트 경로를 소유한다. 전송은 같은 host에서 밖으로 미는 방식이라 8333용
신규 방화벽 규칙 없이 outbound 443만 쓴다. 착지점 자원은 `infra/aws/tofu`가 소유하고
이 role은 그 output을 입력으로 받는다.

rclone 1.74.4 `linux-amd64.zip`과 MIT license 원문 모두 SHA-256을 강제한다. 전송은
`rclone copy` 전용이며 `sync`나 `--delete-*`를 쓰지 않는다. 규칙만으로 두지 않고 AWS IAM
policy에 삭제 action을 넣지 않아 권한으로도 막고, `offsite_allow_delete`가 참이면 role이
적용을 거부한다.

비밀은 `/etc/offsite-backup/offsite.env` mode `0600` 한 곳에만 둔다. rclone remote도
설정 파일이 아니라 이 파일의 `RCLONE_CONFIG_*` 환경변수로 정의해 사본을 늘리지 않는다.
스크립트는 어떤 파일도 셸로 `source` 하지 않고, systemd가 `EnvironmentFile`로만 읽는다.
SNS·CloudWatch 두 호출 때문에 AWS CLI나 boto3를 설치하지 않고 표준 라이브러리만 쓰는
SigV4 서명기를 둔다.

`offsite_source_buckets`가 비어 있어도 timer는 매일 돌며 heartbeat object를 써서 AWS
자격증명·네트워크·쓰기 권한을 실제로 사용한다. 첫 실제 백업 날에야 권한 만료나 경로
단절을 발견하는 것을 막는 canary다. 백업 생산자가 생기면 bucket 이름과 그 bucket에
`Read`·`List`만 가진 SeaweedFS identity를 **함께** 넣는다.

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 인증된 known_hosts> -o PasswordAuthentication=no"
ansible-playbook -i <저장소 밖 inventory> playbooks/seaweedfs-offsite-backup.yml --syntax-check
ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 offsite-vars.yml>" playbooks/seaweedfs-offsite-backup.yml --check --diff
# 명시적 승인 뒤에만 실제 적용
ansible-playbook -i <저장소 밖 inventory> -e "@<저장소 밖 offsite-vars.yml>" playbooks/seaweedfs-offsite-backup.yml
```

전송 계약, 최소권한 음성 시험, 복원 대조와 실패 경보 증거는
[`docs/runbook/seaweedfs-s3-offsite-backup.md`](../../docs/runbook/seaweedfs-s3-offsite-backup.md)가
소유한다.

## PostgreSQL·Vault native backup

`playbooks/native-backup.yml`과 `roles/bkp03_*`, `roles/postgres_native_backup`,
`roles/vault_raft_backup`은 `BKP-03`의 정기 native snapshot을 소유한다. PostgreSQL은
전용 local peer replication role로 `pg_basebackup`과 `pg_verifybackup`을 실행하고,
Vault는 별도 periodic token의 인증된 Raft snapshot API만 사용한다. 두 producer는 서로
다른 SeaweedFS S3 identity·bucket을 가지며 최신 7세대만 유지한다. BKP-04 reader는 두
bucket의 `Read/List`만 받아 기존 AWS 오프사이트 경로로 전달하고,
`rclone check --download --one-way`로 source와 destination의 object bytes를 대조한다.

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 인증된 known_hosts> -o PasswordAuthentication=no"
export BKP03_SECRET_DIR=<저장소 밖 mode-0700 디렉터리>
export BKP03_OFFSITE_VARS_FILE=<BKP-04 mode-0600 offsite-vars.yml>
ansible-playbook -i <저장소 밖 inventory> playbooks/native-backup.yml --syntax-check
ansible-playbook -i <저장소 밖 inventory> playbooks/native-backup.yml --check --diff
# 명시적 승인 뒤에만 실제 적용
ansible-playbook -i <저장소 밖 inventory> playbooks/native-backup.yml
```

live Vault에는 restore API를 호출하지 않는다. PostgreSQL 별도 cluster와 Service 없는
Vault 격리 Pod에서만 복원하고, 상세 승인 gate·검증·정리·rollback은
[`docs/runbook/postgres-vault-native-backup.md`](../../docs/runbook/postgres-vault-native-backup.md)가
소유한다.

BKP-03 volume slot을 위해 승인된 `seaweedfs_volume_max_count: 10` 변경은 systemd 의존성에
따라 volume → filer → S3를 연쇄 재시작한다. master와 기존 volume은 유지하며 이미 volume이
할당된 뒤에는 max를 낮추거나 volume을 삭제하지 않는다.

REG-01은 `30GB` volume 5개까지 Harbor collection에 열어 두도록 별도 승인 뒤 max를 `15`로
올린다. `playbooks/harbor-seaweedfs-capacity.yml`은 전체 identity 선언을 요구하지 않고 정확히
이 값만 바꾸며 volume → filer → S3만 한 차례 재시작한다.

## Wazuh HIDS agent 기준선

`playbooks/wazuh-agent-baseline.yml`과 `roles/wazuh_agent_baseline/`은 `WAZUH-03`의
6개 대상(`k3s-01`·`postgres-01`·`object-01`·`warpgate-01`·`netbird-01`·`proxmox-01`)
Wazuh agent를 소유한다. 기존 manager·indexer·dashboard와 같은 4.14.7 계열로
버전을 고정하고, RPM(Rocky 9 5대)은 `get_url` checksum과 Wazuh 공식 GPG 서명
(key ID `96B3EE5F29111145`) 둘 다로 검증한다. `proxmox-01`(Debian 13 물리 호스트)의
DEB는 낱개 파일에 내장 서명이 없어 다른 role의 GitHub Release 자산과 같은 신뢰
모델(TLS+공식 도메인 sha256)만 적용한다.

이 role이 켜는 모듈은 `syscheck`(최소 경로)·`rootcheck`뿐이다. `templates/ossec.conf.j2`가
전체 `ossec.conf`를 갈아 끼우며 `syscollector`·SCA(Security Configuration
Assessment) wodle·`osquery`·`cis-cat`·`localfile`·`active_response`·command
wodle을 아예 선언하지 않아 비활성 상태를 유지한다. `localfile`(로그 수집)이 없는
이유는 `LOKI-02`가 같은 6개 호스트의 journald/syslog를 별도로 수집하기 때문이며,
인증 성공/실패 이벤트가 두 경로에 중복되지 않게 소스별로 정확히 한쪽에만 보낸다.

`syscheck` 감시 경로는 설정·SSH·systemd unit·인증서 관련 디렉터리로 최소화한다.
공통 경로(`/etc/ssh`, `/etc/sudoers`, `/etc/sudoers.d`, `/etc/systemd/system`)에
OS 계열 신뢰 저장소(RedHat `/etc/pki/tls`·`/etc/pki/ca-trust/source/anchors`, Debian
`/etc/ssl`)와 대상별 `wazuh_agent_extra_syscheck_directories`(inventory
host_vars)를 더한다. PGDATA 전체·session recording·컨테이너 이미지처럼 상시
변경되는 디렉터리는 절대 통째로 넣지 않는다 — `postgres-01`은 `postgres_data_dir`
전체가 아니라 `postgresql.conf`·`pg_hba.conf`·server CA/leaf 인증서 파일 6개만
개별 지정한다. `realtime="no"`(예약 스캔)만 쓰고 `report_changes="no"`로 변경
diff 원문을 저장하지 않는다(대상에 private key 파일이 섞여 있다).

manager 등록은 `<client><enrollment>`를 끄고(비밀번호를 `ossec.conf`에 남기지
않는다) `agent-auth` CLI를 `client.keys`가 비어 있을 때만 1회 실행하는 방식이다.
`wazuh_agent_authd_password`는 `WAZUH-01` `provision.sh`가 이미 만든 저장소 밖
`${KTC_SECRET_ROOT}/wazuh/authd-password`(Vault `kv/wazuh/manager`의
`authd_password`와 동일 값)를 재사용하며 새 credential을 만들지 않는다. agent가
연결하는 주소·포트는 OPNsense agent와 동일한 기존 manager NodePort
`10.10.20.10:31514`(event)·`31515`(등록)이다.

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 known_hosts> -o PasswordAuthentication=no"
ansible-playbook -i inventory/hosts.local playbooks/wazuh-agent-baseline.yml --syntax-check
ansible-playbook -i inventory/hosts.local -e "wazuh_agent_authd_password=$(cat <secret_root>/wazuh/authd-password)" \
  playbooks/wazuh-agent-baseline.yml --check --diff
# 명시적 승인 뒤에만 실제 적용
ansible-playbook -i inventory/hosts.local -e "wazuh_agent_authd_password=$(cat <secret_root>/wazuh/authd-password)" \
  playbooks/wazuh-agent-baseline.yml
```

OPNsense 기존 `os-wazuh-agent`(Suricata `eve.json`만 켜져 있던 상태)의
`syscheck`·`rootcheck` 확장은 `gitops/tools/wazuh-01/apply-opnsense.sh`가
소유하며, manager로 향하는 NetworkPolicy 확장은 `gitops/apps/wazuh/network-policies.yaml`,
cross-VLAN 방화벽 규칙은 `infra/opnsense/`가 소유한다.

### WAZUH-04 Warpgate 감사 로그(journald)

`wazuh_agent_localfile_journald_unit`(기본값 빈 문자열, `warpgate-01`만
`warpgate.service`로 설정)이 있는 대상만 `<localfile log_format="journald">`
하나를 더 갖는다. 나머지 5대는 여전히 localfile 0건이다. Warpgate가 journald에
남기는 `_type="UserAuthenticated1"` 등 감사 event를 manager의
`wazuh-04-warpgate-audit` decoder(`gitops/apps/wazuh/files/wazuh-04-decoders.xml`)가
처리한다. `LOKI-02`가 다룰 host O7(`sshd`·`sudo`·systemd 실패·kernel)과는
겹치지 않는다 — 이 unit 필터는 `warpgate.service` 하나로만 좁힌다.

### WAZUH-05 NetBird 감사 event(`events.db` polling)

NetBird 감사 기록은 로그 파일이 아니라 `netbird-01`의 SQLite `/var/lib/netbird/events.db`다.
`netbird_audit_relay` 역할(`playbooks/netbird-audit-relay.yml`, `netbird_server` 그룹)이
전용 non-root system user(`wazuh05-relay`)를 만들고 `events.db`에 그 user 하나에만
read-only POSIX ACL(`setfacl -m u:wazuh05-relay:r`)을 부여한 뒤, `netbird-audit-relay.timer`
(60초 간격)가 `roles/netbird_audit_relay/files/netbird-audit-relay.py`를 반복 실행한다.
스크립트는 `events.db`를 URI `mode=ro`로만 열어 마지막 처리 row id 이후 새 row만 읽고,
`docs/audit-event-standard.md` 4절 표에 정의된 "account·user·peer·policy·setup-key 변경과
접근 event" 범위 밖(route·DNS·network·service·integration·posture check 등)은 activity
코드 allowlist에서 걸러 아예 전송하지 않는다. `meta`도 allowlist 방식이라 `name`·`fqdn`·`ip`·
`ipv6`·`group`·`group_id`·`type`·`is_service_user`·`pending_approval`·`created_at`만
통과하고, setup key 값(`key`)·geo/city(`location_*`)·이메일·표시명은 항상 제거한다(6절).
출력은 `/var/lib/wazuh-05-netbird-relay/netbird-audit.log`(JSON 한 줄) — `wazuh_agent_baseline`의
`wazuh_agent_localfile_json_path`가 이 파일을 `<localfile log_format="json">`으로 tail한다.
systemd 서비스는 `PrivateNetwork=true`를 포함한 전면 hardening 아래 순수 로컬 파일 I/O만
한다(네트워크 접근 자체가 없다). 상태 파일(마지막 처리 row id)은 tmp write 후 rename으로
원자적으로 갱신해 재시작 뒤에도 중복·누락 없이 이어 읽는다.

## NTP source

`NET-03`은 각 project VLAN에서 **해당 VLAN gateway의 UDP 123만** 허용한다. Rocky 기본 설정의 공개 pool은 차단되므로 그대로 두면 게스트가 영원히 동기화되지 않는다.

baseline은 `/etc/chrony.conf`에 `sourcedir`를 보장하고, 공개 `pool` 줄을 주석 처리한 뒤, `chrony_sources_dir`에 gateway 하나만 담은 `.sources` 파일을 둔다.

주소는 이 저장소에 고정하지 않는다. `chrony_ntp_server`의 기본값이 게스트의 실제 default route gateway(`ansible_default_ipv4.gateway`)이며, 필요하면 저장소 밖 inventory에서 덮어쓴다. 주소의 단일 원본은 [`docs/ip-plan.md`](../../docs/ip-plan.md)다.

성공 판정은 `chronyc sources`에서 gateway가 `^*`로 선택되고, `chronyc tracking`의 Stratum이 0이 아니며 Leap status가 `Normal`, `timedatectl`의 `NTPSynchronized=yes`인 상태다.

## host key 검증

`ansible.cfg`의 `host_key_checking`은 `True`다. `False`는 SSH host key 검증을 완전히 끄며, 위조된 key로도 접속이 성공한다.

게스트 host key는 인증된 경로(Proxmox 직렬 콘솔 또는 QGA)로 확인해 저장소 밖 `known_hosts`에 넣고, 실행할 때 지정한다. `ssh-keyscan`이나 `accept-new`만으로 신뢰를 확정하지 않는다.

```bash
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<저장소 밖 known_hosts> -o PasswordAuthentication=no"
```

검증이 실제로 강제되는지 확인할 때는 SSH 연결 다중화를 꺼야 한다. 켜져 있으면 기존 control socket을 재사용해 host key 검증을 건너뛴다.

## check mode

읽기 전용 조회 태스크에는 `check_mode: false`가 있다. `ansible.builtin.command`는 check mode를 지원하지 않아 조회가 skip되고, 그 결과를 참조하는 `assert`가 빈 변수를 보고 실패하기 때문이다. `--check`가 실패하는 role은 적용 승인의 근거가 될 수 없다.

같은 이유로 timezone은 `timedatectl set-timezone` 대신 `/etc/localtime` 심볼릭 링크로 선언한다. 그 명령은 polkit의 `auth_admin_keep`을 지나므로 인증 agent가 없는 비대화형 sudo에서 `Access denied`로 실패하기도 한다.

## 파일 구조

```text
infra/ansible/
├── ansible.cfg              # 기본 설정 (host_key_checking, remote_user 등)
├── inventory/
│   └── hosts.example        # 비밀 없는 인벤토리 예시 (Git 추적)
├── playbooks/
│   ├── baseline.yml         # 공통 baseline 엔트리 플레이북
│   ├── bkp-01-restore-stage.yml # BKP-01 임시 VM staging·격리 도구
│   ├── k3s-datastore-backup.yml # BKP-01 온라인 datastore/token backup
│   ├── k3s-baseline.yml     # K3S-01 단일 server 엔트리 플레이북
│   ├── postgres-baseline.yml # PG-01 PostgreSQL 엔트리 플레이북
│   ├── netbird-server.yml   # NB-01 NetBird 엔트리 플레이북
│   ├── warpgate-baseline.yml # WG-01 Warpgate 엔트리 플레이북
│   └── seaweedfs-s3.yml     # S3-01 SeaweedFS TLS S3 엔트리 플레이북
└── roles/
    ├── common_baseline/     # 공통 baseline 검증 및 태스크
    ├── k3s_datastore_backup/ # BKP-01 online SQLite·GPG·S3 선언
    ├── k3s_baseline/        # 고정 k3s·local-path·SELinux·systemd 선언
    ├── postgres_baseline/   # PostgreSQL 16·TLS·최소권한 role 선언
    ├── netbird_server/      # NetBird control/relay compose 선언
    ├── warpgate_baseline/   # 고정 Warpgate·systemd hardening·role/target 선언
    └── seaweedfs_s3/        # SeaweedFS 4개 unit·SELinux·TLS·S3 identity 선언
```

## 구문 검사 (Syntax Check)

```bash
ansible-playbook -i inventory/hosts.example playbooks/baseline.yml --syntax-check
```

## 실행 및 멱등성 (Idempotency) 검증

1. 임시 인벤토리 생성 (`hosts.local` 등, `.gitignore`로 보호됨):
   ```ini
   [rocky_baseline]
   target-vm ansible_host=10.10.10.X ansible_user=rocky
   ```

2. 1차 적용:
   ```bash
   ansible-playbook -i inventory/hosts.local playbooks/baseline.yml
   ```

3. 2차 적용 (멱등성 검증 - `changed=0, failed=0` 확인):
   ```bash
   ansible-playbook -i inventory/hosts.local playbooks/baseline.yml
   ```
