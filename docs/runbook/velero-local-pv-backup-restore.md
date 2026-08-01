# BKP-02 Velero local-path filesystem backup·restore

작업: `BKP-02`
대상: `k3s-01.imcherry5778.xyz`, `object-01.imcherry5778.xyz`
S3: `https://s3.imcherry5778.xyz:8333`, bucket `bkp-02-velero`, prefix
`cluster-k3s-01`

이 문서는 Kubernetes API resource와 `local-path` PVC 파일을 Velero node-agent와 Kopia로
백업하고, 실제 namespace 삭제 후 복원하는 절차를 소유한다. k3s SQLite
`/var/lib/rancher/k3s/server/db/state.db`와 server token은 범위 밖이며
[ADR-0005](../adr/0005-backup-and-offsite-recovery.md)의 별도 절차가 보호한다.
SeaweedFS 로컬 S3도 같은 물리 장애 도메인이므로 오프사이트 복구라고 주장하지 않는다.

## 승인된 고정 입력과 권한

| 항목 | 고정값 |
|---|---|
| Helm chart | `velero` 12.1.0, archive SHA-256 `cd23589ad1b2d25cdd3220f6866b3f6f4c5683c4c09494e76a14700b33f81f83` |
| Velero | 1.18.2, linux/amd64 image digest `sha256:a77d493b80f622e0bed1b9a19fea40a48d427de24e82be3f64824528b1ab7ecb` |
| AWS plugin | 1.14.2, linux/amd64 digest `sha256:abe29a7b360231e359f7aaee79668141bd619ab6989c7cc78d041110987f6ca2` |
| Kopia | Velero binary 내장 fork commit `d946b1e75197`, upstream 기반 0.16.0 |
| final S3 identity | `bkp-02-velero`: `Read/List/Write:bkp-02-velero`만 |
| bootstrap identity | `bkp-02-bucket-bootstrap`: bucket 생성 동안 `Admin:bkp-02-velero`, 생성 직후 제거 |
| Velero 권한 | 전용 ServiceAccount의 승인된 `cluster-admin` binding |
| node-agent 권한 | 단일 node에서 root·privileged, `/var/lib/kubelet/pods` read/write mount |

chart 원본과 image provenance는
[`release-metadata.env`](../../gitops/apps/velero/release-metadata.env), 운영 override와
권한 이유는 [`UPSTREAM-BKP-02.md`](../../gitops/apps/velero/UPSTREAM-BKP-02.md)가 소유한다.
실행 image는 모두 digest로 고정한다. chart의 CRD upgrade/cleanup Job과 CSI snapshot은
비활성화한다.

## 정지 기준

다음 중 하나면 쓰기 전에 중단한다.

- `GITOPS-01`, `STOR-01`, `S3-01` 중 하나가 `DONE`이 아니거나 다른 backup/restore 작업이
  같은 자원을 사용한다.
- Node `Ready=False`, `DiskPressure=True`, failed systemd unit 존재, 기존 Argo Application이
  `Synced/Healthy`가 아니다.
- k3s 또는 object guest filesystem 여유가 25% 미만 경고·20% 미만 정지 구간이다.
- 기존 PVC/PV, S3 identity/bucket 또는 엄격한 S3 TLS 기준선이 preflight와 다르다.
- 예측하지 않은 namespace/PV/bucket이 대상 이름과 충돌하거나 credential 입력 mode가
  `0600`보다 넓다.
- 검증 중 backup/restore가 `PartiallyFailed`·`Failed`, marker hash 불일치, CSI resource 생성,
  기존 PVC/S3 object 변화, Node/Argo 열화 중 하나라도 발생한다.

승인된 steady-state request는 CPU 200m·RAM 256Mi, limit는 CPU 1·RAM 1Gi다. data mover와
검증 Pod가 함께 실행되는 짧은 peak request는 약 CPU 310m·RAM 400Mi, limit는 CPU
1.6·RAM 1.6Gi다. 검증 payload는 marker와 8MiB 파일, PVC 요청은 64Mi로 제한한다.

## credential과 bucket 생성

credential 원문은 Git·채팅·명령 인자·일반 로그에 두지 않는다. canonical 입력은
`/home/imcherry/.config/platform/bkp-02/input.json` 하나이며 mode `0600`, 부모 디렉터리는
`0700`이다.

