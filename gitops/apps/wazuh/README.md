# WAZUH-01 보안 이벤트 직접 수집 PoC

이 디렉터리는 단일 노드 `k3s-01`의 Wazuh manager 한 대, Wazuh indexer 한 대,
Wazuh Dashboard 한 대, D30·A90 보존 정책, `wazuh` namespace default-deny NetworkPolicy를
소유한다. Loki 수집 경계, OPNsense Suricata 룰셋, Kyverno 정책 본문, 공개 DNS,
Pomerium Route·Ingress(둘 다 `gitops/apps/pomerium` 소유), active response와 SOAR는
소유하지 않는다.

분류·보존의 단일 원본은 [`docs/audit-event-standard.md`](../../../docs/audit-event-standard.md)이고
자원 한도의 단일 원본은 [`docs/capacity-plan.md`](../../../docs/capacity-plan.md)다.

## 수집 경계

| 소스 | event | 분류 | index | 경로 |
|---|---|---|---|---|
| OPNsense Suricata | `eve.json`의 `event_type=alert` | `D30` | `wazuh-alerts-4.x-*` | OPNsense Wazuh Agent → manager TCP 1514 |
| Kubernetes API | `audit.k8s.io/v1` `Metadata` terminal stage | `A90` | `wazuh-alerts-4.x-audit-*` | 노드 `/var/log/k3s-audit` read-only hostPath → manager `localfile` |

apiserver는 audit 파일을 k3s runtime state 디렉터리가 아니라 전용 `/var/log/k3s-audit`에 쓴다.
`container_t`는 `container_var_lib_t` 파일을 읽을 수 없으므로 이 디렉터리만
`container_file_t`로 라벨하고 그 선언은 `infra/ansible/roles/k3s_baseline`이 영속 소유한다.
Pod에 `spc_t`나 privileged를 주지 않는다.

- Loki를 중계로 쓰지 않는다. `wazuh` namespace에는 Loki로 향하는 egress 규칙이 없고,
  Loki 수집 설정에는 Wazuh 참조가 없다.
- `O7` 운영 로그는 Loki가 소유한다. manager 자신의 기동·상태 message는
  [`files/wazuh-01-d30-suricata.xml`](files/wazuh-01-d30-suricata.xml)의 rule 100130이 level 0으로
  두어 중앙 보안 저장소에 넣지 않는다.
- `eve.json`의 `http`·`dns`·`tls`·`ssh` record는 upstream rule 86600·86602~86604가 이미 level 0이라
  alert만 D30으로 들어간다. payload는 `NIDS-01`이 소스에서 이미 비활성이다.
- 전 소스 온보딩은 이 작업 범위가 아니다. CrowdSec·Falco·Vault·Keycloak·Pomerium·NetBird·
  Warpgate는 표준에 정의만 되어 있고 여기서 수집하지 않는다.

### NIDS-01 all-traffic 테스트 시그니처 제외

2026-08-03 실측에서 OPNsense Suricata는 `2.06 alert/s`(약 177,826건/일)를 냈고 그중
99.87%가 `NIDS-01`이 fingerprint 없이 `any -> any`로 등록한 사용자 정의 테스트 룰
3건(sid `4294967292`·`4294967293`·`4294967294`)이었다. 이 세 시그니처는 모든 패킷에
매치하므로 탐지가 아니며, 그대로 저장하면 D30 일일 256 MiB와 30일 7.5 GiB 상한을 넘는다.

`docs/audit-event-standard.md` 4절의 "맞지 않으면 배포를 멈추고 허용 event class를 줄인다"에
따라 이 세 시그니처만 중앙 저장에서 제외했다. OPNsense 룰셋 자체는 `NIDS-01`이 소유하므로
이 작업에서 바꾸지 않았다. 소스에서 이 룰을 정리하는 일은 별도 작업으로 남는다.

