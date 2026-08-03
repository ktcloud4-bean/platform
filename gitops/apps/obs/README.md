# OBS-01 metrics·경보 기준선

이 디렉터리는 단일 노드 `k3s-01`의 Prometheus Operator, Prometheus, Alertmanager,
node-exporter, kube-state-metrics, Grafana와 인증서 probe만 소유한다. Wazuh 보안 event,
Loki 수집 경계, 자동 대응, 방화벽, 공개 DNS·NAT·Ingress와 다른 앱의 선언은 소유하지 않는다.

## 수집 경계

| acceptance | target과 대표 시계열 | 선언 위치 |
|---|---|---|
| node | `obs-prometheus-node-exporter`, `node_uname_info` | 이 chart의 node-exporter |
| PVC | `obs-kube-state-metrics`, `kube_persistentvolumeclaim_info` | 이 chart의 kube-state-metrics |
| backup | `velero`, `velero_backup_total` | `obs`의 ServiceMonitor가 기존 `velero` Service를 선택 |
| certificate | `obs-blackbox`, `probe_success`, `probe_ssl_earliest_cert_expiry` | blackbox-exporter가 기존 Traefik의 `k3s-01.imcherry5778.xyz` TLS를 검증 |
| 수집 pipeline | `loki`·`alloy`, `loki_build_info`·`alloy_build_info` | `obs`의 ServiceMonitor가 기존 `loki` namespace Service를 선택 |

Prometheus는 `obs` namespace에 있는 `release=obs` ServiceMonitor와 PrometheusRule만
선택한다. Velero와 Loki 선언은 수정하지 않는다. OPNsense exporter·SNMP·방화벽 rule은
`OPN-METRICS-01`로 분리했으며 OBS-01 증거에 포함하지 않는다.

기존 인프라에는 cert-manager와 cert-manager 소유 Certificate가 없다. 인증서 완료 증거는
새 CA controller를 설치하는 대신 실제 외부 진입점인 Traefik `websecure` ClusterIP에 SNI
`k3s-01.imcherry5778.xyz`를 보내 체인·만료 시각을 검증한다. 이 probe는 공개 DNS나 방화벽을
바꾸지 않는다. 향후 내부 workload mTLS 인증서의 발급·갱신·폐기 자동화는 `PKI-01`에서
Vault PKI의 실제 소비자 기준으로 별도 판단한다.

PrometheusRule admission webhook과 operator self-metrics scrape는 활성화하지 않는다. 따라서
자체 서명 webhook Secret을 만들 operator web TLS listener도 끈다. 이 listener는 Kubernetes
API TLS 연결과 무관하며, default-deny namespace 안에서 선택하는 ServiceMonitor도 없다.

Grafana는 ClusterIP만 만들며 Ingress와 공개 DNS가 없다. Grafana admin password는
`obs-grafana` ServiceAccount의 `audience=vault` projected token과 Pod-local Vault Agent init으로
`kv/obs/grafana`에서 읽어 memory `emptyDir`에만 렌더링한다. Kubernetes Secret과 Git에는
credential을 저장하지 않는다.

NetworkPolicy는 `obs`를 ingress·egress default deny로 시작한다. namespace 내부 통신, CoreDNS,
Kubernetes API, node-exporter의 node IP TCP 9100, 기존 Velero·Loki·Alloy metric port,
Grafana init→Vault TCP 8200, blackbox→Traefik TCP 8443과 `obs-01-verification` label의 임시
receiver TCP 8080만 연다.

## 용량과 보존

Prometheus local-path PVC는 8 GiB, retention은 3일, size cap은 6 GiB다. Alertmanager PVC는
1 GiB이고 상태 보존은 120시간이다. Grafana persistence는 꺼져 있다. 따라서 OBS-01 PVC 선언
합계는 9 GiB로 10 GiB 목표 이하이며, 기존 66.125 GiB와 합쳐 75.125 GiB다. Wazuh 16 GiB를
예약해도 96 GiB 경고선까지 4.875 GiB가 남는다. 용량이 부족하면 replica나 disk를 늘리지 않고
scrape target과 retention을 먼저 줄인다.

Prometheus 1 GiB, Alertmanager 256 MiB, Grafana 384 MiB를 포함해 모든 렌더 container에 memory
limit을 명시한다. 배포 직전·직후 available 8 GiB와 swap 0, guest root 20%, PVC 120 GiB
정지선을 `verify-live.sh`가 한 번씩 판정한다. `k3s-01`이 이미 12 GiB RAM 경고 구간이므로
8 GiB 정지선을 깨면 즉시 root를 시작 main SHA로 rollback한다.

## 고정 release와 재생성

chart tarball SHA-256, chart tag commit, image index/amd64 digest와 렌더 hash는
[`release-metadata.env`](release-metadata.env)가 소유한다. 모든 실행 image는 index digest로
고정한다. 렌더는 다음 한 경로만 사용한다.

```bash
OBS01_RENDER_DIR=$(mktemp -d)
curl -fL \
  https://github.com/prometheus-community/helm-charts/releases/download/kube-prometheus-stack-88.1.3/kube-prometheus-stack-88.1.3.tgz \
  -o "${OBS01_RENDER_DIR}/kube-prometheus-stack.tgz"
curl -fL \
  https://github.com/prometheus-community/helm-charts/releases/download/prometheus-blackbox-exporter-11.16.0/prometheus-blackbox-exporter-11.16.0.tgz \
  -o "${OBS01_RENDER_DIR}/blackbox.tgz"
printf '%s  %s\n' \
  8b51a20164aeb3177b1ce20f1d4cb89f103c02c201aa048afc07f73da50c9d73 "${OBS01_RENDER_DIR}/kube-prometheus-stack.tgz" \
  932aa65df0538d9dc003c46bb663ebe44a06078af7a6a54577af5339668ac65b "${OBS01_RENDER_DIR}/blackbox.tgz" \
  | sha256sum -c -
helm template obs "${OBS01_RENDER_DIR}/kube-prometheus-stack.tgz" \
  --namespace obs \
  --include-crds \
  --values gitops/apps/obs/values-kube-prometheus-stack-01.yaml \
  > gitops/apps/obs/install.yaml
helm template obs-blackbox "${OBS01_RENDER_DIR}/blackbox.tgz" \
  --namespace obs \
  --values gitops/apps/obs/values-blackbox-01.yaml \
  >> gitops/apps/obs/install.yaml
sed -i 's/[[:space:]]\+$//' gitops/apps/obs/install.yaml
sha256sum gitops/apps/obs/install.yaml
```