```bash
mkdir -p -m 0700 /home/imcherry/.config/platform/bkp-02
python3 gitops/tools/bkp-02/prepare-credentials.py \
  --output /home/imcherry/.config/platform/bkp-02/input.json
stat -c '%a %n' /home/imcherry/.config/platform/bkp-02/input.json
```

SeaweedFS의 기존 source allowlist는 S3-01 외부 inventory가 계속 소유한다. 임시
extra-vars에는 identity만 넣으며 task가 `no_log`로 보호한다.

```bash
bkp_vars_dir="$(mktemp -d)"
bkp_vars_file="$bkp_vars_dir/seaweedfs-bootstrap.json"
python3 gitops/tools/bkp-02/render-seaweedfs-vars.py \
  --phase bootstrap \
  --input /home/imcherry/.config/platform/bkp-02/input.json \
  --output "$bkp_vars_file"
ANSIBLE_CONFIG=infra/ansible/ansible.cfg \
ANSIBLE_SSH_COMMON_ARGS='-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/imcherry/.ssh/known_hosts' \
ansible-playbook -i /home/imcherry/.config/platform/s3-01/inventory.yml \
  infra/ansible/playbooks/seaweedfs-s3.yml -e "@$bkp_vars_file" --check --diff
ANSIBLE_CONFIG=infra/ansible/ansible.cfg \
ANSIBLE_SSH_COMMON_ARGS='-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/imcherry/.ssh/known_hosts' \
ansible-playbook -i /home/imcherry/.config/platform/s3-01/inventory.yml \
  infra/ansible/playbooks/seaweedfs-s3.yml -e "@$bkp_vars_file"
unlink "$bkp_vars_file"
rmdir "$bkp_vars_dir"
```

stdlib SigV4 helper는 값이 아닌 code만 object host의 정확한 임시 경로로 복사한다. credential
JSON은 SSH stdin으로만 전달하고, helper는 guest의 기존 TLS certificate를 CA로 사용한다.

```bash
scp -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/home/imcherry/.ssh/known_hosts \
  gitops/tools/bkp-02/s3-sigv4-client.py \
  rocky@10.10.50.20:/tmp/bkp-02-s3-sigv4-client.py
ssh -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile=/home/imcherry/.ssh/known_hosts rocky@10.10.50.20 \
  'sudo python3 /tmp/bkp-02-s3-sigv4-client.py --operation create --identity bootstrap --ca-file /etc/seaweedfs/tls/s3.crt' \
  </home/imcherry/.config/platform/bkp-02/input.json
```

bucket 생성 뒤 final identity만 다시 적용하고 bootstrap credential 원문도 제거한다.

```bash
bkp_vars_dir="$(mktemp -d)"
bkp_vars_file="$bkp_vars_dir/seaweedfs-final.json"
python3 gitops/tools/bkp-02/render-seaweedfs-vars.py \
  --phase final \
  --input /home/imcherry/.config/platform/bkp-02/input.json \
  --output "$bkp_vars_file"
ANSIBLE_CONFIG=infra/ansible/ansible.cfg \
ANSIBLE_SSH_COMMON_ARGS='-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/imcherry/.ssh/known_hosts' \
ansible-playbook -i /home/imcherry/.config/platform/s3-01/inventory.yml \
  infra/ansible/playbooks/seaweedfs-s3.yml -e "@$bkp_vars_file" --check --diff
ANSIBLE_CONFIG=infra/ansible/ansible.cfg \
ANSIBLE_SSH_COMMON_ARGS='-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/home/imcherry/.ssh/known_hosts' \
ansible-playbook -i /home/imcherry/.config/platform/s3-01/inventory.yml \
  infra/ansible/playbooks/seaweedfs-s3.yml -e "@$bkp_vars_file"
unlink "$bkp_vars_file"
rmdir "$bkp_vars_dir"
python3 gitops/tools/bkp-02/retire-bootstrap-credential.py \
  --input /home/imcherry/.config/platform/bkp-02/input.json
```

Kubernetes Secret은 SSH stdin으로만 주입한다. 도구는 Secret 값과 base64를 출력하지 않는다.

```bash
python3 gitops/tools/bkp-02/inject-kubernetes-secrets.py \
  --input /home/imcherry/.config/platform/bkp-02/input.json \
  --known-hosts /home/imcherry/.ssh/known_hosts
```

## GitOps 배포

