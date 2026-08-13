# OBS-01 metrics·경보 기준선

이 디렉터리는 단일 노드 `k3s-01`의 Prometheus Operator, Prometheus, Alertmanager,
node-exporter, kube-state-metrics, Grafana, 인증서 probe와 OPNsense node_exporter scrape를
소유한다. Wazuh 보안 event, Loki 수집 경계, 자동 대응, 공개 DNS·NAT·Ingress와 다른 앱의
선언은 소유하지 않는다.

## 수집 경계

| acceptance | target과 대표 시계열 | 선언 위치 |
|---|---|---|
| node | `obs-prometheus-node-exporter`, `node_uname_info` | 이 chart의 node-exporter |
| PVC | `obs-kube-state-metrics`, `kube_persistentvolumeclaim_info` | 이 chart의 kube-state-metrics |
| backup | `velero`, `velero_backup_total` | `obs`의 ServiceMonitor가 기존 `velero` Service를 선택 |
| certificate | `obs-blackbox`, `probe_success`, `probe_ssl_earliest_cert_expiry` | blackbox-exporter가 기존 Traefik의 `k3s-01.imcherry5778.xyz` TLS를 검증 |
| Traefik traffic | `obs-traefik`, `traefik_entrypoint_*`·`traefik_router_*`·`traefik_service_*` | ingress의 private `traefik-metrics:9100` Service와 `obs` ServiceMonitor |
| 수집 pipeline | `loki`·`alloy`, `loki_build_info`·`alloy_build_info` | `obs`의 ServiceMonitor가 기존 `loki` namespace Service를 선택 |
| OPNsense | `opnsense-node`, CPU·memory·interface node metric | 이 앱의 외부 static target ScrapeConfig |
| node-exporter fleet | `node-exporter-fleet`(job=`node-exporter`), CPU·memory·filesystem·disk·network·systemd node metric | `OBS-11`의 외부 static target ScrapeConfig; 대상은 `infra/ansible/roles/node_exporter_baseline` |
| k3s-01 root filesystem | `node-exporter-root-k3s01`(job=`node-exporter-root`), `node_filesystem_avail_bytes`·`node_filesystem_size_bytes` | `OBS-13`의 외부 static target ScrapeConfig(port 9101); 기존 DaemonSet(port 9100)의 filesystem collector 권한 한계를 보완만 한다 |
| 상시 alert 수신 | `obs-13-receiver`, `obs13_alerts_received_total` | `OBS-13`의 상시 webhook receiver; Alertmanager route가 이 Service로 4종 alert를 보낸다 |

Prometheus는 `obs` namespace에 있는 `release=obs` ServiceMonitor·PrometheusRule·ScrapeConfig를
선택한다. Velero와 Loki 선언은 수정하지 않는다. `OPN-METRICS-01`의 OPNsense static target,
Prometheus egress와 방화벽 rule은 이 앱을 확장하며 OBS-01의 과거 증거에는 포함하지 않는다.

### LOKI-02 host journald ingress

`obs-loki-host-gateway`는 기존 Loki ClusterIP를 외부에 열지 않고, 여섯 관리 host가 보내는
O7 Loki push payload만 private LoadBalancer TCP 3100에서 받아 같은 cluster 내부 Loki Service로
전달한다. Pod에는 ServiceAccount·Secret·PVC가 없고 Alloy client WAL과 storage는 memory
`emptyDir` 32 MiB로 제한한다. `source=host`·`hostname`·`unit` selector는 OBS-07 Log Explorer가
Kubernetes O7과 host O7을 구분하는 데만 쓰며 PID·세션·사용자·command·원문은 저장하지 않는다.

노출 경계는 Service `loadBalancerSourceRanges`, gateway ingress NetworkPolicy, gateway→Loki egress
NetworkPolicy, OPNsense의 세 exact cross-VLAN PASS 규칙으로 겹친다. `proxmox-01`은 기존 LAN
allow를 재사용하고 `k3s-01`은 같은 private address로 loopback한다. 공개 DNS·Ingress·Pomerium·
credential·Loki runtime 설정은 바꾸지 않는다. 실패 rollback은 gateway Deployment/Service/
NetworkPolicy와 host collector·LOKI-02 OPNsense rule만 제거하며 기존 K8s O7 수집은 보존한다.

`TRAEFIK-METRICS`의 ServiceMonitor도 `obs` namespace에만 두고 `kube-system`의
`traefik-metrics` ClusterIP Service를 선택한다. Prometheus Pod egress는 Traefik Pod의 TCP
9100 한 포트로만 추가한다. 이 경로는 외부 serving Service·Ingress·DNS·NAT와 독립적이며,
Prometheus metric에는 path·client IP·사용자·인증 header label을 넣지 않는다.

