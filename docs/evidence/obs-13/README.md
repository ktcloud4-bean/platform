# OBS-13 상시 alert rule과 실제 알림 채널 증거

## 상시 alert rule 4종(5개 alertname)

[`gitops/apps/obs/alerting-rules.yaml`](../../../gitops/apps/obs/alerting-rules.yaml)이 소유한다.

| alertname | expr 요약 | for | threshold 근거 |
|---|---|---|---|
| `NodeDown` | `up{job="node-exporter"} == 0` | 5m | backlog가 지정한 값. 30초 scrape interval 기준 약 10회 연속 실패라 단발성 scrape 실패를 걸러낸다. |
| `RootFilesystemUsageWarning` | root filesystem 사용률 > 85% | 10m | 로그 회전·임시 파일 churn 같은 일시적 스파이크를 거르면서도 critical 전에 조치할 시간을 준다. |
| `RootFilesystemUsageCritical` | root filesystem 사용률 > 95% | 5m | 디스크가 거의 찬 상태라 warning보다 확인 창을 짧게 잡아 더 빨리 올린다. |
| `TLSCertificateExpiringSoon` | 인증서 잔여시간 < 14일 | 10m | 14일이라는 큰 예산 대비 probe 한 번의 flakiness를 거르는 데는 10분이면 충분하다(1시간은 과함). |
| `VeleroBackupFailed` | `velero_backup_failure_total` 또는 `velero_backup_partial_failure_total`이 지난 1시간 안에 증가 | 0m | 이미 끝난 실패 이벤트라 sustained 조건이 필요 없다. 완전 실패 metric만 보면 라이브 실측상 partial failure(예: selector가 아무 것도 못 찾은 backup)를 놓치므로 둘 다 포함한다(아래 "Velero 실패 실측" 참고). |

## root filesystem 사용률이 "PVC 사용률"을 대신하는 이유

이 클러스터는 단일 노드 `k3s-01` + `local-path` provisioner([ADR-0002](../../adr/0002-single-node-k3s-and-local-storage.md))라
PVC 요청량이 디렉터리 하드 쿼터가 아니다. 모든 PVC 데이터가 물리적으로 `k3s-01`의 root
disk 위에 있으므로, root filesystem 사용률이 곧 PVC 용량 위험 신호와 같다. `kubelet_volume_stats_*`
(PVC별 실사용량)는 kubelet cAdvisor 전체 scrape가 있어야 나오는데, `values-kube-prometheus-stack-01.yaml`의
`kubelet.enabled: true`가 `install.yaml`에 반영되지 않은 채 방치된 기존 drift(`OBS-11`이 이미
발견)라 이번에 새로 켜는 대신, root filesystem 사용률만으로 같은 위험을 잡는다. 이 결정은
`OBS-09`가 cAdvisor container-level metric을 의도적으로 수집 경계 밖에 둔 결정과도 맞는다.

## k3s-01 root filesystem 보완용 host-level node_exporter

기존 `obs-prometheus-node-exporter` DaemonSet(port 9100, hostNetwork)은 `runAsUser: 65534`
non-root securityContext 때문에 `/proc/1/mountinfo`를 읽지 못해 filesystem collector만
실패한다(`OBS-11`이 이미 발견하고 "권한을 약화하지 않는다"는 원칙상 확대하지 않기로
판정한 기존 한계). 이 DaemonSet은 그대로 두고, 같은 host에 `infra/ansible/roles/node_exporter_baseline`
role을 port 9101로 한 번 더 적용해(inventory group `node_exporter_root_k3s01`) filesystem
collector 하나만 보완한다. hostNetwork라 Prometheus Pod와 같은 host에서 나가는 트래픽이고
OPNsense를 거치지 않으므로 새 방화벽 rule은 없다. `gitops/apps/obs/network-policies.yaml`의
기존 `10.10.20.10/32` egress에 port 9101 한 줄만 추가했다. 새 target은 `job=node-exporter-root`로
fleet(`job=node-exporter`)과 분리해 `OBS-11`이 확정한 6-target 집계를 건드리지 않는다.

## 실제 채널: 상시 obs-13-receiver (Wazuh·Shuffle 대신)

backlog 원안은 "기존 Wazuh manager나 Shuffle 중 하나로 webhook forward"였으나, 둘 다 라이브로
실측한 결과 "기존 endpoint에 연결"이 아니라 새 통합 지점을 만드는 작업이었다.