## 완료 증거와 rollback

[`provision.sh`](../../tools/obs-01/provision.sh)는 Grafana password input을 생성하고 Vault policy,
Kubernetes auth role과 KV를 설정한다. 값은 출력하지 않는다. [`verify-live.sh`](../../tools/obs-01/verify-live.sh)는
`capacity-pre`에서 배포 전 기준을 기록하고 `verify` 한 번으로 다음만 판정한다.

1. node·PVC·backup·certificate와 Loki·Alloy target의 `up=1` 및 대표 시계열
2. Prometheus running flags의 3일·6 GiB retention, 선언 PVC 9 GiB, 전후 available·swap
3. metric 준비와 경보 전달이 공유하는 10분 고정창에서 전용 rule이 firing하고 Alertmanager
   active를 거쳐 임시 receiver가 실제 수신한 로그
4. immutable SHA의 `platform-root`와 `obs`가 `Synced/Healthy`

큰 Prometheus Operator CRD는 Argo child의 server-side apply로 적용해 client-side
`last-applied-configuration` annotation 크기 제한을 피한다.

### 2026-08-03 라이브 완료 증거

최신 `origin/main`을 포함한 immutable root
`d9b7d31aa23b93a04e7dca8bcc99a6949302f71f`과 child 설정
`544d6611c4d43f8443cba905f56059be4c80fa05`에서 다음 항목을 한 번 검증했다.

| acceptance | 라이브 증거 | 판정 |
|---|---|---|
| node | node-exporter target `up=1`, `node_uname_info=1` | 통과 |
| PVC | kube-state-metrics target `up=1`, 실제 PVC의 `kube_persistentvolumeclaim_info=1` | 통과 |
| backup | Velero target `up=1`, `velero_backup_total=0` 시계열 존재 | 통과 |
| certificate | blackbox target `up=1`, Traefik SNI probe `probe_success=1`, `probe_ssl_earliest_cert_expiry=1793334433` | 통과 |
| 수집 pipeline | Loki·Alloy target 각각 `up=1`, `loki_build_info=1`, `alloy_build_info=1` | 통과 |
| 실제 경보 전달 | `OBS01Delivery`가 Prometheus firing, Alertmanager active를 거쳐 receiver 로그 `RECEIVED alertname=OBS01Delivery status=firing`에 도달 | 통과 |
| disk·RAM 상한 | running retention 3일·6 GiB; PVC 66.125→75.125 GiB; available 10,273,751,040→9,978,179,584 bytes; swap 0 | 통과 |
| Argo | 위 immutable root·child가 모두 `Synced/Healthy` | 통과 |

배포 전후 available 감소량은 295,571,456 bytes이고 직후 값은 8 GiB 정지선보다
1,323.93 MiB 높았다. guest root 여유는 84%였다. 검증 중 확인한 node-exporter는 host
`/proc`·`/sys`를 읽고 정상 Running이어서 `spc_t`나 PolicyException을 추가하지 않았다.

merge 전 실패는 상태와 로그가 가리킨 지점만 수정했다. 사용하지 않는 operator TLS의
`obs-admission` Secret mount, Grafana subchart가 projected token을 `emptyDir`로 바꾼 렌더,
default-deny에서 빠진 Grafana→Vault TCP 8200, Prometheus의 `6GB`→`6GiB` 정규화와 첫 scrape
전 판정 race를 각각 제거했다. 최종 검증은 총 10분 고정 deadline을 늘리지 않고 통과했다.

임시 receiver namespace, ServiceMonitor와 PrometheusRule은 성공·실패 모두 trap에서 제거한다.
메일·Slack·외부 webhook egress는 없다. Grafana UI는 완료 증거가 아니므로 port-forward 확인도
중복 실행하지 않는다.

정상 child `targetRevision`은 literal `main`이다. merge 전에는 최신 `origin/main`에 rebase한 설정
commit을 push하고, 다음 pointer commit에서 `obs` child만 설정 SHA로 고정한 뒤 `platform-root`를
pointer SHA로 전환한다. 실패하거나 검증이 끝나면 다음 순서로 시작 main SHA에 rollback한다.

1. `platform-root` automated sync를 잠시 끈다.
2. `Application/obs`를 foreground 삭제해 namespace와 PVC를 포함한 child resource를 제거한다.
3. prune 보호한 `AppProject/obs`를 삭제한다.
4. root `targetRevision`과 automated sync를 시작 main SHA로 복원하고 `Synced/Healthy`를 확인한다.
5. 작업 branch의 child 선언이 literal `main`인 것을 확인한 뒤 `ARGO-ROOT`를 해제한다.

임시 라이브 검증 rollback에서 삭제되는 OBS-01 PVC는 아직 운영 데이터를 소유하지 않는다.
로컬 0600 Grafana password input과 Vault policy·role·KV는 다음 main sync를 위해 보존하며,
credential 회전은 이 rollback 범위가 아니다.
