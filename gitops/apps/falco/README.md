# Falco runtime 탐지 기준선

이 디렉터리는 `FALCO-01`의 컨테이너·노드 runtime 탐지만 소유한다. NetworkPolicy와
Kyverno 정책, Suricata 네트워크 IDS, CrowdSec AppSec/WAF, 방화벽, 공개 경로와 자동 대응은
소유하지 않는다. Wazuh·Loki·Shuffle 전송도 후속 작업 전까지 비활성이다. 경보는 JSON 한 줄
stdout에만 남고 kubelet의 Pod log 보존 경계를 따른다.

## 고정 버전과 engine

- 공식 Falco chart `9.1.0`, Falco `0.44.1`, falcoctl `0.13.0`, container plugin `0.7.1`을
  사용한다. chart tarball SHA-256과 모든 OCI index/amd64 digest는
  [`release-metadata.env`](release-metadata.env)가 소유한다.
- 라이브 `k3s-01`은 Rocky Linux 9.8, kernel
  `5.14.0-687.10.1.el9_8.0.1.x86_64`, containerd `2.3.2-k3s2`이고 BTF와 BPF JIT가 있다.
  공식 조건인 BPF ring buffer와 BTF를 쓰는 `modern_ebpf`를 명시한다. 별도 kernel module,
  host header, driver download/build는 없다.
- image의 `config.d` 기본 plugin 선언은 읽지 않고 chart가 생성한 고정 digest container plugin
  선언 하나만 로드한다. 두 선언을 함께 읽으면 동일 이름 plugin 중복 등록으로 Falco가 시작하지
  못한다.
- chart 원본은 values로 렌더링해 [`install.yaml`](install.yaml)로 저장한다. 재생성은 아래 한
  경로만 사용하며 결과 hash가 metadata와 일치해야 한다.

```bash
helm template falco \
  https://github.com/falcosecurity/charts/releases/download/falco-9.1.0/falco-9.1.0.tgz \
  --namespace falco \
  --kube-version 1.36.2 \
  --skip-tests \
  --values gitops/apps/falco/values-falco-01.yaml \
  > gitops/apps/falco/install.yaml
sed -i 's/[[:space:]]\+$//' gitops/apps/falco/install.yaml
```

## 권한과 host 접근

Falco container는 `privileged: false`, `allowPrivilegeEscalation: false`, read-only root
filesystem, `RuntimeDefault` seccomp, AppArmor unconfined과 capability
`BPF`·`PERFMON`·`SYS_RESOURCE`·`SYS_PTRACE`만 쓴다. AppArmor unconfined은 eBPF program load와
host process 관찰을 막지 않기 위한 chart의 engine 전용 예외다. host PID/network namespace,
hostPath `/boot`·`/lib/modules`·`/usr`·`/etc`는 주지 않는다.

Rocky Linux 9.8의 SELinux `container_t`에서는 위 capability와 seccomp의 `bpf`·
`perf_event_open` 허용이 있어도 host `/proc` 읽기와 BPF ring buffer map 생성이 `EACCES`로
거부됐다. 따라서 본 Falco container에만 `spc_t`를 적용하고 artifact init은 `container_t`로
유지한다. `spc_t`는 넓은 SELinux 예외이므로 `privileged: false`, 고정 capability, 아래 세
host mount로 경계를 제한한다. Falco가 더 좁은 전용 SELinux type을 공식 제공하거나 host 밖
sensor가 같은 metadata를 제공하면 이 예외를 제거한다.

남기는 host 접근은 세 가지뿐이다.

| 경로 | mode | 이유 | 재검토 조건 |
|---|---|---|---|
| `/proc` → `/host/proc` | read-only | event의 process/container 관계 해석 | Falco가 host proc 없이 같은 metadata를 제공할 때 |
| `/sys/kernel` | read-only | CO-RE BTF와 modern eBPF engine 초기화 | Falco chart가 더 좁은 BTF mount를 공식 지원할 때 |
| k3s CRI socket 하나 | read-only mount | namespace·Pod·container metadata 해석 | CRI proxy 또는 k8s-metacollector가 더 작은 권한·자원으로 검증될 때 |

CRI Unix socket 연결 자체는 강한 host 권한이다. 그래서 socket 후보 자동 탐색을 끄고
`/run/k3s/containerd/containerd.sock` 하나만 고정한다. Kubernetes API RBAC, ServiceAccount
token, k8s-metacollector는 모두 없으며 ServiceAccount와 Pod의 token automount도 끈다.
Falco와 init container image는 digest로 고정하고 plugin도 OCI index digest로 설치한다.

상시 request/limit은 Falco `100m/512Mi`와 `1 CPU/1Gi`, 일회성 artifact init은
`20m/32Mi`와 `100m/128Mi`다. PVC와 Service는 없고 writable volume은 process state와
artifact 전달, 8Mi Sigstore 검증 cache용 bounded `emptyDir`뿐이다. init root filesystem은
계속 read-only다.

## rule과 출력 경계

공식 전체 ruleset은 command line·파일 경로·I/O buffer처럼 민감한 원문을 output field에 넣을
수 있으므로 FALCO-01에서 그대로 활성화하지 않는다. 이 기준선은 다음 네 rule만 로드한다.

- 완료 증거 namespace와 marker path만 맞는 `FALCO-01 Test Runtime File Write`
- 컨테이너의 TTY 연결 shell 실행
- 컨테이너 표준 binary directory 쓰기
- 컨테이너 mount syscall 시도

