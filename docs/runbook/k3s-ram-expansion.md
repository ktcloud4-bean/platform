# k3s-01 RAM 증설

- 작업: `CAP-03`
- 상태: 완료
- 잠금: `PVE-LIVE`, `TOFU-STATE`, `K3S-BOOTSTRAP`
- 대상: Proxmox VMID 120 `k3s-01`, RAM 24 GiB → 28 GiB

## 목적과 경계

`WAZUH-01`의 8 GiB available 정지선을 지킬 수 있도록 `k3s-01`에 RAM 4 GiB를 추가한다.
OpenTofu state가 이미 소유하는 VMID 120의 `memory`만 바꾸며 CPU, disk, NIC, VLAN,
cloud-init, 다른 VM과 Proxmox host 설정은 바꾸지 않는다. RAM ballooning은 계속 0이다.

이 작업은 방화벽·DNS·Ingress·credential, PVC, Wazuh 선언을 바꾸지 않는다. Proxmox host는
재부팅하지 않는다. OpenTofu apply와 단일 k3s server VM의 정상 재부팅은 중단을 수반하므로
아래 승인 묶음에 대한 명시 승인을 받은 뒤에만 실행한다.

승인된 cold start 뒤 발견된 재부팅 복원 결함도 같은 세션이 끝까지 소유했다. Ansible은
`fs.inotify.max_user_instances=256`만 영구 선언한다. Kyverno는 UID 0인 Falco modern eBPF
sensor의 정확한 Pod·DaemonSet만 `runAsNonRoot`에서 예외 처리하고, 별도 Enforce 정책으로 고정
image digest·ServiceAccount·capability·hostPath·비privileged 기준선을 강제한다. 이 확대 범위는
각 라이브 적용 직전에 별도 승인을 받았으며 다른 workload와 전역 정책에는 적용하지 않는다.

## 승인 전 확정값

측정 시각은 2026-08-03 13:50 KST다. 저장소 밖 trusted `known_hosts`를 사용한 strict SSH와
최소권한 Proxmox API token으로 확인했다.

| 항목 | 현재 | 적용 후 목표·예상 | gate |
|---|---:|---:|---|
| VMID 120 OpenTofu memory | 24,576 MiB | 28,672 MiB | 4,096 MiB 외 변경 0 |
| balloon | 0 | 0 | 변경 금지 |
| VM RAM 회계 | 41 GiB | 45 GiB | 경고 52 GiB, 정지 56.5 GiB |
| Proxmox host available | 29,864,136,704 bytes (27.813 GiB) | 약 23.813 GiB | 경고 12 GiB, 정지 8 GiB |
| Proxmox swap 사용 | 0 bytes | 0 bytes | 사용 시 중단 |
| `k3s-01` available | 9,857,167,360 bytes (9.180 GiB) | 약 13.180 GiB | Wazuh 재진입 11 GiB |
| Wazuh 최소 3 GiB 반영 후 available | — | 약 10.180 GiB | 정지 8 GiB, 여유 2.180 GiB |
| guest swap / root 여유 / PVC 요청 | 0 / 84% / 75.125 GiB | 동일 | swap 0, root 여유 20% 이상, Wazuh 포함 PVC 96 GiB 미만 |

baseline binary plan은 state resource 5개 모두 `no-op`, 비통과 check 0건이다. 변경 plan은
최신 `origin/main`에 rebase한 뒤 `0 add, 1 change, 0 destroy`, replace 0으로 다시 만들었고
수정 승인 대상 plan SHA-256은
`f8d311c0a424abfaa66d54c0140165c9906774bd63f284eb8fb826dd0cf0e3d0`이다. 대상 주소는
`module.service_vm["k3s-01"].proxmox_virtual_environment_vm.this`, `memory.dedicated`
`24576→28672` 하나이며 나머지 state resource 4개는 `no-op`, 비통과 check는 0건이다.
binary plan은 저장소 밖 mode `0700` 작업 디렉터리에 mode `0600`으로 보관한다.

### 1차 적용 실패와 수정

2026-08-03 14:04 KST에 최초 승인 plan
`7160101dcaa5a495eddbb91517b313e9127378bcb826ca4555ce6d241d8cfe18`을 실행했으나
provider 호출 전에 `Saved plan does not match the given state`와 `different state lineage`로
exit 1 중단됐다. plan 생성은 main worktree의 state를 `-state`로 읽었지만 apply 명령에서
같은 경로를 생략해 CAP-03 worktree의 빈 기본 state와 비교한 것이 원인이다.

