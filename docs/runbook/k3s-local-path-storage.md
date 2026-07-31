# k3s local-path `local` PV와 SELinux 자동 삭제

- 검증일: 2026-07-31
- 작업: `STOR-01`
- 잠금: `K3S-BOOTSTRAP`
- 선행: `K3S-01`
- 설계 결정: [ADR-0002](../adr/0002-single-node-k3s-and-local-storage.md)
- 용량 기준: [`capacity-plan.md`](../capacity-plan.md)

## 목적과 경계

k3s의 기본 `local-path` StorageClass를 유지하면서 동적 PV가 `hostPath`가 아닌
`local` source를 사용하게 선언한다. PVC 요청량은 디렉터리 quota가 아니므로 작은
요청보다 큰 제한된 쓰기로 이를 확인하고, 재부팅 뒤 데이터와 SELinux Enforcing을
유지한 채 reclaim helper가 PV 경로를 자동 삭제하는지 검증한다.

Longhorn·Ceph·CSI 도입, 디스크 확장·재파티션, 다른 플랫폼 앱 배포는 이 runbook의
범위가 아니다. 생성된 PV 디렉터리명과 kubeconfig·token 원문은 출력하거나 기록하지
않는다.

## 선언 소유권

구현은 `infra/ansible/roles/k3s_baseline/`이 소유한다.

- k3s packaged `local-storage` AddOn은 `config.yaml`의 `disable` 목록에 둔다.
- 동일한 local-path-provisioner 버전과 기본 StorageClass를 Ansible 소유 AddOn으로
  배치한다.
- StorageClass의 `defaultVolumeType: local`, `Delete`,
  `WaitForFirstConsumer`를 명시한다.
- 저장소 root와 image 값은 role defaults가 단일 원본이다.
- helper용 SELinux policy 원본과 컴파일·설치, AddOn manifest를 같은 role에서
  선언한다.