OPNsense 플러그인 node_exporter와 API 기반 opnsense-exporter를 한 번 비교했고, 추가 API
credential 없이 CPU·memory·interface를 얻는 더 짧은 경로라 `os-node_exporter`를 선택했다.
플러그인은 관리 주소 한 곳의 TCP 9100에만 bind하고 CPU·meminfo·netdev collector만 켠다.
Kubernetes Service가 없는 외부 static endpoint이므로 ServiceMonitor가 아니라 ScrapeConfig를
사용한다. SNMP, dashboard와 alert rule은 이 작업 범위가 아니다.

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

## OBS-02 운영 UI와 대시보드

Grafana·Prometheus·Alertmanager의 외부 진입은 모두 `pomerium` 앱이 소유하는 표준 Kubernetes
`Ingress`와 선언형 Route다. 이 앱에는 별도 Ingress·공개 DNS·NAT·Traefik 정적 설정이 없다.

| UI | 내부 upstream | Pomerium claim 경계 |
|---|---|---|
| `grafana.imcherry5778.xyz` | `obs-grafana:80` | `/platform-users` |
| `prometheus.imcherry5778.xyz` | `obs-prometheus:9090` | `/platform-users` |
| `alertmanager.imcherry5778.xyz` | `obs-alertmanager:9093` | 조회는 `/platform-users`, silence 변경은 `/platform-privileged` |

Grafana native dashboard provider는 `dashboard.yaml`의 `obs-02-dashboard` ConfigMap을
`Platform` folder로 read-only mount한다. `defaultDashboardsEnabled`는 계속 꺼져 있으며, 이
대시보드는 Prometheus의 node·PVC 대표 query와 Loki의 5분 로그량 query 세 패널만 제공한다.
Loki datasource가 `loki.loki.svc:3100`을 사용하므로 Grafana Pod에만 정확한 TCP 3100 egress를
추가한다. Grafana native admin login은 Pomerium 로그인과 별개이며, password의 Vault Agent
소비 경계는 바꾸지 않는다.

## OBS-12 Argo CD Application Overview

`obs-argocd-application-controller` ServiceMonitor는 이미 존재하는
`argocd/argocd-metrics:8082`만 30초마다 읽는다. Prometheus가 ServiceMonitor를 `obs`
namespace에서만 선택하므로 monitor 자체는 `obs`에 두고, target namespace만 `argocd`로
한정한다. `obs-prometheus-scrape-egress`는 Prometheus Pod에서 application-controller Pod의
TCP 8082로 가는 exact egress 한 건만 더 허용한다. Argo CD 설정·Service·ingress 정책·권한은
바꾸지 않는다.