실패 직후 state SHA-256, VMID 120의 running·24,576 MiB·balloon 0, guest boot ID와 k3s
active가 모두 불변임을 확인했다. 최초 plan은 재사용하지 않는다. 수정 plan은 같은 실제
state에서 새로 만들었고 action·memory 전후·replace·check 결과가 위 승인값과 같다. 적용은
반드시 다음처럼 **plan과 같은 state 경로를 명시**하고 OpenTofu 자체 pre-apply backup도
저장소 밖에 둔다.

```sh
tofu apply \
  -state=/home/imcherry/projects/ktcloud4-bean/platform/infra/proxmox/tofu/terraform.tfstate \
  -backup=<저장소 밖 mode-0600 경로> \
  <수정 승인 binary plan>
```

## 승인 묶음

승인은 다음 두 동작을 한 묶음으로 허용한다.

1. 저장소 밖 mode `0600` state 사본과 SHA-256을 확정하고, 수정 승인된 단 하나의 binary
   plan을 위의 명시적 `-state`·`-backup` 인자로 한 번 실행한다.
2. VMID 120 설정이 28,672 MiB로 바뀐 것을 확인한 뒤 `k3s-01`에서 정상 OS 재부팅을 한 번
   수행한다. 예상 영향은 단일 노드 Kubernetes API와 그 위 서비스의 수 분 이내 중단이다.

apply 직전에 같은 strict 경로로 capacity 정지선, VMID 120 identity와 현재 memory,
state SHA-256, plan SHA-256을 다시 읽는다. 값이 위 전제와 다르거나 다른 세션이 세 잠금 중
하나라도 사용하면 승인된 plan을 실행하지 않는다. plan을 다시 만들 필요가 생기면 새 SHA와
차이를 제시하고 다시 승인받는다.

## 적용과 검증 순서

1. `tofu fmt -check -recursive`, `tofu init`(`-upgrade` 금지), `tofu validate`를 통과한다.
2. 현재 local state를 저장소 밖 전용 mode `0700` 디렉터리에 mode `0600`으로 복사하고
   SHA-256을 기록한다. state·plan·변수·token 원문은 출력하거나 Git에 넣지 않는다.
3. 실제 mode `0600` 변수 파일과 환경변수 한 개로 binary plan을 만든다. JSON에서 resource
   address, action, `memory.dedicated` 전후와 replace 부재만 추출한다.
4. 승인된 plan을 한 번 apply하고 state 사본을 다시 보관한다. 실패하면 재시도하지 않고
   provider task, state와 `qm config 120`에서 실패 단계를 먼저 특정한다.
5. Proxmox config와 pending 값을 대조해 목표 RAM 외 하드웨어가 불변인지 확인한다.
6. 현재 boot ID를 기록하고 guest에서 `sudo systemctl reboot`를 한 번 실행한다. SSH가
   끊긴 뒤 strict SSH가 돌아올 때까지 유한 대기하고 반복 재부팅하지 않는다.
7. boot ID 변경, Proxmox `memory=28672`·`balloon=0`, guest `MemTotal` 증가·swap 0,
   `k3s` active, `/readyz=ok`, Node Ready, 전체 Argo Application `Synced/Healthy`를 확인한다.
8. host available·swap·load·root·thin, guest available·swap·root, PVC 요청 합계를 한 번
   재측정한다. guest available 11 GiB 이상이어야 `WAZUH-01` 재진입을 연다.
9. 같은 구성의 refresh plan이 `No changes`인지 확인한다.

완료 증거가 모두 있어야 `CAP-03`을 `DONE`으로 바꾸고 `WAZUH-01`을 `READY`로 연다. 실제
post 값은 [`capacity-plan.md`](../capacity-plan.md)에 추가하고 main에는 이 작업 하나의 squash
commit만 통합한다.

## 적용 결과

수정 승인 plan
`f8d311c0a424abfaa66d54c0140165c9906774bd63f284eb8fb826dd0cf0e3d0`을 main worktree의
실제 state와 명시적 `-state`·저장소 밖 backup 경로로 한 번 적용했다. `memory.dedicated`
`24576→28672` 한 건만 바뀌었고 state SHA-256은
`abd55833087fec91e019da764121d410ab7906c4aaee80fabf469aa055972c5d`에서
`b6275be5d8ea2ffcdc5cb327c2a31857ea219f445581d0eaffb9828f2cbf68ea`가 됐다. apply가 만든
backup SHA-256은 `48d77be5509c53c7f188b628e624d438ab14c7379ccadfaed97d0435c0f5d80f`이며 원문은
저장소 밖 mode `0600` 파일에만 있다.

정상 OS 재부팅은 guest boot ID를 바꿨지만 QEMU의 pending memory를 활성화하지 않아 live
memory가 24,576 MiB로 남았다. 별도 승인 뒤 guest를 한 번 종료하고 VMID 120을 cold start해
QEMU current memory 28,672 MiB·balloon 0, guest `MemTotal=29,154,533,376 bytes`, boot ID
`4e745572-8cf3-4bd2-91c2-a572ad45a382`로 활성화했다. Proxmox host는 재부팅하지 않았다.