제외 지점은 manager rule이 아니라 저장 직전 ingest pipeline의 `drop` processor다.
`<field name="alert.signature_id">`(숫자), 소수부를 허용한 pcre2,
`<field name="alert.signature">`(문자열), `<match>` 네 조건을 `<if_sid>` 자식 룰로 각각
실측했고 넷 다 이 event를 걸러내지 못했다. 룰 적재 오류는 없었고 같은 필드의
`$(alert.signature)` 치환은 정상 렌더됐다. pipeline drop은
`_ingest/pipeline/_simulate`로 노이즈 drop·대표 event 통과·audit 분리를 함께 확인한다.

## 배치와 자원

| 구성 | 값 | 근거 |
|---|---|---|
| indexer | replica 1, `discovery.type=single-node` | 단일 노드 k3s |
| indexer heap | `-Xms1g -Xmx1g` | upstream `wazuh-kubernetes` 기본값. 공식 최소 아래로 줄이지 않았다 |
| indexer limit | cpu 1, memory 2Gi | upstream `envs/local-env` 값 |
| manager limit | cpu 1, memory 1536Mi | upstream base 512Mi와 `envs/eks` 2Gi 사이 |
| indexer PVC | 15 GiB `local-path` | Wazuh PVC 합계 상한 16 GiB |
| manager PVC | 1 GiB `local-path` | upstream 기본 500Mi 이상 |
| Dashboard | cpu 500m/mem 1Gi limit, PVC 없음 | WAZUH-02. upstream처럼 stateless 컨테이너라 재기동마다 keystore·wazuh.yml을 다시 만든다 |

`local-path`는 PVC 요청량을 강제하지 않는다. 16 GiB는 선언 상한이자 capacity 회계 단위이며,
실제 저장 상한은 아래 ISM 보존 정책과 `verify-live.sh`의 환산 판정이 지킨다.

## 고정과 재현

