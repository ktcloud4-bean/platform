# BKP-01 k3s SQLite·server token 전용 backup/restore

작업: `BKP-01`
잠금: `K3S-BOOTSTRAP`
대상: [`ip-plan.md`](../ip-plan.md)의 `k3s-01`과 SeaweedFS S3 endpoint
설계: [ADR-0005](../adr/0005-backup-and-offsite-recovery.md)

## 목적과 계층 경계

실행 중인 단일 노드 k3s의 SQLite datastore를 SQLite Online Backup API로 일관 복사하고,
같은 시점의 server token과 API proof를 하나의 GPG 암호화 archive로 묶어 전용 S3 bucket에
올린다. 복원은 OpenTofu state 밖의 폐기 가능한 빈 VM에서만 수행한다.

K3s 공식 문서는 SQLite 복원 시 `/var/lib/rancher/k3s/server/db`와 동일한
`/var/lib/rancher/k3s/server/token`을 함께 복원하도록 요구한다. server token은 datastore의
bootstrap data 복호화에 쓰이므로 backup과 한 쌍이다. SQLite 공식 Online Backup API는
실행 중 DB를 다른 DB 파일의 일관된 snapshot으로 만들 수 있다.

- [K3s Backup and Restore](https://docs.k3s.io/datastore/backup-restore)
- [K3s token](https://docs.k3s.io/cli/token)
- [SQLite Online Backup API](https://www.sqlite.org/backup.html)
- [SQLite `PRAGMA quick_check`](https://www.sqlite.org/pragma.html#pragma_quick_check)

Velero는 Kubernetes API resource와 명시한 Pod volume 파일을 복원한다. BKP-02의 node-agent
hostPath에는 k3s server directory가 없고, SQLite 파일과 host의 server token은 Velero
Backup/Restore 대상이 아니다. BKP-01 복원 성공은 Velero Restore CR이 0개인 격리 cluster에서
원래 UID와 spec/data hash를 가진 API object가 돌아오는 것으로 대조한다.

## 선언과 영속 자원

| 자원 | 소유·권한 | 역할 |
|---|---|---|
| `playbooks/k3s-datastore-backup.yml` | Ansible | 라이브 backup service·timer 선언 |
| `roles/k3s_datastore_backup/` | Ansible | 온라인 SQLite copy, GPG 암호화, S3 round-trip 검증 |
| `tools/bkp-01/` | controller script | 저장소 밖 입력, identity 병합, bucket, 임시 VM·복원 guard |
| `bkp-01-k3s-datastore` | 전용 bucket | 암호화 archive만 보관 |
| `bkp-01-k3s-datastore` identity | `Read/List/Write` 전용 bucket만 | backup PUT와 restore GET |
| `bkp-01-bucket-bootstrap` identity | 일회성 `Admin` 전용 bucket만 | bucket 생성·versioning 뒤 제거 |
| `k3s-datastore-backup.timer` | enabled, persistent | 매일 backup oneshot 예약 |

기존 `bkp-02-velero` bucket과 identity는 renderer가 기존 저장소 밖 BKP-02 입력에서 다시
포함한다. BKP-01 identity를 적용할 때 기존 identity를 빈 목록이나 새 목록으로 덮어쓰지
않는다. bucket bootstrap credential은 bucket 생성 뒤 canonical 입력과 SeaweedFS에서 모두
제거한다.

server token을 포함한 tar stream은 plaintext archive로 디스크에 쓰지 않고, 저장소 밖
recovery GPG public key로 즉시 암호화한다. private key는 라이브 k3s·S3·Git에 복사하지 않는다.
복구 자격증명과 GPG private key는 복구 대상 cluster의 Vault에만 두지 않는다.

## 적용 전 정지 기준

다음 중 하나면 실제 변경 전에 중단한다.

- `BKP-01 READY`, `K3S-01·S3-01 DONE`, `K3S-BOOTSTRAP` 단독 소유가 아니다.
- 라이브 k3s service가 active/running이 아니거나 Node가 `Ready`가 아니다.
- SQLite source `quick_check`가 `ok`가 아니거나 token이 root `0600` regular file이 아니다.
- Argo Application, Velero workload·BSL, 기존 PVC/PV가 사전 기준선과 다르다.
- Proxmox capacity가 [`capacity-plan.md`](../capacity-plan.md)의 경고·정지 기준에 닿는다.
- `bkp-01-k3s-datastore` bucket/identity/VMID/실험 주소가 이미 존재한다.
- 기존 `bkp-02-velero` identity를 renderer가 보존하지 못한다.
- strict SSH, GPG encryption recipient, S3 TLS hostname 검증 중 하나라도 실패한다.

라이브 `k3s`를 stop/restart/reboot하지 않는다. Online Backup API가 실패하면 service를
중단해 파일을 복사하는 fallback으로 전환하지 않고 보고한다. OPNsense와 OpenTofu state,
`gitops/root/kustomization.yaml`, Argo `platform-root.targetRevision`도 변경하지 않는다.

## 저장소 밖 입력 준비

부모 directory는 `0700`, `input.json`과 inventory는 `0600`이다. S3 certificate는
인증된 object host SSH로 가져와 SAN·만료를 확인한다. 명령 인자·일반 log에 credential이나
token 값을 넣지 않는다.

```bash
python3 infra/ansible/tools/bkp-01/prepare-input.py \
  --output <outside-bkp01>/input.json \
  --gpg-recipient <full-GPG-fingerprint> \
  --s3-ca-file <authenticated-S3-certificate> \
  --s3-host <ip-plan의-S3-alias>

python3 infra/ansible/tools/bkp-01/prepare-inventory.py \
  --output <outside-bkp01>/inventory.yml \
  --name k3s-01 \
  --host <ip-plan의-k3s-canonical-host>
```

## 전용 bucket·최소권한 identity

bootstrap phase는 기존 BKP-02 final identity, BKP-01 bootstrap, BKP-01 final identity를
함께 렌더한다. `--check --diff`와 적용 뒤 일회성 identity로 bucket을 만들고 versioning을
활성화한다. final phase 재적용과 실제 identity 목록 확인 뒤에만 canonical 입력에서
bootstrap credential을 제거한다.

```bash
python3 infra/ansible/tools/bkp-01/render-seaweedfs-vars.py \
  --bkp-01-input <outside-bkp01>/input.json \
  --bkp-02-input <outside-bkp02>/input.json \
  --phase bootstrap --output <mode-0600-bootstrap-vars>

ansible-playbook -i <outside-s3-inventory> infra/ansible/playbooks/seaweedfs-s3.yml \
  -e @<mode-0600-bootstrap-vars> --check --diff
ansible-playbook -i <outside-s3-inventory> infra/ansible/playbooks/seaweedfs-s3.yml \
  -e @<mode-0600-bootstrap-vars>
```

final vars로 재적용한 뒤 `bkp-02-velero`와 BKP-01 final identity만 있어야 한다. BKP-01 final
identity의 자기 bucket HEAD/LIST/PUT/GET은 성공하고, 기존 BKP-02 bucket HEAD는 403이어야
한다. 같은 시점 자기 bucket 성공을 양성 control로 둔다.

### S3 client 실행 경계

controller는 SeaweedFS S3 service의 허용 source가 아니므로 TCP 8333에 직접
접속하지 않는다. 기존 firewall을 넓히지 않고, 현재 source allowlist에 포함된
`object-01`에 검증 client 두 개만 전용 임시 directory에 배치해 자기 TLS endpoint를
접속한다.
credential 입력은 SSH stdin으로만 전달하고 object host에 파일로 저장하지 않는다.

```bash
ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<object-known-hosts> \
  <object-user>@<ip-plan의-object-01> \
  'umask 077; mkdir /var/tmp/bkp01-s3-client'

scp -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<object-known-hosts> \
  infra/ansible/tools/bkp-01/s3-client.py \
  infra/ansible/roles/k3s_datastore_backup/files/s3_sigv4.py \
  <object-user>@<ip-plan의-object-01>:/var/tmp/bkp01-s3-client/

ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<object-known-hosts> \
  <object-user>@<ip-plan의-object-01> \
  'sudo python3 /var/tmp/bkp01-s3-client/s3-client.py --config - --identity bootstrap \
  --ca-file /etc/seaweedfs/tls/s3.crt --operation create-bucket' \
  < <outside-bkp01>/input.json

ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<object-known-hosts> \
  <object-user>@<ip-plan의-object-01> \
  'sudo python3 /var/tmp/bkp01-s3-client/s3-client.py --config - --identity bootstrap \
  --ca-file /etc/seaweedfs/tls/s3.crt --operation enable-versioning' \
  < <outside-bkp01>/input.json
```

HEAD/LIST/PUT/GET 양성 control과 기존 bucket 403 음성 control도 같은 경로에서
`--identity backup`으로 수행한다. 다운로드한 복원 archive는 암호문이지만
object host의 mode `0600` 임시 파일로만 두고, hash 비교와 controller로의
strict SSH stream 전송 후 즉시 제거한다. 마지막에는 다음 정확한 helper 파일도
제거한다.

```bash
ssh -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<object-known-hosts> \
  <object-user>@<ip-plan의-object-01> \
  'sudo find /var/tmp/bkp01-s3-client -mindepth 1 -maxdepth 2 -type f -delete && \
  sudo find /var/tmp/bkp01-s3-client -mindepth 1 -maxdepth 2 -type d -empty -delete && \
  rmdir /var/tmp/bkp01-s3-client'
```

## 라이브 온라인 backup

Ansible role은 backup service를 직접 실행하지 않고 선언와 timer를 배치한다.
`Persistent=true` timer는 놓친 calendar 시각이 있으면 첫 활성화 직후 oneshot을
실행할 수 있으므로, 적용 전 미실행이라고 가정하지 않는다. syntax/check, 첫 적용,
두 번째 적용 `changed=0`과 service journal을 확인한 뒤, 이미 성공 object가 없는
경우에만 oneshot을 한 번 수동 시작한다. backup service에는 `Requires=k3s.service`를
두지 않아, k3s가 중단된 상태에서 backup 실행이 server를 자동 시작하지 않는다.

```bash
python3 infra/ansible/tools/bkp-01/render-k3s-backup-vars.py \
  --input <outside-bkp01>/input.json --output <mode-0600-k3s-vars>
ansible-playbook -i <outside-bkp01>/inventory.yml \
  infra/ansible/playbooks/k3s-datastore-backup.yml -e @<mode-0600-k3s-vars> --check --diff
ansible-playbook -i <outside-bkp01>/inventory.yml \
  infra/ansible/playbooks/k3s-datastore-backup.yml -e @<mode-0600-k3s-vars>
ansible-playbook -i <outside-bkp01>/inventory.yml \
  infra/ansible/playbooks/k3s-datastore-backup.yml -e @<mode-0600-k3s-vars>

ssh <live-k3s> 'sudo systemctl start k3s-datastore-backup.service'
```

성공 JSON은 secret 원문 없이 다음을 포함한다.

- source와 online copy 각각 `quick_check=ok`
- database·암호화 archive byte와 SHA-256
- S3 PUT 뒤 HEAD content length, GET SHA-256, LIST 존재
- backup 전후 k3s `MainPID`, `NRestarts`, active timestamp 불변
- API proof의 resource 이름과 Velero Restore CR 0개
- Velero node-agent가 datastore·server token path를 mount하지 않는 판정

## 격리 VM 복원 drill

임시 VM은 template full clone 하나이며 OpenTofu config/state에 선언·import하지 않는다.
생성 직전 VMID·이름·주소의 부재와 capacity를 다시 확인한다. `proxmox-restore-vm.py`는
서비스 VMID, ip-plan의 실험 범위 밖 주소, `bkp01-restore-` 밖 이름을 거부하고 Proxmox
`/etc/network/interfaces` hash를 생성 전후 보존한다.

1. `proxmox-restore-vm.py create`로 2 vCPU·2 GiB RAM·10 GiB full clone을 만든다.
2. QGA `network-get-interfaces`의 IP·MAC을 Proxmox `net0`와 대조한 뒤 ED25519
   host key를 한 번만 scan해 전용 `known_hosts`에 고정한다. 그 뒤의 모든 SSH는
   strict mode를 쓰고, guest 내부 public host key와 hostname을 다시 대조한다.
3. `baseline.yml`과 `k3s-baseline.yml`을 적용하고 두 번째 적용 `changed=0`을
   확인한다.
4. `bkp-01-restore-stage.yml`로 nftables·restore 도구를 배치하고 **임시 VM의 k3s만** 정지한다.
5. final S3 identity로 `object-01`의 새 mode `0600` 임시 파일에 archive를 GET하고
   암호화 SHA-256을 backup 결과와 비교한 뒤 strict SSH stream으로 controller에
   옮기고 object host 임시 파일을 즉시 제거한다.
6. GPG decrypt tar stream을 strict SSH stdin으로 임시 VM staging에 직접 풀어 controller에
   plaintext token archive를 만들지 않는다.
7. 임시 VM의 정확한 controller SSH 응답과 loopback만 허용하는
   `bkp01_isolation` nft table을 적용한다. gateway·라이브 k3s API·S3·공개 HTTPS probe가
   실패하고 output/forward drop counter가 증가해야 한다.
8. `--mode without-token`을 실행한다. API `/readyz`는 성공하면 안 되고 새 journal cursor
   이후 token/bootstrap 복호화 실패가 있어야 한다.
9. 같은 staging 원본으로 data directory를 다시 만들고 `--mode with-token`을 실행한다.
   `/readyz=ok`, SQLite `quick_check=ok`, API proof UID·spec/data SHA-256 일치,
   Velero Restore CR 0개를 확인한다.

음성 시험 뒤 생성됐을 수 있는 임시 token과 변형된 DB는 성공 복원에 재사용하지 않는다.
매 단계마다 staging의 원본 database와 token SHA-256을 암호화 manifest와 먼저 대조한다.

## 정리와 불변성

성공·실패와 무관하게 삭제 대상은 이번 drill의 정확한 임시 VMID·이름과 outside state
directory뿐이다. helper의 `destroy`는 state file, 라이브 `qm config` 이름, VMID를 세 겹으로
대조한 뒤 임시 VM과 그 disk를 삭제한다. 기존 5개 VM, template, OpenTofu state·tfvars,
Proxmox network config는 삭제·수정 대상이 아니다.

정리 후 다음을 모두 확인한다.

- 임시 VMID·disk·guest IP·restore inventory/known_hosts/state directory 부재
- Proxmox VM 목록은 기존 5개와 template뿐, network config SHA-256 불변
- OpenTofu state의 기존 5개 resource와 no-op plan 불변
- 라이브 k3s boot ID·MainPID·active timestamp 불변, Node Ready·DiskPressure False
- Argo Application `Synced/Healthy`, `platform-root.targetRevision` 불변
- 기존 PVC/PV, Velero BSL·bucket·identity 불변
- BKP-01 bucket에는 암호화 archive만 있고 plaintext token/datastore object 없음
- Git tracked/untracked와 전체 Git history에 credential·token·private key 원문 없음

## rollback

bucket·identity 적용 중 실패하면 bootstrap credential을 먼저 제거하지 않는다. 기존
`bkp-02-velero` identity가 보존되고 bucket이 빈 상태인지 확인한 뒤, 승인된 경우에만
BKP-01 전용 bucket·두 identity를 역순 제거한다. 기존 bucket/identity는 rollback 대상이 아니다.

라이브 backup role rollback은 timer disable/stop, service·timer·정확한 BKP-01 config/libexec/
state path 제거다. `k3s` service와 datastore/token은 건드리지 않는다. 이미 성공한 암호화
backup object는 복구 가능성을 잃게 하므로 기본 rollback에서 삭제하지 않는다.

복원 실패는 라이브 cluster rollback 사유가 아니다. 임시 VM을 삭제하고 archive·manifest·
오류 class를 보존해 branch에서 중단한다. 라이브 k3s에 restore하거나 service를 중단하는
대안으로 전환하지 않는다.

## 시크릿 경계

- server token, S3 secret, GPG private key와 복호화 tar를 Git·채팅·일반 log에 남기지 않는다.
- Ansible secret 입력과 runtime config는 `no_log`, outside `0600`, guest root `0600`이다.
- backup summary에는 cryptographic hash·byte·resource UID만 남기며 token 값은 출력하지 않는다.
- S3 archive는 public-key encrypted 상태만 허용하고 plaintext object는 만들지 않는다.

## 2026-08-01 검증 기록

### 온라인 backup과 라이브 불변성

최신 `origin/main` rebase 뒤 최종 재검증에서 backup ID `20260801T061722Z`를 만들었다.
source와 Online Backup API 사본의 `quick_check`가 모두 `ok`였고, 사본은 28,299,264 bytes,
SHA-256 `2c92b5462d23b7be286a45d76f6a795ea9bbc074aa439975cc84abd2d67cff23`였다. GPG 암호문은
11,645,915 bytes, SHA-256
`012377d8d34c8fe7f4bd96d01f2eaf607bc8718501055c52be05c6d74eb25af6`였으며, S3 PUT 뒤
HEAD length·GET hash·LIST key가 모두 일치했다. 라이브 host에는 평문 작업 directory가
남지 않았고 root `0700` state directory와 `0600` lock만 남았다.

backup 전후 k3s의 boot ID `2ec08a0c-0dcf-461f-acb7-7bf8bbd67695`, `MainPID=1013`,
`NRestarts=0`, `ActiveEnterTimestampMonotonic=11468908`이 같았다. service를 정지·재시작하거나
host를 재부팅하지 않았고 Node는 `Ready`, source SQLite의 WAL mode와 `quick_check=ok`도
유지됐다. timer는 enabled·active이고 다음 실행은 2026-08-02 03:55:55 KST로 예약됐다.
role 최종 재적용은 `ok=17 changed=0 failed=0`이었다.

### S3 최소권한과 기존 자원 보존

전용 `bkp-01-k3s-datastore` bucket은 versioning `Enabled`이고 final identity에는 그 bucket의
`Read/List/Write`만 있다. 자기 bucket HEAD/LIST/객체 HEAD는 HTTP 200, 같은 identity로 기존
`bkp-02-velero` bucket HEAD는 HTTP 403이었다. 최종 SeaweedFS 선언에는 기존
`bkp-02-velero`와 BKP-01 final identity만 있고 bootstrap identity는 제거됐다.
최초 검증 archive와 rebase 뒤 재검증 archive 두 개, 합계 19,764,502 bytes가 모두 versioned
암호문 key로 남았고 plaintext datastore/token object는 없다.

실측 당시 공용 volume 1개와 BKP-02 collection volume 4개가 `volume_max_count=5`를 모두
사용하고 있어 BKP-01 PUT이 `no writable volumes`로 실패했다. 기존 volume을 삭제하거나
재사용하지 않고 사용자 승인을 받아 최소 한도 6으로 늘려 BKP-01 collection volume 1개를
추가했다. 최종 topology는 6개 모두 정상이고 object disk는 약 196 GiB가 남았다. 기존
BKP-02 bucket HEAD/LIST와 SeaweedFS 네 service의 active/enabled 상태를 다시 확인했으며,
최종 Ansible 재적용은 `ok=40 changed=0 failed=0`이었다.

### 격리 복원과 Velero 대조

OpenTofu state 밖에서 VMID 9901, 이름 `bkp01-restore-20260801`, 2 vCPU·2 GiB RAM·10 GiB
full clone을 만들었다. 초기 blank cluster에서는 `velero` Namespace,
`backups.velero.io` CRD, `velero` Deployment, `platform-root` Application이 없었고 CoreDNS
ConfigMap UID도 원본과 달랐다. archive를 복호화한 staging에는 mode `0600`의 database,
server token, manifest 세 파일만 있었고 암호문이나 평문 tar를 남기지 않았다.

controller SSH 응답만 허용하고 gateway, 라이브 k3s API, S3, public HTTPS와 동일 VLAN의
라이브 k3s→임시 VM TCP 6443을 차단한 nftables 격리를 적용했다. server token 없이 복원하면
API가 ready가 되지 않고 `token/bootstrap decryption failure`로 실패했다. 같은 원본 DB와
token을 함께 복원하면 `/readyz=ok`, 복원 DB `quick_check=ok`가 됐으며 다음 UID가 라이브
backup 시점과 일치했다.

| API object | 복원 UID |
|---|---|
| Namespace `velero` | `5d110109-d2c5-40ef-968e-ad731b3b85ae` |
| ConfigMap `kube-system/coredns` | `3731f5c8-9830-459e-81c6-28cd650c9091` |
| CRD `backups.velero.io` | `03e5a945-d486-43e5-b4f5-094c8d56331b` |
| Application `argocd/platform-root` | `a2fc1818-7538-4713-8886-b47293d9c5f3` |
| Deployment `velero/velero` | `439f0466-4ffe-4921-a60c-8f485a162b15` |

양성 복원을 같은 staging으로 한 번 더 실행해 UID가 그대로임을 확인했다. 복원 cluster의
Velero Restore CR은 0개였고, 라이브 Velero node-agent mount 어디에도
`/var/lib/rancher/k3s/server/db/state.db`나 `/var/lib/rancher/k3s/server/token`이 없었다.
따라서 API object는 Velero restore가 아니라 BKP-01의 SQLite·token 복원으로 돌아왔다.
최신 rebase 뒤에는 이름 `bkp01-restore-postrebase`로 같은 VMID를 새로 만들고 최신 archive로
blank/음성/양성/양성 재실행과 제거를 모두 반복해 같은 판정을 다시 얻었다.

임시 baseline에서 `/etc/localtime` link를 바꾼 뒤 `systemd-timedated` cache가 이전 timezone을
보고하는 문제를 재현해 공통 role이 cache를 갱신하도록 보정했다. baseline 최종 실행은
`ok=22 changed=0`, k3s baseline은 `ok=47 changed=0`, restore staging은 임시 k3s를 정지한
상태에서 `ok=10 changed=0`이었다.

### 정리와 경계 재확인

VMID 9901, disk, 임시 주소, restore state/inventory/known_hosts와 object host helper를 모두
제거했다. Proxmox에는 기존 서비스 VM 5개와 template 9000만 남았고 network config hash는
불변이었다. 기존 OpenTofu state SHA-256
`abd55833087fec91e019da764121d410ab7906c4aaee80fabf469aa055972c5d`는 plan 전후 같았으며
OpenTofu 1.12.5 재계획 결과는 `No changes`였다. OPNsense, Tofu 선언/state,
`gitops/root/kustomization.yaml`, `platform-root.targetRevision`은 변경하지 않았다.

라이브 최종 상태에서 모든 Argo Application은 `Synced/Healthy`, Velero deployment와
node-agent는 Ready, BSL은 `Available`이었다. 기존 Traefik·Vault PVC/PV도 Bound 상태를
유지했다. Git 현재 파일과 전체 history를 exact credential/server token 및 private-key/token
pattern으로 검사해 원문 0건을 확인했다. 저장소 밖 BKP-01 입력·inventory·CA만 mode `0600`으로
남겼고 bootstrap credential과 임시 자원은 남기지 않았다.