k3s packaged manifest는 서비스 시작 때 원본으로 다시 쓰이고 AddOn으로 적용된다.
따라서 ConfigMap만 `kubectl patch`하거나 packaged manifest를 직접 수정하지 않는다.
공식 [`disable` 동작](https://docs.k3s.io/installation/packaged-components)으로 소유권
경쟁을 제거한 뒤 같은 provisioner를 별도 AddOn으로 유지한다.

## 재현 원인

변경 전 8Mi PVC와 작은 marker로 실패를 다시 만들었다.

| 증거 | 변경 전 결과 |
|---|---|
| PV source | `.spec.local=true`, `.spec.hostPath=false` |
| writer process·경로 label | 둘 다 같은 `container_t` MCS category |
| delete helper label | writer와 다른 임의 MCS category |
| helper 결과 | exit 1, 경로와 marker 잔존 |
| provisioner | `create process timeout after 120 seconds` |
| AVC | 0건 |

같은 시험 경로를 읽기만 하는 진단 Pod에서 기본 `container_t`의 다른 MCS는 marker
접근에 실패했고, SELinux 제약을 우회하는 `spc_t`는 접근했다. 그러나 `spc_t`는
사실상 비제약 도메인이므로 최종안에서 제외했다. 원인은 writer가 local volume을 자기
MCS로 재라벨한 뒤 별도 helper가 다른 MCS로 실행되어 teardown 대상에 접근하지 못한
것이다. AVC가 없었으므로 AVC 부재를 정상 근거로 사용하지 않는다.

## 선언형 해결

helper 전용 `k3s_local_path_helper_t` policy는 container-selinux의 표준
`svirt_sandbox_domain` 실행 경계를 쓰되 MCS 제약 예외 대상으로 선언한다. BusyBox
root filesystem과 local PV가 모두 `container_file_t`이므로 SELinux type만으로 파일
내용 권한을 더 세분화할 수 있다고 주장하지 않는다. 대신 helper가 볼 수 있는 host
경로를 provisioner가 주입하는 정확한 대상 PV mount 하나로 한정하고 Pod 실행 권한을
아래와 같이 제한한다.

local-path-provisioner v0.0.36은 custom helper `securityContext`를 기본 거부하므로
관리자가 소유한 template에 한해 명시적 opt-in을 사용한다. helper 자체는
`privileged`가 아니며 다음 제한을 함께 둔다.

- `allowPrivilegeEscalation: false`
- capability `ALL` drop
- read-only root filesystem
- `RuntimeDefault` seccomp
- ServiceAccount token 자동 마운트 비활성
- 관리 template에 임의 `hostPath` volume 없음
- teardown 입력이 선언된 storage root 바로 아래인지 검사

설정 형식과 `local` volume annotation, helper template 안전 검사는
[local-path-provisioner v0.0.36 문서](https://github.com/rancher/local-path-provisioner/tree/v0.0.36)를
따른다. SELinux level과 MCS가 volume 접근을 제한하는 방식은
[Red Hat SELinux options](https://docs.redhat.com/ko/documentation/openshift_container_platform/3.11/html/configuring_clusters/selinuxoptions)을
근거로 판정했다.

## 적용과 검증

실제 inventory와 trusted `known_hosts`는 저장소 밖에 둔다.

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<trusted-known-hosts> -o PasswordAuthentication=no"
ansible-playbook -i <outside-inventory> playbooks/k3s-baseline.yml --syntax-check
ansible-playbook -i <outside-inventory> playbooks/k3s-baseline.yml --check --diff
ansible-playbook -i <outside-inventory> playbooks/k3s-baseline.yml
ansible-playbook -i <outside-inventory> playbooks/k3s-baseline.yml
```

성공 판정은 다음을 모두 요구한다.

1. StorageClass annotation이 `local`이고 새 PV에 `.spec.local`만 존재한다.
2. 16Mi 요청 PVC에 32MiB 쓰기가 성공하되 전체 시험 데이터는 64MiB 이하다.
3. marker 내용과 SHA-256을 기록하고 정확한 k3s VM만 재부팅한다.
4. 새 boot ID와 Node Ready 뒤 같은 PVC를 mount한 소비 Pod에서 marker와 bounded
   file이 동일하다.
5. PVC 삭제 helper가 timeout 없이 성공하고 PV·helper·정확한 시험 경로가 자동으로
   사라진다.
6. Node, CoreDNS, Traefik, ServiceLB, metrics-server와 local-path-provisioner가
   정상이고 DiskPressure=False, failed unit 0이다.
7. syntax-check와 check/diff가 통과하고 두 번째 실제 적용이 changed=0, failed=0이다.
8. 검증 namespace·Pod·PVC·PV·helper와 storage child가 남지 않는다.

## 2026-07-31 라이브 결과

| 항목 | 결과 |
|---|---|
| k3s·provisioner | `v1.36.2+k3s1`, local-path-provisioner `v0.0.36` |
| PV source | `local=true`, `hostPath=false`, node affinity 일치 |
| capacity 미강제 | 16Mi 요청에 32MiB 쓰기 성공; DiskPressure=False |
| 재부팅 | boot ID 변경, Node Ready 뒤 같은 PVC의 writer 재생성, marker 내용·SHA-256 동일 |
| marker SHA-256 | `3c623bd725236988f5cc469b34eb0c0e4d7c6616cbca7fc28197ccbcae25776a` |
| 자동 reclaim | 최종 삭제 4초, PV·helper·시험 경로 자동 제거, 최종 PV의 `VolumeFailedDelete` 0 |
| SELinux | 재부팅 전후 Enforcing, helper policy priority 400, AVC 0 |
| 기본 구성요소 | CoreDNS 조회 PASS, Traefik·ServiceLB HTTP 도달, 모두 1/1 |
| 멱등성 | syntax-check 통과, check/diff `changed=0 failed=0`, 재적용 `changed=0 failed=0` |
| 정리 | 검증 namespace·Pod·PVC·PV·helper·storage child 0 |

PVC 요청량보다 큰 쓰기가 성공한 것은 quota 부재를 증명하지만, 노드 파일시스템을
얼마나 채울 수 있는지 시험한 것은 아니다. 실제 운영 제어는 PVC 선언 합계와 guest
여유율을 함께 보는 [`capacity-plan.md`](../capacity-plan.md)의 임계치를 따른다.

## 증거 한계

- K3S-01의 원래 Kubernetes Event는 시작 시 보존 기간이 지나 0건이었고 provisioner
  log의 과거 120초 timeout만 남아 있었다. STOR-01 재현 중 발생한
  `VolumeFailedDelete` Event object 3개는 원인 증거로 남았지만 최종 PV와 일치하는
  실패 Event는 0개다.
- 변경 전·후 AVC는 모두 0건이었다. 원인 판정은 MCS label 대조와 접근 성공/실패,
  helper exit, 경로 잔존으로 했다.
- 최종 성공 helper의 CRI metadata는 확인 시점에 이미 garbage collection됐다.
  같은 policy type의 제한 Pod가 exit 0인 것, 적용된 helper template, 자동 reclaim
  성공을 서로 다른 증거로 사용했다.
- `svirt_sandbox_domain`은 표준 container 파일 권한을 포함한다. 이 해결의 최소 권한
  경계는 SELinux 파일 permission 세분화가 아니라 비특권 securityContext와 helper가
  실제로 mount받는 단일 대상 경로다. template validator opt-in도 이 관리자 소유
  securityContext 때문에 필요하며, 사용자 입력 template을 허용하지 않는다.
- 32MiB 시험은 capacity가 하드 quota가 아님만 확인한다. 장기 사용량·eviction·실제
  백업 복원은 각각 capacity 관측과 `BKP-02` 범위다.
- `restartPolicy: Never`인 검증 writer는 재부팅 뒤 `Unknown`이어서 정확한 Pod만
  재생성했다. PVC/PV와 데이터 경로는 변경하지 않았고 새 소비 Pod에서 내용과 hash를
  비교했으므로 증거는 Pod 생존이 아니라 volume 데이터 유지에 한정한다.
- 초기 재현 진단 출력에서 이 세션의 실제 시험 경로가 한 번 노출됐다. 이후 출력은
  모두 마스킹했고 해당 경로는 최종 helper 성공으로 자동 제거됐지만, 노출 사실 자체는
  증거 한계로 남긴다.

## rollback

rollback은 local-path 데이터를 삭제하지 않는다.

1. 새 PVC 생성을 멈추고 현재 PVC/PV와 복구 가능한 백업을 확인한다.
2. Ansible 선언에서 custom AddOn을 제거하고 `disable: local-storage`를 되돌린다.
3. k3s를 한 번 재시작해 packaged `local-storage` AddOn과 동일 StorageClass가
   복원되는지 확인한다.
4. Node와 기존 PVC mount를 확인한 뒤에만 `k3s_local_path_helper` policy module을
   제거한다.
5. packaged helper의 SELinux 자동 삭제 실패가 다시 생기는 상태이므로 rollback 뒤
   PVC 삭제를 완료 증거 없이 수행하지 않는다.

PVC/PV나 storage root를 wildcard로 지우지 않는다. custom AddOn과 packaged AddOn을
동시에 유지해 같은 리소스를 경쟁시키는 것도 rollback으로 인정하지 않는다.