공식 Wazuh Helm chart는 존재하지 않는다. ArtifactHub의 `wazuh` chart는 모두 third-party이고
공식 Kubernetes 배포 원본은 Kustomize 기반 [`wazuh/wazuh-kubernetes`](https://github.com/wazuh/wazuh-kubernetes)다.
그래서 이 앱은 `gitops/apps/gitea`처럼 선언을 직접 작성하고, 파생 원본과 image를
[`release-metadata.env`](release-metadata.env)에 고정한다. `helm template` 산출물인
`install.yaml`은 만들지 않는다.

파생 원본 검증은 아래 한 경로만 쓴다.

```bash
WAZUH01_SRC=$(mktemp -d)
curl -fL https://github.com/wazuh/wazuh-kubernetes/archive/refs/tags/v4.14.7.tar.gz \
  -o "${WAZUH01_SRC}/wazuh-kubernetes.tar.gz"
printf '%s  %s\n' \
  928dc1e46d4f9db5a3c4f358f13b6eea03fccdb1f0a036567deabcc5528567c1 \
  "${WAZUH01_SRC}/wazuh-kubernetes.tar.gz" | sha256sum -c -
tar xzf "${WAZUH01_SRC}/wazuh-kubernetes.tar.gz" -C "${WAZUH01_SRC}"
kubectl kustomize gitops/apps/wazuh > /dev/null
```

upstream에서 바꾼 점과 이유는 [`indexer.yaml`](indexer.yaml)·[`manager.yaml`](manager.yaml)·
[`files/ossec.conf`](files/ossec.conf)·[`files/opensearch.yml`](files/opensearch.yml) 머리말이 각각 소유한다.
요약하면 worker·dashboard·LoadBalancer·평문 Secret·`wazuh-storage` StorageClass를 쓰지 않고,
privileged `vm.max_map_count` init을 노드 기준선(`524288`)으로 대체했으며, root chown init은
`fsGroup`으로 대체했다.

## credential

Git과 Kubernetes Secret에는 어떤 값도 두지 않는다. [`provision.sh`](../../tools/wazuh-01/provision.sh)가
저장소 밖 mode 0700 디렉터리에 root CA와 node·admin·filebeat 인증서, indexer admin password와
그 bcrypt hash, Wazuh API credential, authd 등록 password를 만들고 Vault policy·Kubernetes auth
role·KV에 넣는다. Pod는 `audience=vault` projected token으로 Vault Agent init을 돌려
memory `emptyDir`에만 렌더한다. 스크립트는 어떤 credential도 출력하지 않는다.

| Vault 경로 | 소비자 | 내용 |
|---|---|---|
| `kv/wazuh/indexer` | `wazuh-indexer` SA | root CA, node·admin 인증서, admin password bcrypt hash |
| `kv/wazuh/manager` | `wazuh-manager` SA | root CA, filebeat 인증서, indexer·API credential, authd password |
| `kv/wazuh/bootstrap` | `wazuh-bootstrap` SA | root CA, admin client 인증서 |

`indexer`의 `internal_users.yml`에는 `admin` 한 명만 둔다. upstream demo 계정
(`kibanaserver`, `kibanaro`, `logstash`, `readall`, `snapshotrestore`)은 만들지 않는다.

## Kyverno 예외

`wazuh-manager` container는 upstream image대로 UID 0으로 동작한다. `POL-02`가 Enforce하는
`pol-01-require-pod-run-as-non-root`를 통과하기 위해 `policies/`에 `Pod/wazuh-manager-master-*`와
`StatefulSet/wazuh-manager-master`만 허용하는 `PolicyException` 두 건과, 고정 image digest·
ServiceAccount·token 미자동 mount·비privileged·권한 상승 금지·RuntimeDefault seccomp와
hostPath 한 곳만 허용하는 보상 Enforce 정책 `pol-02-wazuh-root-manager-baseline`을 함께 둔다.
Falco root sensor 경계와 같은 구조다.

capability는 `drop: [ALL]` 뒤에 upstream image가 실제로 요구하는 일곱 개만 더한다.
`CHOWN`·`FOWNER`는 permanent data 복원(`cp -a`), `SETUID`·`SETGID`·`KILL`은 s6가 daemon을
`wazuh` 사용자로 내려 실행하는 데, `DAC_OVERRIDE`는 root가 자기 소유가 아닌 파일을 읽는 데,
`SYS_CHROOT`는 ossec daemon chroot에 필요하다. 기본 Docker 집합의 `NET_RAW`,
`NET_BIND_SERVICE`, `MKNOD`, `SETPCAP`, `SETFCAP`, `AUDIT_WRITE`, `FSETID`는 주지 않는다.
이 목록을 바꾸면 보상 정책의 `restrict-wazuh-manager-added-capabilities`도 같은 변경에서
갱신한다.

`gitops/root/wazuh-application.yaml`은 sync wave 2다. wave 1인 `policy-baseline`이 Healthy가 된
뒤에 생성되므로 예외가 admission보다 먼저 존재한다.

## 보존

[`files/bootstrap-retention.py`](files/bootstrap-retention.py)가 indexer REST API에 ISM 정책 두 건을 만든다.

| 정책 | index pattern | priority | 삭제 |
|---|---|---|---|
| `wazuh-01-d30` | `wazuh-alerts-4.x-*` | 1 | 30일 |
| `wazuh-01-a90` | `wazuh-alerts-4.x-audit-*` | 100 | 90일 |

두 pattern은 겹치므로 A90 priority를 높여 audit index가 A90만 받게 한다. `ism_template`은
index 생성 시점에만 적용되므로 sync wave 순서(indexer 0 → bootstrap 1 → manager 2)가 계약의
일부다. 이 순서를 바꾸면 첫 index가 정책 없이 만들어진다.

index 분리는 manager container의 `/etc/cont-init.d/3-wazuh-01-index-routing`이 upstream
filebeat 설정에 조건부 `output.elasticsearch.indices`만 더해서 만든다. 판정 키는 **rule ID
범위 `100100`~`100109`**이고 그 밖은 upstream 기본 D30 index다.

판정은 filebeat이 아니라 **서버측 ingest pipeline**에서 한다. wazuh filebeat 모듈은
`input: log`로 `alerts.json`을 raw 한 줄씩 읽고 JSON 파싱과 최종 index 결정은
`filebeat-7.10.2-wazuh-alerts-pipeline`이 수행한다. 이 pipeline의 `date_index_name`
processor가 `{{fields.index_prefix}}`로 `_index`를 다시 쓰기 때문에 filebeat
`output.elasticsearch.indices` 조건은 결과에 영향을 주지 않는다. `rule.groups`(배열),
`rule.id`, `message` 세 조건을 차례로 실측했고 셋 다 A90 record가 D30 index로 갔다.

그래서 cont-init 스크립트가 `date_index_name` 직전에 `set` processor 하나를 넣어
rule ID가 A90 범위일 때만 `fields.index_prefix`를 `wazuh-alerts-4.x-audit-`로 바꾼다.
patch한 pipeline이 매 기동에 반영되도록 `filebeat.overwrite_pipelines: true`도 함께 켠다.
분리는 `_ingest/pipeline/_simulate`로 A90·D30 문서 각각에 대해 먼저 확인했다.

rule ID 할당은 A90 `100100`~`100109`, D30 `100120`~`100129`, O7 억제 `100130`이다.
A90 룰을 이 범위 밖 ID로 추가하면 라우팅이 조용히 깨지므로 같은 변경에서 이 정규식도
갱신한다.

## WAZUH-02 Dashboard 조사 UI

Dashboard의 외부 진입은 `pomerium` 앱이 소유하는 표준 Kubernetes `Ingress`와 선언형
Route(`gitops/apps/pomerium/pomerium-conf.yaml`의 `wazuh` Route) 하나뿐이다. 이 앱에는 별도
Ingress·공개 DNS·NAT가 없다.

| UI | 내부 upstream | Pomerium claim 경계 |
|---|---|---|
| `wazuh.imcherry5778.xyz` | `wazuh-dashboard.wazuh.svc.cluster.local:5601` | `/platform-privileged`만(사고 조사 도구라 `/platform-users`는 거부) |

`wazuh-default-deny`는 cross-namespace ingress도 막으므로 Pomerium egress만으로는
Dashboard에 도달하지 못한다. `wazuh-dashboard-pomerium-ingress`(이 앱)와
`wazuh-02-pomerium-to-wazuh`(`gitops/apps/pomerium/wazuh-egress.yaml`)가 정확히 짝을
이룬다. `OBS-02`가 이 짝을 빼먹어 503을 겪은 전례가 있다.

### credential 설계

Dashboard는 두 자격증명만 쓰고 둘 다 새로 만들지 않는다.

- indexer 인증: upstream demo는 `kibanaserver` 내부 사용자를 새로 만들지만, `indexer.yaml`의
  `internal_users.yml`에는 `admin` 한 명만 둔다는 WAZUH-01 결정을 유지한다. 그래서
  `DASHBOARD_USERNAME`/`DASHBOARD_PASSWORD`(컨테이너 entrypoint가 OpenSearch Dashboards
  keystore의 `opensearch.username`/`opensearch.password`로 그대로 쓰는 값)에 기존 indexer
  admin 자격증명을 재사용한다. 컨테이너가 실제로 읽는 값은 이 keystore 값뿐이라
  `INDEXER_USERNAME`/`INDEXER_PASSWORD`(upstream 매니페스트가 선언하지만 `entrypoint.sh`·
  `wazuh_app_config.sh` 어느 쪽도 참조하지 않는 값)는 선언하지 않는다.
- Wazuh API 인증: `WAZUH-01`의 manager가 이미 provisioning한 `wazuh-01-api` 사용자(`kv/wazuh/manager`의
  `api_username`/`api_password`)를 그대로 재사용한다. 새 API 사용자를 만들지 않는다.

두 값 모두 `gitops/tools/wazuh-02/provision.sh`가 WAZUH-01 provision이 이미 만든 로컬
입력(`root-ca.pem`, `indexer-admin-password`, `api-password`)에서 복사해 새 경로
`kv/wazuh/dashboard`에 쓴다. 새 credential을 생성하지 않고, indexer·manager·bootstrap의
policy·role·kv는 건드리지 않는다.

| Vault 경로 | 소비자 | 내용 |
|---|---|---|
| `kv/wazuh/dashboard` | `wazuh-dashboard` SA | root CA, `dashboard_username`/`password`(admin 재사용), `api_username`/`password`(`wazuh-01-api` 재사용) |

### 설계 결정: 내부 TLS·PVC 없음

Dashboard의 `server.ssl.*`는 켜지 않는다(`files/opensearch_dashboards.yml`). ClusterIP로만
존재하고 Pomerium이 외부 TLS를 종단하므로 내부 자체 서명 TLS 계층을 추가로 얹지 않는다.
`OBS-02` Grafana·`GITOPS-02` Argo(Route에서 `tls_skip_verify`로 자체서명을 흡수)와 같은
결정이다. indexer(9200)로 나가는 연결은 여전히 TLS이며 기본값인 full hostname 검증을 쓴다
(indexer node 인증서 SAN에 `indexer.wazuh.svc.cluster.local`이 이미 있다).

PVC도 만들지 않는다. upstream Dashboard 컨테이너는 상태를 갖지 않는다. keystore와
`data/wazuh/config/wazuh.yml`은 매 기동마다 entrypoint가 다시 만들거나 멱등하게 append한다.

### Kyverno

새 `PolicyException`이 없다. `wazuh-dashboard` 컨테이너는 upstream Dockerfile이 만드는
`wazuh-dashboard` 사용자(UID/GID 1000)로 이미 non-root로 뜨고 `cap_net_bind_service`도
빌드 시점에 제거돼 있어 `pol-01-require-pod-run-as-non-root`를 그대로 통과한다.
`drop: [ALL]` 뒤에 추가하는 capability도 없다.

## 설치

1. `gitops/tools/wazuh-01/provision.sh apply`로 Vault policy·role·KV를 만든다.
2. Kubernetes API audit는 `infra/ansible/roles/k3s_baseline`이 소유한다.
   `ansible-playbook -i inventory/hosts.local playbooks/k3s-baseline.yml`이 정책 파일과
   apiserver 인자를 선언하고 k3s를 한 번 재시작한다.
3. `gitops/tools/wazuh-01/verify-live.sh capacity-pre`로 배포 전 값을 기록한다.
4. Argo가 `platform-root`에서 `wazuh` child를 동기화한다.
5. OPNsense Wazuh Agent를 [`apply-opnsense.sh`](../../tools/wazuh-01/apply-opnsense.sh)로 설치·등록한다.
6. `gitops/tools/wazuh-01/verify-live.sh verify`를 한 번 실행한다.
7. 6까지 모두 통과한 뒤에만
   [`finalize-opnsense-snapshot.sh`](../../tools/wazuh-01/finalize-opnsense-snapshot.sh)를 실행해
   `infra/opnsense/config.xml` masked drift snapshot을 갱신한다.

`apply-opnsense.sh apply`의 성공은 라이브 적용이 끝났다는 뜻이지 snapshot이 갱신됐다는 뜻이
아니다. `apply-opnsense.sh`는 `check-drift.sh --update`를 직접 호출하지 않는다. 6번 전에
snapshot을 갱신하면 아직 실패한 배포나 동시 foreign drift를 정상 상태로 흡수할 수 있기
때문이다(`WAZUH-01-FIX-01`). `finalize-opnsense-snapshot.sh`는 live와 snapshot의 diff를
hunk 단위로 승인 목록(firmware plugin 목록의 `os-wazuh-agent` 추가, `WazuhAgent` subtree
신규 추가, `IDS`의 `persisted_at`만 변경)과 대조하는 exact-diff gate를 통과한 뒤에만
`check-drift.sh --update`를 부르고, 그 직후 일반 `check-drift.sh`로 drift가 없는지 다시
확인한다. 승인 범위 밖 차이가 하나라도 있으면 라이브를 건드리지 않고 중단한다.

### WAZUH-02 설치

WAZUH-01이 이미 `Synced/Healthy`인 상태를 전제로 한다.

1. `gitops/tools/wazuh-02/provision.sh apply`로 `kv/wazuh/dashboard` Vault policy·role·KV를
   만든다(WAZUH-01의 policy·role·kv는 바꾸지 않는다).
2. `gitops/tools/wazuh-02/verify-live.sh capacity-pre`로 배포 전 available·swap·PVC를 기록한다.
3. Argo가 `platform-root`에서 `wazuh`·`pomerium` child를 동기화해 Dashboard와 Route를 만든다.
4. `gitops/tools/wazuh-02/opnsense-alias.py apply`로 `wazuh` Unbound alias를 등록한다.
5. `gitops/tools/wazuh-02/verify-live.sh verify`를 한 번 실행한다.

## 완료 증거

[`verify-live.sh`](../../tools/wazuh-01/verify-live.sh) 하나가 아래 다섯 개만 판정한다.
UI 클릭, 중복 port-forward, 별도 smoke test, 부하 시험은 하지 않는다. OPNsense snapshot
갱신은 `verify-live.sh`가 아니라 위 설치 7단계의 `finalize-opnsense-snapshot.sh`가 소유한다.

1. 대표 Suricata event 한 건이 소스에서 Wazuh로 직접 수집·탐지·검색됨
2. Loki relay 부재와 같은 고정창의 Loki 보안 event 복제본 0건
3. running 설정의 `D30=30일`, `A90=90일`
4. 같은 고정창의 실제 index 증가량 환산이 D30·A90·전체 상한 이내이고 배포 전후
   available·swap·PVC가 정지선 이내
5. active response 비활성과 immutable SHA의 `platform-root`·`wazuh` child `Synced/Healthy`

active response 비활성 판정은 세 가지다. running `ossec.conf`의
`<active-response><disabled>yes</disabled></active-response>`, 주석을 제거한 뒤 `<command>`
정의 0건, 그리고 manager가 agent에 배포하는 `/var/ossec/etc/shared/ar.conf`에
`firewall-drop`·`host-deny`·`route-null`·`disable-account`·`netsh`·`ip-customblock`이 0건인 것이다.
`wazuh-execd` 상주 여부는 기준이 아니다. 이 daemon은 active response 설정과 무관하게 항상
뜨고, `ar.conf`에 남는 `restart-wazuh` 두 줄은 Wazuh가 설정 배포용으로 항상 포함하는
내장 항목이라 트래픽 차단이나 계정 조작을 하지 않는다. agent 쪽
`<active-response><disabled>yes</disabled>`는 `apply-opnsense.sh`가 저장값으로 판정한다.

대표 event는 고정창 안에서 정확히 한 번 만든다. 검증 실행 host(`10.10.60.2`)는 Suricata
`HOME_NET`(`10.10.10.0/24`~`10.10.50.0/24`) 밖이라 `$EXTERNAL_NET`이고, `k3s-01`으로 가는
cleartext HTTP는 감시 대상 `vlan02`를 지난다. User-Agent `Mozilla/5.0 zgrab/0.x`와 고정
source port 하나로 `emerging-scan.rules`의 sid `2029054`가 정확히 한 건 발생하며,
`data.alert.signature_id`와 `data.src_port`로 유일하게 검색한다.

### 증거 한계

- `local-path`는 PVC 요청량을 강제하지 않는다. 16 GiB는 선언·회계 상한이고 실제 저장
  상한은 ISM 보존과 환산 판정이 지킨다.
- index 증가량은 고정창의 `store.size_in_bytes` 차이를 일·기간으로 환산한 값이다. segment
  merge 때문에 짧은 창에서는 실제보다 작게 보일 수 있으므로 상한 판정에만 쓰고 정확한
  용량 예측으로 쓰지 않는다.
- 오탐 gate는 고정창의 D30·A90 index 내용만 본다. OPNsense가 만들지만 중앙 저장에서
  제외한 event의 오탐률은 이 gate가 판정하지 않는다.
- Wazuh API(TCP 55000)는 ClusterIP만 있고 완료 증거에 쓰지 않는다.

### WAZUH-02 완료 증거

[`verify-live.sh`](../../tools/wazuh-02/verify-live.sh) 하나가 아래만 판정한다. WAZUH-01이
이미 판정한 Suricata 수집·D30/A90 라우팅·NIDS-01 제외는 다시 검증하지 않는다.

1. 배포 직전·직후 available·swap·PVC가 정지선 이내, 배포 후 available이 `SOAR-01` 진입선
   12 GiB를 남기는지 기록
2. Dashboard 로그인 뒤 D30(`wazuh-alerts-4.x-*`)·A90(`wazuh-alerts-4.x-audit-*`) index를
   검색해 `WAZUH-01`이 이미 수집한 대표 Suricata event(sid `2029054`)를 Dashboard UI 경로로
   조회. 새 트래픽을 만들어 재수집을 다시 검증하지 않는다 — 이미 저장된 event를 Dashboard가
   실제로 질의·표시하는지만 본다.
3. `/platform-privileged` 계정은 Route 통과, `/platform-users`만 있는 계정과 미소속 계정은
   403
4. active response 비활성과 ISM 정책(`wazuh-01-d30`, `wazuh-01-a90`) 두 건이 배포 전후로
   그대로임
5. `wazuh` alias 내부 A 1건, 내부 AAAA·공개 A/AAAA 0건
6. immutable SHA의 `platform-root`·`wazuh`·`pomerium` child `Synced/Healthy`

### 2026-08-04 라이브 완료 증거

immutable root `f96520c5f13dd8e1a002102d1c1819007e206a2a`와 child 설정
`b7a36d8d1ad2ed2f71085a593b90d322d6c63ab0`(`wazuh`·`pomerium` 둘 다 이 commit)에서 다음을
검증했다.

| acceptance | 라이브 증거 | 판정 |
|---|---|---|
| capacity 정지선 | 배포 전 available 13,179,863,040 bytes(12.273 GiB)·swap 0, 배포 후 available 12,715,151,360 bytes(11.842 GiB)·swap 0, PVC 91.125 GiB로 배포 전후 불변 | 통과, 8 GiB 정지선 위 3.842 GiB |
| `SOAR-01` 진입선 | 배포 후 available 11.842 GiB, 진입선 12 GiB에 169,750,528 bytes(약 161.9 MiB) 미달 | **미달**, `k3s-01` 32 GiB 증설이 `SOAR-01` 선행 |
| Dashboard D30/A90 검색 | `admin` 계정으로 Dashboard 자체 보안에 로그인 뒤 `/api/console/proxy`로 `wazuh-alerts-4.x-*`(sid `2029054*`)·`wazuh-alerts-4.x-audit-*`(`rule.id:[100100 TO 100109]`) 조회, 둘 다 기존 저장 문서 hit | 통과 |
| RBAC | `/platform-privileged`(`imcherry-admin`)는 Pomerium Route 통과, `/platform-users`만 가진 `imcherry`는 403 | 통과 |
| active response·ISM 불변 | running `ossec.conf`의 `<active-response><disabled>yes</disabled>`, `ar.conf` 차단성 명령 0건, `wazuh-01-d30`·`wazuh-01-a90` 정책 그대로 | 통과 |
| alias | Unbound `wazuh` A 1건, 공개 A/AAAA 미등록(내부 alias만 추가) | 통과 |
| Argo | 위 immutable root·child가 모두 `Synced/Healthy` | 통과 |

`gitops/root/wazuh-project.yaml`의 `namespaceResourceWhitelist`에 `apps/Deployment`가 없어서
첫 sync가 `resource apps:Deployment is not permitted in project wazuh`로 거부됐다. manager·
indexer가 StatefulSet만 썼기 때문에 이 whitelist에 Deployment가 없었다. 같은 커밋에서
`apps/Deployment`를 추가해 해결했다.

indexer·manager는 배포 전후로 Pod 재시작·restart count 변화가 없었다(`wazuh-indexer-0`,
`wazuh-manager-master-0` 둘 다 8h 무변화). `pomerium` Deployment는 새 ConfigMap 해시를
반영하며 정상적으로 한 번 재기동했다(기존 Route·Portal 기능 영향 없음, Grafana·Argo 등
기존 Route는 이 재기동과 무관하게 유지).

## Rollback

라이브 검증이 실패하면 새 작업 ID를 만들지 않고 아래 순서로 되돌린 뒤 같은 브랜치에서
원인을 고친다. `wazuh` namespace와 Wazuh 전용 PVC 삭제는 승인된 rollback 범위이며 공유
PVC와 다른 서비스는 건드리지 않는다.

1. `platform-root`의 automated sync를 끈다.

   ```bash
   kubectl -n argocd patch application platform-root --type merge \
     -p '{"spec":{"syncPolicy":{"automated":null}}}'
   ```

2. `Application/wazuh`를 foreground로 삭제해 child resource를 제거한다.

   ```bash
   kubectl -n argocd delete application wazuh --cascade=foreground --wait=true
   ```

3. 남은 `wazuh` namespace와 Wazuh 전용 PVC를 삭제한다.

   ```bash
   kubectl delete namespace wazuh --wait=true
   ```

4. prune 보호한 `AppProject/wazuh`를 삭제한다.

   ```bash
   kubectl -n argocd delete appproject wazuh
   ```

5. `platform-root`의 `targetRevision`과 automated sync를 시작 main SHA로 복원한다.
6. 작업 branch의 child 선언이 literal `main`인지 확인한다.
7. `platform-root`와 기존 Application이 모두 `Synced/Healthy`인지 확인한다.
8. `ARGO-ROOT` 잠금을 푼다.

OPNsense Wazuh Agent는 `apply-opnsense.sh rollback`이 서비스 정지 → 설정 제거 →
플러그인 remove 순서로 되돌리고 `check-drift.sh`로 무변경을 확인한다.
Kubernetes API audit는 `infra/ansible/roles/k3s_baseline`에서 audit 인자와 정책 파일을
제거하고 playbook을 다시 실행해 되돌린다. Vault policy·role·KV와 저장소 밖 credential
입력은 다음 main sync를 위해 보존하며 credential 회전은 이 rollback 범위가 아니다.

### WAZUH-02 rollback

위 절차는 WAZUH-01 최초 배포용이다. indexer·manager가 이미 운영 중인 지금은 그 절차를 쓰지
않는다. Dashboard만 되돌리고 indexer·manager·retention(ISM 정책, D30·A90 데이터)은 그대로
둔다.

1. `dashboard.yaml`을 `kustomization.yaml`의 `resources`에서, `vault-agent-dashboard.hcl`과
   `wazuh-dashboard-conf` 항목을 `configMapGenerator`에서 빼고 `serviceaccounts.yaml`의
   `wazuh-dashboard` SA와 `network-policies.yaml`의
   `wazuh-dashboard-pomerium-ingress`를 지운 뒤 커밋한다. `gitops/apps/pomerium`의 `wazuh`
   Route, `wazuh-egress.yaml`, `ingress.yaml`의 `wazuh.imcherry5778.xyz` host/tls 항목도
   같은 커밋에서 함께 뺀다.
2. `platform-root`의 automated sync가 살아 있으면 위 커밋을 반영해 `wazuh`·`pomerium`
   child가 Dashboard Deployment/Service/ConfigMap과 Route·NetworkPolicy만 prune한다.
   `wazuh-indexer`·`wazuh-manager-master` StatefulSet과 그 PVC는 kustomization에 그대로
   남아 있으므로 건드려지지 않는다.
3. `gitops/tools/wazuh-02/provision.sh rollback`으로 `kv/wazuh/dashboard`와
   `wazuh-dashboard` policy·role만 지운다. `kv/wazuh/{indexer,manager,bootstrap}`은
   손대지 않는다.
4. `gitops/tools/wazuh-02/opnsense-alias.py rollback`으로 `wazuh` Unbound alias를 지운다.
5. `docs/ip-plan.md`의 `wazuh.imcherry5778.xyz` 행을 제거한다.
6. indexer `_cluster/health`와 manager `statefulset/wazuh-manager-master` rollout이 rollback
   전후로 동일하게 Healthy인지 확인해 회귀가 없음을 판정한다.