`gitops/root/velero-project.yaml`과 `velero-application.yaml`을 root Kustomization에 포함한다.
branch 검증 중 child Application은 `task/bkp-02`를 읽는다. root를 검증 commit으로 고정해
기존 child app을 보존한 상태에서 sync하고, 최종 squash merge에는 child revision을
`main`으로 바꾼다. Secret은 Argo가 소유하지 않으며 prune 대상이 아니다.

배포 후 다음을 확인한다.

```bash
sudo k3s kubectl -n argocd get applications platform-root velero
sudo k3s kubectl -n velero rollout status deployment/velero --timeout=10m
sudo k3s kubectl -n velero rollout status daemonset/node-agent --timeout=10m
sudo k3s kubectl -n velero get backupstoragelocation default
sudo k3s kubectl -n velero get pod -o wide
```

runtime `imageID`는 release metadata의 linux/amd64 digest와 같아야 한다. CRD는 chart가
설치하지만 `volumesnapshot*` CRD·VolumeSnapshotLocation은 없어야 하며 server args에
`--uploader-type=kopia`는 있고 `--features=EnableCSI`와
`--default-volumes-to-fs-backup`은 없어야 한다.

## 삭제 후 복원 검증

정확한 ephemeral 대상은 다음뿐이다.

- namespace `bkp-02-restore-test`
- PVC `bkp-02-data`, Pod `bkp-02-holder`, 동적으로 연결된 전용 PV
- `velero.io/exclude-from-backup=true` label의 제외 ConfigMap `bkp-02-excluded`
- Backup `bkp-02-validation-20260801`
- Restore `bkp-02-restore-20260801`
- 해당 Backup/Restore가 소유한 PVB/PVR와 mover Pod

리소스를 적용하고 Pod가 Ready인 뒤 marker와 8MiB payload를 만든다. marker 내용과 두
SHA-256, 최초 PV 이름을 기록한다.

```bash
sudo k3s kubectl apply -f gitops/tools/bkp-02/test-resources.yaml
sudo k3s kubectl -n bkp-02-restore-test wait pod/bkp-02-holder \
  --for=condition=Ready --timeout=5m
printf '%s\n' 'BKP-02 marker 2026-08-01' | \
  sudo k3s kubectl -n bkp-02-restore-test exec -i bkp-02-holder -- \
  sh -c 'cat > /data/marker.txt'
sudo k3s kubectl -n bkp-02-restore-test exec bkp-02-holder -- \
  sh -c 'dd if=/dev/urandom of=/data/payload.bin bs=1M count=8 && sync'
sudo k3s kubectl -n bkp-02-restore-test exec bkp-02-holder -- \
  sha256sum /data/marker.txt /data/payload.bin
sudo k3s kubectl apply -f gitops/tools/bkp-02/backup.yaml
```

Backup은 `Completed`, PVB는 `Completed`와 uploader `kopia`, 처리 byte가 8MiB 이상이어야
한다. Backup spec의 `snapshotVolumes=false`, snapshot CRD/VSL 0건도 함께 기록한다. 그런
뒤 자신이 만든 namespace만 삭제하고 namespace·PVC·원래 PV가 모두 NotFound인지 native
API로 확인한다.

```bash
sudo k3s kubectl delete namespace bkp-02-restore-test --wait=true --timeout=5m
sudo k3s kubectl apply -f gitops/tools/bkp-02/restore.yaml
```

Restore가 `Completed`이고 Pod가 Ready가 되면 marker 내용·marker SHA-256·payload SHA-256이
원본과 정확히 같아야 한다. `bkp-02-excluded` ConfigMap 조회는 `NotFound`여야 한다. PVR은
`Completed`, uploader `kopia`, 처리 byte가 8MiB 이상이어야 한다.

## 정리와 운영 유지

승인된 결정은 PoC 성공 뒤 Velero 운영 구성을 유지하는 것이다. 검증 후 복원 namespace와
Restore를 삭제하고 `DeleteBackupRequest`로 validation backup의 S3 data까지 제거한다.
plain Backup CR 삭제는 object data 정리 증거가 아니므로 사용하지 않는다. 최종적으로
namespace/PVC/PV, Backup/Restore/PVB/PVR/DeleteBackupRequest, validation mover Pod가 모두
없고 전용 prefix에 validation backup object가 0인지 native API와 S3 API로 증명한다.