cold start 뒤 Vault는 initialized 상태에서 sealed됐고 저장소 밖 mode `0600` unseal key 입력을
원문 출력·argv·Git 기록 없이 threshold `3/3`으로 넣어 `sealed=false`, Raft로 복구했다.
CrowdSec AppSec의 기존 `emptyDir`에는 init checksum 대상 49개 외 runtime `crowdsec.db`가 남아
재시작 init이 실패했으므로 exact ephemeral Pod 한 건만 교체해 새 UID에서 Ready가 됐다. PVC와
DB 데이터는 바꾸지 않았다.

Falco의 첫 실패는 root UID inotify instance `127/128` 고갈과
`could not initialize inotify handler`였고, `fs.inotify.max_user_instances=256` 적용과 두 번째
Ansible 실행 `changed=0`으로 복원했다. 이후 새 Pod admission에서 발견한 POL-02 누락은 만료
없는 exact Pod·DaemonSet 예외와 `pol-02-falco-root-sensor-baseline` Enforce로 보정했다. 검증
root `8c299322a49a0bcf55edc39309f69ed305e762cc`, 설정
`bc8da181eecc00392585311628a2a7f3bbdb73de`에서 `allowPrivilegeEscalation=true` 음성 표본은
정확한 보상 rule에서 거부됐고 실제 Pod는 UID
`0a0451fd-739a-439b-8918-95ec8ee6a330→697979bc-7471-4f85-bb3a-33478ef4b1d9`로 바뀌어
Ready·restart 0, 신규 `runAsNonRoot` 거부 0건이었다. 검증 뒤 root는 시작 main SHA로
rollback했고 두 child는 literal `main`, 세 Application은 `Synced/Healthy`였다.

최종 refresh plan SHA-256은
`31a4985740727cc53b89d7b5d29b62d45a1ddc66def45f238c1fef68ab8a34d4`이고 mode `0600`으로
저장소 밖에 있다. 실제 resource 5개가 모두 `no-op`, 변경 0건, 비통과 check 0건이며 plan 전후
state SHA-256은 `b6275be5d8ea2ffcdc5cb327c2a31857ea219f445581d0eaffb9828f2cbf68ea`로 불변이다.
최종 capacity 값은 [`capacity-plan.md`](../capacity-plan.md)가 소유한다.

## rollback

적용 전 rollback 지점은 작업 시작 `origin/main` SHA
`da6f70b03048fe5858f57e8a75b8cf99edf2dea1`, VMID 120 memory 24,576 MiB, boot ID
`5bbaeac3-55f3-4f22-bdd2-16618c7dc415`, pre-state SHA-256
`abd55833087fec91e019da764121d410ab7906c4aaee80fabf469aa055972c5d`다. state 원문은
저장소 밖 mode `0600` 사본에만 둔다.

- apply 전 gate가 실패하면 라이브 변경 없이 멈추고 plan을 폐기한다.
- apply가 실패하면 같은 plan을 반복 실행하거나 `qm set`, `tofu state rm`, 수동 import,
  state 원문 편집으로 우회하지 않는다. provider task와 live/state 차이를 먼저 특정한다.
- RAM 변경 뒤 guest가 정상화되지 않으면 시작 SHA의 24,576 MiB 선언으로 별도 rollback
  binary plan을 만든다. VMID 120 memory 한 건의 `0 add, 1 change, 0 destroy`인지 확인하고
  적용한 뒤 정상 재부팅 한 번으로 원래 RAM을 복원한다.
- pre-state 사본은 state 손상 복구점이지 라이브 RAM을 단독으로 되돌리는 수단이 아니다.
  라이브가 28 GiB인데 state만 과거로 덮어쓰지 않는다.
- guest가 부팅하지 않으면 반복 재부팅하지 않고 Proxmox console·task log로 원인을 확인한다.
  Proxmox host 재부팅, VM 삭제·disk 변경은 범위 밖이며 별도 승인 없이는 하지 않는다.
- Falco 보상 정책 검증이 실패하면 `platform-root`를 기록한 시작 main SHA로 복원하고 두 child의
  literal `main`과 정책·예외 prune을 확인한다. 기존 Falco Pod는 유지되지만 다시 만들 수 없으므로
  이 상태는 운영 rollback 지점일 뿐 완료 상태가 아니며, 같은 브랜치에서 원인을 고친다.

rollback 뒤 VMID 120의 24,576 MiB·balloon 0, guest boot, k3s Ready, Argo 전체
`Synced/Healthy`, OpenTofu no-op을 확인한다. 실패한 작업은 merge하지 않고 같은 `CAP-03`
브랜치에서 원인을 고친다.
