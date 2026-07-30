# 단일 노드 k3s·SQLite 기준선

- 검증일: 2026-07-31
- 작업: `K3S-01`
- 잠금: `K3S-BOOTSTRAP`
- 주소 단일 원본: [`docs/ip-plan.md`](../ip-plan.md)
- 설계 결정: [ADR-0002](../adr/0002-single-node-k3s-and-local-storage.md)

## 목적과 경계

`k3s-01`에 단일 server 노드 k3s를 배포하고 기본 SQLite datastore,
CoreDNS, Traefik, ServiceLB, local-path StorageClass와 metrics-server를 유지한다.
etcd·외부 DB·Longhorn·Ceph를 사용하지 않으며 GitOps 앱, Ingress,
NetworkPolicy와 플랫폼 서비스는 배포하지 않는다.

구현은 `infra/ansible/playbooks/k3s-baseline.yml`과
`infra/ansible/roles/k3s_baseline/`이 소유한다. inventory와 trusted
`known_hosts`는 저장소 밖에 두며 kubeconfig와 token 원문은 출력하거나 복사하지 않는다.

## 고정 배포물과 무결성

| 항목 | 검증된 값 |
|---|---|
| 선택 채널 | 설치 전 `stable` 채널 조회 |
| 고정 버전 | `v1.36.2+k3s1` |
| release commit | `01b6f04aaa69e8b09303f0393d4b4f1811da23aa` |
| binary SHA-256 | `65a55ec56c24eab44383086166ec620a491952b7e23941a49ddca6e8a4c4b4de` |
| 고정 install script SHA-256 | `46177d4c99440b4c0311b67233823a8e8a2fc09693f6c89af1a7161e152fbfad` |
| SELinux 정책 | `k3s-selinux-1.6-1.el9.noarch`, Rancher RPM GPG key 검증 |

release binary에는 별도 서명 asset이나 GitHub artifact attestation이 없었다. 따라서
공식 checksum 파일, GitHub release asset digest와 고정 release commit의 install
script checksum을 함께 사용한다. SELinux RPM은 GPG 서명을 별도로 검증한다.

## 적용 전 gate

다음을 모두 확인하고 설치 승인을 받는다.

1. `K3S-01 READY`, 선행 `VM-01 DONE`, `K3S-BOOTSTRAP` 비점유
2. 전용 branch와 clean `main`, 다른 worktree·세션의 동일 잠금 부재
3. trusted known_hosts 양성 접속과 위조 known_hosts 음성 실패
4. Rocky Linux 9, swap 0, SELinux Enforcing, firewalld inactive
5. 기본 Pod·Service 대역과 예정 포트 충돌 없음
6. 정확한 버전, checksum, upstream 서명 부재, guest 변경과 rollback 영향 보고
7. `--syntax-check`, `--check --diff` 성공

승인 전 실제 playbook 실행, package 설치, service 시작과 재부팅을 하지 않는다.

## 실행

주소와 SSH key 경로는 저장소 밖 inventory에서 제공한다.

```bash
cd infra/ansible
export ANSIBLE_SSH_COMMON_ARGS="-o StrictHostKeyChecking=yes -o UserKnownHostsFile=<trusted-known-hosts> -o PasswordAuthentication=no"
ansible-playbook -i <outside-inventory> playbooks/k3s-baseline.yml --syntax-check
ansible-playbook -i <outside-inventory> playbooks/k3s-baseline.yml --check --diff
# 승인 뒤에만 실행
ansible-playbook -i <outside-inventory> playbooks/k3s-baseline.yml
```

role은 다음을 선언한다.

- Rancher GPG key와 SELinux repository, `container-selinux`, 고정 `k3s-selinux`
- checksum으로 검증한 `/usr/local/bin/k3s`와 SELinux 실행 context
- root mode `0600`의 `/etc/rancher/k3s/config.yaml`
- 고정 commit의 공식 install script가 만드는 systemd unit과 제거 script
- k3s service `enabled`, `active`

설정에는 `write-kubeconfig-mode: "0600"`과 `selinux: true`만 둔다. node 주소,
advertise 주소, Pod·Service CIDR, datastore endpoint와 disable 목록을 고정하지 않는다.

## 성공 판정

세 계층을 각각 확인한다.

### 게스트

- k3s binary 버전·SHA-256과 SELinux context 일치
- service `active`, `enabled`; `overlay`, `br_netfilter`와 필요한 sysctl 활성
- kubeconfig와 server token은 위치·소유자·mode만 확인
- failed systemd unit 0, swap 0, chronyd 동기화, AVC 없음

### Kubernetes API