유지 대상은 `velero` namespace, Velero/node-agent, 13개 Velero CRD, 두 Secret,
BackupStorageLocation, `bkp-02-velero` bucket·final identity다. test namespace 전용
BackupRepository와 `cluster-k3s-01/kopia/bkp-02-restore-test/`는 다른 snapshot이 0개임을
확인한 뒤 승인된 object 수·byte와 정확히 일치할 때만 정리한다. Kopia SafetyFull
maintenance가 최근 orphan pack을 즉시 회수하지 않는 경우에도 검증 data를 남기지 않는다.
기존 namespace/PVC/PV와 기존 S3 data는 변경하지 않는다.

## rollback

1. Git에서 BKP-02 squash commit을 revert하고 root Application을 sync한다. 먼저 검증
   Backup/Restore가 없는지 확인한다.
2. Argo가 Velero workload·BSL을 prune하게 하되 `cleanUpCRDs=false`이므로 CRD와 외부
   Secret/bucket은 자동 삭제하지 않는다.
3. 제거가 승인된 경우에만 `velero` namespace의 두 전용 Secret과 Velero CRD를 정확한
   목록으로 삭제한다. 다른 namespace/PV는 대상이 아니다.
4. 새 일회성 `Admin:bkp-02-velero` identity를 Git 밖 mode 0600 입력으로 만들어 빈 bucket을
   삭제하고 즉시 identity를 제거한다. final identity도 그 뒤 제거한다. prefix가 비어 있지
   않거나 목록이 예상과 다르면 삭제하지 않는다.
5. object host의 `/tmp/bkp-02-s3-sigv4-client.py`는 검증 종료 후 `sudo unlink`로 제거한다.

## 실제 증거

검증일은 2026-08-01이다. k3s는 `v1.36.2+k3s1`, Node는 `Ready=True`·
`DiskPressure=False`였다. 시작 시 k3s guest root는 4% 사용·약 206.5GB 여유,
object guest root는 2% 사용·약 210.4GB 여유였다. 기존 PVC/PV 기준선은 다음 두 개뿐이었다.

| namespace/PVC | PV | storage |
|---|---|---|
| `kube-system/traefik` | `pvc-468433af-b025-4ab5-b544-fb35e9c0ca2e` | local-path 128Mi |
| `vault/vault-data` | `pvc-87e4c5ea-b225-4acf-9fa0-0552e04f19f9` | local-path 4Gi |

### 배포와 보정 증거

Argo root 검증 revision `cfec657e380c79bd0aa26b3cffd077f5d530fa2e`에서 Velero child를
bootstrap했다. server와 node-agent의 runtime imageID는
`sha256:a77d493b80f622e0bed1b9a19fea40a48d427de24e82be3f64824528b1ab7ecb`, AWS init
plugin은 `sha256:abe29a7b360231e359f7aaee79668141bd619ab6989c7cc78d041110987f6ca2`와
일치했다. server 실제 process UID/GID는 `1000:1000`, 두 workload restart는 0이었다.
BSL `default`는 `Available`, Velero CRD는 13개, CSI snapshot CRD와 VSL은 0개다.

처음 server Pod는 이름형 image user `cnb:cnb` 때문에 kubelet의 `runAsNonRoot` 판정을
통과하지 못했다. 숫자 UID/GID 1000으로 고정한 뒤 runtime `/proc`으로 확인했다. 첫 validation
Backup은 Kopia가 read-only root의 `/udmrepo`, 이어 `/.cache`에 쓰려 해
`PartiallyFailed`였다. 원본 namespace/PVC는 삭제하지 않고 실패 Backup을
DeleteBackupRequest로 정리했다. `/udmrepo` server `emptyDir`, `HOME=/scratch`를 선언한 뒤
BackupRepository가 `Ready`가 됐다. 이 실패를 성공 증거로 세지 않는다.

node-agent 시작 로그는 custom mover resource `100m/500m CPU`, `128Mi/512Mi` memory와
global load concurrency 1을 사용한다고 기록했다. server args에는
`--uploader-type=kopia`가 있고 CSI feature와 `--default-volumes-to-fs-backup`은 없다.

### 실제 삭제·복원 결과

원본 PVC의 동적 PV는 `pvc-8adcf568-ab63-4fbd-9d5b-53203df34404`였다.

| 파일 | 원본과 복원 SHA-256 |
|---|---|
| `/data/marker.txt` (`BKP-02 marker 2026-08-01`) | `b32ae306b19b145a7729f851bb5829daa4a1a94b9ef3ee293a0235c7d13d22a4` |
| `/data/payload.bin` (8MiB) | `d71a0b1d98dde113cc0e796d658154edc545c3df7670f2e74afd1f7c9db9c82f` |