rule condition은 syscall과 경로를 판정할 수 있지만 event output에는 `time`, `rule`, `priority`,
`namespace`, `pod`, `container`, `process`만 남긴다. `output`·`message`·tag, command arguments,
파일 경로·내용, I/O buffer는 출력하지 않고 `snaplen: 0`으로 둔다. stdout 외 syslog·file·HTTP·
program output은 모두 끈다. metrics는 외부 Service 없이 Pod-local `/metrics`에만 두며 실패 시
rule match와 stdout output 단계를 구분하는 데만 쓴다.

## 완료 증거와 noise 기준

[`verify-live.sh`](../../tools/falco-01/verify-live.sh)는 `ARGO-ROOT` 잠금 아래 다음 항목만 한 번
검증한다.

1. immutable 설정 SHA의 Falco child와 pointer SHA의 `platform-root`가 `Synced/Healthy`,
   DaemonSet이 `1/1` Ready인지 확인한다.
2. 고유한 전용 namespace에서 digest 고정 BusyBox 비특권 Pod 하나가 3초 뒤 emptyDir의
   `/tmp/falco-01-runtime-event`를 실제로 생성한다. JSON Pod log 단일 경로에서 전용 rule을
   확인한 즉시 namespace와 Pod를 삭제한다.
3. 삭제 뒤 60초 고정 창을 딱 한 번 관찰한다. 전체 runtime event와 상위 rule을 세고
   `시간당 비율 = event 수 × 60`으로 환산한다. 총 `0–1건`(`0–60건/시간`)은 기준선 통과,
   2건 이상은 완료하지 않고 상위 rule의 workload/condition 원인을 확인한 최소 조정만 한다.
4. 배포 전 한 번 기록한 available RAM과 검증 뒤 한 번 측정한 RAM·swap·Falco working set을
   비교한다. available `8GiB` 미만 또는 swap 사용은 rollback 정지 조건이다.

실패 메시지는 `deployment`, `kernel/driver`, `rule_match`, `output`, `noise`, `capacity` 단계로
구분한다. 이벤트를 stdout과 metrics 두 경로로 성공 증명하지 않으며 metrics rule counter는
stdout event가 없을 때 `rule_match`와 `output`을 구분하는 실패 진단에만 사용한다.

## 2026-08-03 라이브 검증 결과

- 설정 SHA `5edc2425615fde3a8776b8e165dca6cfe468ad97`와 root pointer
  `02b033a22bfccaf7282ad622461e7559748c69ea`에서 root·Falco child가
  `Synced/Healthy`, DaemonSet이 `1/1 Ready`였고 modern eBPF가 초기화됐다.
- 비특권 BusyBox Pod가 전용 namespace의 `emptyDir`에 실제 marker 파일을 썼다. 단일 JSON
  stdout 경로에서 `2026-08-03 00:59:38 KST`, rule
  `FALCO-01 Test Runtime File Write`, priority `Notice`와 namespace·Pod·container를 확인한
  직후 테스트 namespace를 제거했다.
- 테스트 제거 뒤 `2026-08-03 01:00:06 KST`부터 60초간 관찰한 event는 `0건`, 환산
  `0건/시간`, 상위 noisy rule은 `없음`이었다. 통과 기준 `0–1건`(`0–60건/시간`)을 만족해
  rule 예외를 추가하지 않았다.
- 적용 전/후 available RAM은 `11,169/10,994MiB`(증분 `-175MiB`), swap은 모두 0이었다.
  사후 Falco working set `134MiB`, CPU `7m`, node memory `12,996MiB`, root 사용률 `14%`,
  PVC 요청 합계 `66.125GiB`였다. 12GiB 경고 구간이지만 8GiB 정지선 위이므로 **GO**다.
- 실패 단계는 순서대로 artifact init의 read-only Sigstore cache, 배포 설정의 container plugin
  중복, kernel/driver 초기화의 SELinux `container_t` EACCES였다. 각각 bounded Sigstore
  `emptyDir`, image 기본 plugin config 제외, 본 Falco container만 `spc_t` 적용으로 원인을
  제거했고 자동 차단이나 다른 탐지 계층은 변경하지 않았다.
- 검증 뒤 시작 main `bd96f29097fbf5c6e0ae9f93a75f80d395932947`로 rollback해
  Falco Application·AppProject·namespace와 테스트 namespace가 없고 root가 다시
  `Synced/Healthy`임을 확인했다. 최종 child 선언은 `main`이다.

## immutable 동기화와 rollback

정상 선언은 child `targetRevision: main`이다. merge 전에는 최신 `origin/main`으로 rebase한
설정 commit을 먼저 push하고, 다음 pointer commit에서 Falco child만 설정 SHA로 고정한다.
`platform-root`는 pointer SHA를 읽는다. mutable branch 이름은 어느 Application에도 넣지 않는다.

branch 검증 rollback은 다음 순서를 지킨다.

1. 시작 main SHA를 확인한 뒤 `platform-root`의 automated sync를 잠시 끈다.
2. Falco child를 foreground 삭제해 DaemonSet·ConfigMap·ServiceAccount·namespace가 제거될
   때까지 기다린다. eBPF program도 Falco process 종료와 함께 해제된다.
3. prune 보호한 `falco` AppProject를 삭제한다.
4. `platform-root.spec.source.targetRevision`과 automated sync를 시작 main SHA로 복원하고
   `Synced/Healthy`를 확인한다.
5. 작업 branch의 최종 child 선언을 `main`으로 되돌린 뒤에만 `ARGO-ROOT` 잠금을 푼다.

responseActions/Falco Talon, Falcosidekick, Wazuh/Loki/Shuffle, 방화벽·NetworkPolicy 변경은 이
rollback과 작업 범위에 포함하지 않는다. 사건 대응 순서는
[`Falco runtime event 대응 초안`](../../../docs/runbook/falco-runtime-response.md)이 소유한다.