저장하는 metric은 Grafana.com [ArgoCD / Application / Overview (ID 19974)](https://grafana.com/grafana/dashboards/19974-argocd-application-overview/)
revision 6의 필요량인 `argocd_app_info`·`argocd_app_sync_total`뿐이다. `repo`·`operation`·`dry_run`
label은 대시보드에 쓰지 않으므로 ingestion 전에 버린다. upstream download SHA-256은
`7a230d1221b1014a40a70d989a80d25d3d800c3a62dd77b63a4a1088c5fbbaf1`이며, 현재 Argo CD metric
label에 맞춰 upstream의 없는 `cluster` selector를 제거하고 `exported_namespace`를
`dest_namespace`로 정규화했다. sync counter에는 destination namespace label이 없으므로
application별 sync-result panel만 그 namespace selector를 쓰지 않는다.

대시보드는 Prometheus datasource UID `prometheus`와 `Platform` folder의 native read-only provider를
쓴다. 기존 Platform Overview의 Argo CD OutOfSync 요약은 유지하되 새 drill-down 링크를 더한다.
Grafana Viewer 권한과 Pomerium `/platform-users` 경계는 `OBS-03`·`OBS-02`에서 이미 판정한 것을
재사용하며, Grafana의 raw metric query로 repo label을 보이지 않게 한다.

## OBS-09 Kubernetes Global inventory

Grafana.com [Kubernetes / Views / Global (ID 15757)](https://grafana.com/grafana/dashboards/15757-kubernetes-views-global/)
revision 43을 source SHA-256 `6e8a2f49237bb86a6b1e422eec28683117456875acf810e39f4ccf49230faaa3`로
고정해 vendoring했다. [`normalize-dashboard.jq`](../../tools/obs-09/normalize-dashboard.jq)는 upstream의
datasource·cluster 변수를 제거하고 datasource UID를 `prometheus`로 고정하며, 단일 k3s에 없는
`cluster` label selector와 `machine_*` node capacity metric을 이 환경의 kube-state-metrics query로
정규화한다. `container_*` cAdvisor metric을 요구하는 namespace CPU·memory·network 패널 세 개는
현재 수집 경계에 없으므로 제외했다.

Grafana native provider는 `Platform` folder에서 read-only로 이 dashboard를 mount한다. kube-state-metrics는
기존 node·pod·PV·PVC에 Namespace, Deployment, DaemonSet, StatefulSet, ReplicaSet, Job, CronJob,
Service, Endpoint, Ingress, HPA, NetworkPolicy, ResourceQuota만 더 수집한다. Secret·ConfigMap collector,
metric, 대시보드 panel은 넣지 않으며 object label allow-list도 넓히지 않는다. HPA나 ResourceQuota처럼
현재 객체가 0개인 종류는 임의 객체를 만들지 않고 collector 활성화와 dashboard의 빈 상태를 정상으로
판정한다.

### 2026-08-11 OBS-09 라이브 완료 증거

immutable root `ce81ebee7fe2d0a49b8d244342828800b87e0d35`과 child
`146dbda3099ccc3bb2adcdc081c7c5e07e5e5c79`에서 `verify-live.sh` 한 번으로 판정했다.

| acceptance | 라이브 증거 | 판정 |
|---|---|---|
| KSM·비민감 metric | target `up=1`; Namespace 26, Deployment 44, DaemonSet 4, StatefulSet 9, ReplicaSet 85, Job 7, CronJob 2, Service 62, Endpoint 62, Ingress 5, NetworkPolicy 57 대표 series | 통과 |
| 빈 자원·민감 경계 | HPA·ResourceQuota 객체 0개라 collector 활성화만 확인; `kube_secret_*`·`kube_configmap_*` metric family 0건 | 통과 |
| Grafana | `obs-09-kubernetes-global`, read-only, schema 41, datasource UID `prometheus`만 사용, drill-down 표시 | 통과 |
| 용량·범위 | head series 42,631→54,351; Prometheus 312,475,648→325,058,560 bytes, KSM 68,157,440→33,554,432 bytes; available RAM 14,742,831,104→14,297,698,304 bytes, swap 0, retention 3d/6GiB; obs Service 9·NetworkPolicy 13·PVC 2·Secret 9로 불변 | 통과 |
| rollback | literal `main` 복구 뒤 `platform-root`·`obs`가 `dac2fe9facf2278faaac3b113887b4941a80703f`에서 `Synced/Healthy` | 통과 |

### 2026-08-11 OBS-09-FIX-01 라이브 완료 증거

`machine_*` capacity metric 치환문이 label quote 앞에 literal backslash를 남겨 Prometheus parser가
거부하던 결함을 보정했다. immutable root `7cbe87450c213b0f85c3748425f4a51667beb175`와 child
`6f66f115734765d819c4fbe1b6665886f95c5a8b`에서 Grafana API의 allocatable CPU·memory query 6건이
backslash 0건이고 Prometheus API parse 성공임을 확인했다. collector·RBAC·ServiceMonitor·NetworkPolicy·PVC·Secret·Ingress
변경은 0건이며, 이후 literal `main` `4ac2336a8d352e89416f00654ee8475e87e89901`에서
`platform-root`·`obs` 모두 `Synced/Healthy`로 복구했다.

`obs-default-deny`는 cross-namespace ingress도 막으므로 Pomerium egress만으로는 UI backend에
도달하지 못한다. 세 `obs-02-*-pomerium-ingress` 정책은 Pomerium server Pod만 Grafana TCP 3000,
Prometheus TCP 9090, Alertmanager TCP 9093에 도달하게 해 해당 egress와 정확히 짝을 이룬다.

NetworkPolicy는 `obs`를 ingress·egress default deny로 시작한다. namespace 내부 통신, CoreDNS,
Kubernetes API, node-exporter의 node IP TCP 9100, OPNsense 관리 주소 TCP 9100 한 건, 기존
Velero·Loki·Alloy metric port, Grafana init→Vault TCP 8200, blackbox→Traefik TCP 8443과
`obs-01-verification` label의 임시 receiver TCP 8080만 연다.

## OBS-03 Grafana Keycloak 로그인과 Editor 경계

Grafana는 Keycloak `platform` realm의 confidential client `grafana`를 `generic_oauth` provider로
사용한다. callback은 `https://grafana.imcherry5778.xyz/login/generic_oauth` 한 건이고, client의
`groups` mapper가 full path claim을 ID token·access token·userinfo에 넣는다. client와 신규
top-level group `/grafana-editors`는
[`provision-keycloak.sh`](../../tools/obs-03/provision-keycloak.sh)가 기존 객체를 먼저 비교한 뒤
없는 객체와 membership만 추가한다. `/grafana-editors`의 exact 회원은 daily ID
`imcherry5778`·`cerberos2022` 두 개이며, `imcherry5778-admin`에는 membership을 주지 않는다.

Grafana의 `role_attribute_path`는 `groups`에 `/grafana-editors`가 있으면 `Editor`, 없으면
`Viewer`를 반환한다. `role_attribute_strict=true`, `skip_org_role_sync=false`이므로 로그인할
때마다 이 결과를 org role로 동기화하고, `GrafanaAdmin`은 어떤 claim에도 매핑하지 않는다.
Pomerium이 이미 `/platform-users`만 Route에 통과시키므로 Grafana에서 같은 allow 경계를
중복 선언하지 않는다. `GF_AUTH_DISABLE_LOGIN_FORM`은 두지 않아 Vault의 기존
`admin_password`를 쓰는 local `admin` 복구 로그인을 유지한다.

OIDC client secret은 기존 `obs-grafana` Vault policy·Kubernetes auth role을 그대로 사용한다.
[`provision-vault.sh`](../../tools/obs-03/provision-vault.sh)는
`kv/obs/grafana`가 `admin_password` 한 key인 상태만 신규 적용 대상으로 받고, 현재 version을
CAS로 고정한 `vault kv patch`로 `oidc_client_secret`만 추가한다. 전후 policy 본문과 role data는
정규화해 비교하고, KV 값은 출력하지 않는다. OBS-01 provisioner도 기존 KV가 있으면 read-write patch를
사용해 이후 재실행이 `oidc_client_secret`을 지우지 않는다. Vault Agent는 두 값을 각각
memory `emptyDir` 파일로 렌더링한다.

client secret 저장소 밖 파일은 영숫자 48자와 파일 종단 newline 정확히 1개만 허용한다. 초기
검증에서 생성 파이프라인이 newline을 중복 추가해 Keycloak credential 값에 newline 1 byte가
들어간 상태를 발견했으므로, provisioner는 이 exact legacy만 같은 48자 본문으로 교정하고 그 밖의
secret 차이는 자동 변경하지 않는다. Vault도 같은 legacy 값일 때만 CAS patch하며 값은 출력하지
않는다.

default-deny egress에서 Grafana가 token·userinfo endpoint를 호출할 수 있도록 Grafana Pod에서
기존 `kube-system` Traefik Pod의 HTTPS container port `8443`으로 가는 TCP 한 경로만 연다.
내부 `sso` alias가 가리키는 node IP·TCP 443은 Service DNAT 뒤 이 Pod·port가 되므로, 같은
namespace의 blackbox→Traefik 정책과 동일한 selector 경계를 재사용한다. 공개 DNS·방화벽,
Pomerium Route, datasource와 dashboard 내용은 바꾸지 않는다.

실제 role 증거는 immutable SHA 배포 뒤 사용자가 새 브라우저 세션으로 Grafana의
`Sign in with Keycloak`을 한 번 완료해 만든다. `imcherry5778`의 Editor 로그인과
`foxgeun`·`Jaeeyun`·`snsd-hybirdinfra` 중 한 명의 Viewer 대조 로그인을 확인한다. 아직 본인 IAM
온보딩을 마치지 않은 `cerberos2022`는 exact group membership과 공통 role mapping 선언을
OBS-03 증거로 삼고 실제 로그인은 온보딩 뒤로 이관한다. 이후 Grafana org에 나타난 경우
Editor가 아니면 실패다. [`verify-live.sh`](../../tools/obs-03/verify-live.sh)는 local admin API
로그인으로 생성된 org user를 조회해 실제 Editor와 선택한 Viewer role, 특권 ID 부재를 한 번
판정한다. 같은 실행에서 Keycloak
client/group check-first 일치, Vault key와 policy·role 불변, local admin 복구, datasource 세
개와 dashboard provider의 `editable: false`, Argo `platform-root`·`obs`의 immutable
`Synced/Healthy`만 확인한다. OBS-01/02의 dashboard 렌더링·수집·경보·용량 경계는 다시
검증하지 않는다.

### 2026-08-05 OBS-03 라이브 완료 증거

실제 로그인은 immutable root `244cf4a0e91256c1788114cbeb7a8b9c149a2c8c`·child
`534db0945901922aa8c54e582200ec803c64bdfa`에서, 나머지 선언은 완료 기준을 반영한 immutable
root `69979a52273296a4ccbeb8f9810df28fe1d4539c`·child
`f50b1003dd8ba1db3bb69627946efa8d2e99b8eb`에서 확인했다. 두 child 사이 런타임 선언 diff는
0건이다.

| acceptance | 라이브 증거 | 판정 |
|---|---|---|
| Keycloak | confidential client `grafana`, groups mapper, `/grafana-editors` exact 회원 `imcherry5778`·`cerberos2022`, 특권 ID membership 없음 | 통과 |
| 실제 역할 | `imcherry5778=Editor`, `snsd-hybirdinfra=Viewer`; `cerberos2022` 실제 로그인은 본인 온보딩 뒤로 이관 | 통과 |
| 복구·provisioning | local `admin=Admin`, 로그인 form 유지, datasource 세 개와 dashboard provider `editable:false` | 통과 |
| Vault | `kv/obs/grafana` key가 `admin_password`·`oidc_client_secret`뿐이고 기존 `obs-grafana` policy·role 불변 | 통과 |
| Argo | 검증 root·child와 복구한 literal `main`에서 `platform-root`·`obs` 모두 `Synced/Healthy` | 통과 |

Grafana persistence가 꺼져 있어 rollback 뒤 재배포는 OIDC org user를 초기화한다. 같은 실제 로그인
경계를 재검증하지 않고 위 API 판정을 보존하며, 이후 로그인은 같은 claim에서 role을 다시
동기화한다.

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

## OPN-METRICS-01 적용과 rollback

[`apply-live.sh`](../../tools/opn-metrics-01/apply-live.sh)는 일반 drift가 없는 상태에서 플러그인을
설치·최소 설정하고, `opt2`의 기존 비공개 목적지 BLOCK보다 앞에 k3s-01→OPNsense TCP 9100
exact PASS 한 건을 disabled로 stage해 의미값을 읽은 뒤 enable·apply한다. 원본 config와 생성
rule UUID는 저장소 밖 mode 0700/0600 복구 지점에 남긴다.

[`verify-live.sh`](../../tools/opn-metrics-01/verify-live.sh) 한 번만 실행해 immutable root/child,
target `up=1`, CPU·memory·interface 시계열, 저장 rule과 PF runtime을 판정한 뒤에만
`check-drift.sh --update`와 일반 drift 검사를 순서대로 실행한다. 실패하면 출력된 단계부터
원인을 특정하고 root를 시작 main SHA로 되돌린다. 방화벽은 생성 UUID만 disable·apply한 뒤
삭제·apply하고, 이 작업이 처음 설치한 node_exporter를 disable·remove한다. 마지막으로 시작
스냅샷과 일반 drift가 일치하는지 확인한다. 기존 OBS PVC·Secret·Vault 입력은 삭제하거나
회전하지 않는다.

### 2026-08-03 라이브 완료 증거

immutable root `addba0e1aa8e6625345641b0d19929ee99e4f0b8`과 child
`df003d3fe221b488da7c4e24872fb3bf121b91c5`에서 `verify-live.sh`를 한 번 실행했다.

| acceptance | 라이브 증거 | 판정 |
|---|---|---|
| target | `up{job="scrapeConfig/obs/opnsense-node",instance="opnsense.imcherry5778.xyz"}=1` | 통과 |
| CPU | `node_cpu_seconds_total{cpu="3",mode="idle"}=133659.968503937` | 통과 |
| memory | `node_memory_size_bytes=33280430080` | 통과 |
| interface | `node_network_receive_bytes_total{device="igc1"}=7359887362` | 통과 |
| 방화벽 | UUID `850333eb-ba9f-4a03-a846-81b6bd24e1cf`, sequence 1020, PF rule 1개, packets 11, bytes 5436 | 통과 |
| drift·Argo | `check-drift.sh --update` 뒤 일반 검사 drift 없음, 위 immutable root·child `Synced/Healthy` | 통과 |

적용 중 첫 PF runtime 판정은 300초 캐시가 남는 rule 검색 응답에서 `pf_rules`를 읽어 실패했다.
응답과 설치본 controller를 대조해 캐시 없는 `filter_util/rule_stats`가 같은 UUID의 PF rule 1개를
반환함을 확인한 뒤 검증기만 고쳤으며, 방화벽을 다시 적용하지 않았다. 독립 복구 지점은
`/home/imcherry/.local/state-backups/opn-metrics-01-nKnokVNk`, 변경 전 config revision은
`1785711551.50`이다. 검증 종료 뒤 root와 child는 시작 SHA
`3ab89ab66bc6217c8ca789f034485e41a1e77f08`을 거쳐 literal `main`으로 복구했다.