Backup `bkp-02-validation-20260801`은 `Completed`, error/warning 0, 15/15 item이었다.
PVB `bkp-02-validation-20260801-wz22t`는 uploader `kopia`, phase `Completed`,
8,388,633/8,388,633 bytes를 처리하고 snapshot
`b0a3ee04f9dfab1ed7115fedf98f7494`를 만들었다. S3 전용 prefix는 이때 23 objects,
8,430,762 bytes였다. Backup spec은 `snapshotVolumes=false`, CSI/VSL은 계속 0개였으며
로그도 CSI feature가 꺼져 있고 PV snapshot을 PVB 때문에 건너뛰었다고 기록했다.

그 뒤 test namespace를 삭제했다. namespace·PVC·원래 PV와 원래 local-path directory가
모두 실제로 사라졌고 기존 두 PVC/PV만 남았다. Restore `bkp-02-restore-20260801`은
`Completed`, error 0, 6/6 item이었다. node 결정 전 Linux fallback 경고 1개가 있었지만
PVR `bkp-02-restore-20260801-ptqs2`가 uploader `kopia`, phase `Completed`,
8,388,633/8,388,633 bytes와 파일 2개를 복원했다. 새 동적 PV는
`pvc-106bbdfb-3367-4c65-85d8-6ac287561c2f`이며 `local=true`, `hostPath=false`, `csi=false`다.
Pod 내부와 host local-path에서 위 두 SHA-256이 모두 원본과 같았다.

`velero.io/exclude-from-backup=true` label의 `bkp-02-excluded` ConfigMap은 Backup 상세 목록에
0건이었고 복원 뒤에도 NotFound였다.

### cleanup과 불변성

복원 namespace를 다시 삭제해 새 PVC/PV/local directory 부재를 확인했다. Restore CR을
삭제하고 DeleteBackupRequest가 Kopia snapshot batch delete와 backup object 삭제를
완료했다. Backup 전용 S3 경로는 0 object였다. Kopia SafetyFull maintenance를 성공시켜도
최근 orphan pack 17개·8,418,343 bytes가 즉시 회수되지 않아, 다른 snapshot과
BackupRepository가 0개임을 확인한 뒤 전용
`cluster-k3s-01/kopia/bkp-02-restore-test/`만 object 수·byte 일치 gate로 삭제했다.
최종 `cluster-k3s-01`은 0 object·0 byte다.

최종 namespace/PVC/PV, Backup/Restore/PVB/PVR/DeleteBackupRequest/BackupRepository,
DataUpload/DataDownload, mover·maintenance Job은 모두 native API 0건이다. object host의 임시
SigV4 helper도 제거했다. 유지 대상은 Velero/node-agent·BSL·13개 CRD·두 Secret, 빈
`bkp-02-velero` bucket과 `Read/List/Write` final identity다. SeaweedFS Ansible 최종 2회차는
`ok=40 changed=0 failed=0`이었다. 기존 Traefik/Vault PVC/PV 이름·타입·capacity는 시작과
같다.

merge 전 root와 `headlamp`, `ingress`, `vault`, `velero` Application은 모두
`Synced/Healthy`였다. 검증 branch의 root가 이전 main 기준을 잠시 고정하면서 최신
VAULT-02 AppProject 권한보다 뒤처졌지만, branch를 최신 main에 rebase해 권한을 보존한 뒤
Vault의 실패한 자동 동기화 요청만 다시 실행해 원하는 revision으로 수렴시켰다. Vault
resource나 설정을 BKP-02에서 변경하지 않았다.

마지막 불변성 확인에서 Node는 `Ready=True`·`DiskPressure=False`, k3s root는 4% 사용·
192GB 여유였고 Velero 두 workload는 Ready·restart 0, BSL은 `Available`이었다. 기존
Traefik/Vault PVC와 PV 이름·Bound 상태는 시작과 같았다. 전용 bucket은 HEAD 200,
`cluster-k3s-01` prefix는 0 object·0 byte였고 final identity는 credential 1개와
`Read/List/Write:bkp-02-velero`만 가졌다. 실제 `offsite-backup.timer`는
`active/enabled`이고 source bucket 목록은 계속 비어 있어 기존 BKP-04 범위도 불변이다.