- **Wazuh manager**: HTTP JSON을 받는 경로가 없다(agent 프로토콜과 API뿐). 받으려면 새 webhook
  브리지 컨테이너와 `<localfile>`+decoder/rule을 새로 만들어야 해 `gitops/apps/wazuh/`까지 범위가
  넘어가고 SIEM에 새 수집 경로를 여는 결정이 된다.
- **Shuffle**: `SOAR-DASH-01`이 의도적으로 Orborus(워크플로 실행 엔진)를 배포하지 않고 외부
  egress를 전부 막아뒀다. Webhook trigger가 동작하려면 최소 action 노드 1개가 있는 workflow가
  필요한데, action app(예: Shuffle Tools)을 붙이려면 backend가 `shuffler.io`에서 앱 정의를
  다운로드해야 하고 이는 NetworkPolicy egress 부재로 전부 `connection refused`다. 이 저장소는
  모든 외부 다운로드를 SHA-256/digest로 고정하는데 Shuffle의 앱 다운로드는 그런 고정
  메커니즘이 없는 third-party 레지스트리 실시간 fetch라, 열면 공급망 원칙을 이 지점에서만
  깨게 된다.

대신 `OBS-01`의 임시 검증용 receiver 패턴(non-root, capability drop, pinned python 이미지)을
지우지 않고 상시화했다. [`gitops/apps/obs/alerting-receiver.yaml`](../../../gitops/apps/obs/alerting-receiver.yaml)의
`obs-13-receiver` Deployment는 Alertmanager webhook을 받아 `/metrics`로 `obs13_alerts_received_total`·
`obs13_alert_last_received_timestamp_seconds`를 노출하고, 같은 `obs` namespace의 기존
ServiceMonitor를 통해 Prometheus가 다시 긁어간다. `obs` namespace 안이라 `obs-internal`
NetworkPolicy(모든 obs Pod 상호 허용)가 이미 Alertmanager→receiver, Prometheus→receiver 경로를
열어 새 NetworkPolicy가 필요 없다. 새 credential·외부 egress·cross-namespace 방화벽은 0건이다.
`SOAR-01`이 나중에 만들 Wazuh 경보의 정보 보강·통지·승인 흐름과는 겹치지 않는다(이 receiver는
action이 없고 수신 확인용일 뿐이다).

Alertmanager route는 5개 alertname만 `obs-13-receiver`로 보내고 나머지는 여전히 `discard`다.
silence 변경 `/platform-privileged` 경계(`gitops/apps/pomerium/pomerium-conf.yaml`)는 바꾸지 않았다.

## Velero 실패 실측

`velero_backup_failure_total`(완전 실패)은 실제로 재현하려면 `default` BackupStorageLocation의
연결성을 직접 깨야 해서 운영 backup 경로를 건드리는 위험이 있다. 존재하지 않는
`includedNamespaces` selector로 안전하게 만든 throwaway Backup은 라이브 실측 결과
`PartiallyFailed`(=`velero_backup_partial_failure_total` 증가)로 끝나고 완전 실패 metric은
증가하지 않았다. `VeleroBackupFailed` rule이 두 metric을 모두 잡도록 넓힌 이유다.

## 라이브 검증

[`verify-live.sh`](../../../gitops/tools/obs-13/verify-live.sh)가 `capacity-pre`로 배포 전
기준을 기록하고 `verify` 한 번으로 판정한다. 실제 조건은:

- `NodeDown`: netbird-01 `node_exporter` systemd 정지(5분 이상)
- `RootFilesystemUsageWarning`/`Critical`: 실측 root 사용률(fleet 1.7~9.6%, k3s-01 약 22%)이
  넘도록 임계값만 낮춘 별도 임시 PrometheusRule(`obs-13-verify-thresholds`, git 밖 ad-hoc
  객체라 Argo prune/selfHeal 대상이 아님)을 같은 alertname으로 병행 적용. 실제 선언 rule(85/95%)은
  건드리지 않는다.
- `TLSCertificateExpiringSoon`: 실측 잔여일(약 79일)이 넘도록 cutoff를 14일에서 85일로 늘린
  같은 임시 PrometheusRule.
- `VeleroBackupFailed`: 위 안전한 PartiallyFailed backup 재현.
