# Falco runtime event 대응 초안

- 작성일: 2026-08-03
- 대상: `falco` namespace DaemonSet이 JSON stdout에 남긴 container·node runtime event
- 소유 범위: 탐지 확인과 read-only 조사, 사람 승인 뒤의 격리·복구 판단
- 제외: 자동 차단, Falco Talon/active response, 방화벽·공개 경로 변경, Wazuh/Loki/Shuffle 연동
- rollback 기준: event와 workload를 잘못 연결했거나 격리가 독립 복구·관리 경로를 끊으면 즉시 원복
- 전제: Falco Application·DaemonSet이 `Synced/Healthy`·Ready이고 대응자가 read-only Kubernetes
  조회 권한과 해당 workload의 GitOps 원본을 읽을 수 있어야 한다. 변경은 별도 소유 작업과 사람
  승인이 있어야 한다.

## 1. 탐지 확인

1. JSON 한 줄에서 `time`, `rule`, `priority`, `namespace`, `pod`, `container`, `process`만 읽는다.
2. 같은 event를 Kubernetes Event나 별도 Falco output으로 다시 증명하지 않는다. Falco Pod log의
   JSON stdout 한 경로를 원본으로 둔다.
3. 필수 field가 없거나 JSON이 아니면 대응을 시작하지 않고 Falco `output` 장애로 분류한다.
   DaemonSet Ready 실패는 `deployment`, modern eBPF 초기화 오류는 `kernel/driver`, 실제 행위 뒤
   rule counter가 0이면 `rule_match` 단계다.
4. command arguments, environment, Secret, token, 파일 내용은 ticket·채팅·명령 출력에 복사하지
   않는다.

## 2. workload·사용자·시각 식별

1. event의 namespace/Pod/container를 exact match로 조회하고 Pod UID, node, image digest,
   ServiceAccount, labels와 ownerReferences를 기록한다.
2. owner chain을 ReplicaSet→Deployment, Job→CronJob처럼 읽기 전용으로 따라가 GitOps 선언과
   현재 image digest를 대조한다. event 시각과 Pod start time이 맞지 않으면 이름 재사용을
   의심하고 UID 기준으로 다시 판정한다.
3. Falco syscall event만으로 사람 사용자를 단정하지 않는다. Kubernetes API 행위라면 후속
   audit source에서 같은 시각·object UID의 actor를 찾고, Warpgate/Pomerium/애플리케이션 접근은
   해당 소유 로그의 사용자·request/session ID로 보강한다. audit 수집 전에는 `미확인`으로 둔다.

안전한 조회 예시는 다음과 같다. `<namespace>`·`<pod>`는 event의 exact 값으로 치환한다.

```bash
kubectl -n <namespace> get pod <pod> -o json \
  | jq '{uid:.metadata.uid,node:.spec.nodeName,serviceAccount:.spec.serviceAccountName,
         images:[.spec.containers[]|{name,image}],owners:.metadata.ownerReferences,
         started:.status.startTime}'
kubectl -n <namespace> get deployment,statefulset,daemonset,job,cronjob \
  -l app.kubernetes.io/name=<label> -o name
```

## 3. 읽기 전용 조사

1. Pod phase·restart·container state, controller desired/ready, node Ready·pressure를 조회한다.
2. Git의 해당 Application·workload 선언과 live imageID를 digest 기준으로 비교한다.
3. 필요한 경우 해당 workload의 기존 운영 로그를 event 시각 주변의 짧은 범위로 조회하되 Secret,
   token, cookie, command arguments, body/file content를 수집하거나 공유하지 않는다.
4. `kubectl exec`, ephemeral container, packet capture, host process kill, 파일 복사·수정은 read-only
   조사가 아니므로 이 단계에서 실행하지 않는다.
5. 예상된 관리 작업이면 승인자·작업 ID·시간을 연결하고 종료한다. 설명되지 않으면 영향 범위와
   독립 복구 경로를 먼저 확인한 뒤 격리 판단으로 넘긴다.

## 4. 사람 승인형 격리 또는 복구 판단

자동 대응은 없다. 운영자가 다음 중 한 가지를 명시적으로 승인하고, 각 리소스 소유 작업의
rollback을 함께 적은 뒤 실행한다.

- 단일 workload 중지/scale-down 또는 알려진 정상 digest로 GitOps 복구
- 별도 승인된 namespace NetworkPolicy로 제한(정책 소유 범위에서 수행)
- node 격리가 필요한 경우 관리·Vault·백업 복구 경로 영향을 먼저 평가
- 방화벽·공개 DNS·외부 노출 변경은 별도 잠금과 승인이 있는 네트워크 작업으로 이관

Secret/token 노출이 증명된 경우에도 rotation은 자동으로 하지 않는다. 영향 credential과 소비자를
식별해 credential 교체 승인 절차로 이관한다. 단일 노드 k3s 재시작, 물리 host 재시작, PVC·VM·
disk 삭제는 FALCO-01 대응 권한이 아니다.

## 5. rollback과 종료

1. 격리에 사용한 exact patch/scale/정책을 역순으로 원복하고 GitOps가 알려진 정상 main 선언을
   다시 소유하게 한다.
2. 대상 Application과 workload가 `Synced/Healthy`·원래 replica/Ready로 돌아왔는지 확인한다.
3. 독립 관리·복구 경로가 유지되는지 해당 작업의 기존 증거 범위에서 확인한다.
4. 잘못된 rule이면 광범위 disable 대신 확인된 workload/condition 하나만 최소 예외로 만들고,
   같은 고정 noise 창을 다음 FIX 작업에서 검증한다. 공개 main 이력은 다시 쓰지 않는다.
5. 기록에는 event의 안전한 metadata, 판단 근거, 승인자, 실행·rollback 시각, 남은 후속 작업만
   남긴다. raw command line·환경·Secret·파일 내용은 남기지 않는다.