- 단일 control-plane Node `Ready`, 예상 Kubernetes·containerd 버전
- CoreDNS, Traefik, ServiceLB, local-path-provisioner, metrics-server 정상
- Traefik이 유일한 default ingress class이고 local-path가 default StorageClass
- SQLite 파일 존재, read-only `PRAGMA quick_check=ok`, etcd port·process·설정 없음

API readyz에 표시되는 `etcd` check 이름은 Kubernetes storage health check 이름이다.
그 문자열만으로 etcd datastore 사용 여부를 판정하지 않는다.

### 실제 통신

- 임시 Pod에서 `kubernetes.default.svc.cluster.local` 해석
- Traefik LoadBalancer 주소로 요청해 실제 Traefik 응답 확인
- 임시 PVC를 Bound시키고 marker를 쓴 뒤 재부팅 후 새 Pod에서 같은 내용을 읽음
- `vlan-verify run --profile bootstrap`의 MGMT control과 project VLAN probe 전부 PASS
- VLAN 10 임시 namespace에서 API 6443 접근 확인

검증용 namespace·Pod·PVC·PV와 Proxmox namespace·veth는 모두 제거한다. Proxmox
`/etc/network/interfaces` SHA-256이 전후 같아야 한다.

## 2026-07-31 라이브 결과

| 항목 | 결과 |
|---|---|
| k3s | `v1.36.2+k3s1`, service active/enabled |
| Node | `Ready`, containerd `2.3.2-k3s2` |
| SQLite | `server/db/state.db`, WAL, `quick_check=ok`, etcd listener·process 없음 |
| 기본 구성요소 | CoreDNS·Traefik·ServiceLB·local-path·metrics-server 정상 |
| 통신 | 내부 DNS 성공, 게스트와 HOME에서 Traefik HTTP 응답 확인 |
| PVC | 16 MiB 동적 PVC Bound, 재부팅 후 marker SHA-256·내용 유지 |
| 재부팅 | QGA·strict SSH 16초, Node Ready boot 기준 47초 |
| 멱등성 | 공통 baseline과 k3s role 모두 `changed=0`, `failed=0` |
| NET-03 | 설치 후·재부팅 후 MGMT와 k3s 각각 18/18 PASS, MGMT 6443 ALLOW |
| 자원 | k3s 데이터 약 1.31 GiB, Node memory 약 1.24 GiB, guest root 2% |

## 실제로 확인한 함정

### 설치된 package의 불필요한 metadata refresh

이미 정책 package가 설치됐는데도 DNF에 `update_cache`를 매번 실행하면 일시적인
mirror HTML 응답을 `repomd.xml`로 해석해 멱등 실행이 실패할 수 있다. 설치된
`k3s-selinux` NEVRA를 먼저 확인하고 두 정책 package가 모두 있으면 DNF를 건너뛴다.

### VLAN 10 임시 client

VLAN-aware bridge에 veth를 붙이기만 하면 untagged traffic이 VLAN 10으로 들어가지
않는다. 이 세션이 만든 veth에만 `vid 10 pvid untagged`를 일시 적용한다. Proxmox
자기 관리 주소를 source로 쓰면 local route라 control 판정이 무효다.

### local-path 삭제 helper

SELinux Enforcing에서 test PVC 삭제 helper가 exit 1과 120초 timeout을 냈다. writer
Pod의 MCS label이 남은 경로와 별도 helper Pod label의 불일치가 원인으로 추정되지만
AVC가 기록되지 않아 확정하지 않았다. 이 세션이 만든 marker 하나를 확인한 뒤 정확한
파일은 `rm -f`, 빈 디렉터리는 `rmdir`로 제거했고 PV·helper까지 사라진 것을 확인했다.

기본 local-path 설정이나 SELinux를 완화하지 않는다. `STOR-01`에서 재현·원인·안전한
보정 여부를 다시 판정한다.

## rollback

공식 `/usr/local/bin/k3s-uninstall.sh`는 service와 unit, binary·symlink,
`/etc/rancher/k3s`, `/var/lib/rancher/k3s`, kubelet·CNI 상태, SQLite datastore와
local-path 데이터를 제거한다. 실행 전 삭제 영향을 다시 승인받는다.

제거 후 interface, iptables, mount, data directory와 SELinux package·RPM key 잔여를
확인한다. 게스트가 복구 불가능하면 VM 재생성이 최후 수단이지만 OpenTofu state를
소유하지 않는 세션에서는 실행하지 않고 보고 후 중단한다.

## 시크릿 경계

- kubeconfig, node/server token 원문을 Git·채팅·일반 로그에 남기지 않는다.
- backup에는 존재·경로·mode만 기록한다.
- 실제 inventory와 raw 검증 자료는 저장소 밖 mode `0600`으로 보관한다.
