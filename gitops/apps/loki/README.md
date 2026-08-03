# Loki 운영 로그 기준선

이 디렉터리는 `LOKI-01`의 Grafana Alloy와 Loki, 그리고
[`audit-event-standard.md`](../../../docs/audit-event-standard.md)의 `O7` 운영 로그만 소유한다.
Wazuh 보안 event 수집, Prometheus 계열 metrics·경보, Grafana UI, 방화벽, 공개 경로와 자동
대응은 소유하지 않는다.

## 수집 경계

1차 범위는 `k3s-01` 안의 Pod log와 `core/v1 Event`다.

| 원본 | Alloy allowlist | Loki에 남는 내용 | 명시적 drop |
|---|---|---|---|
| Falco `falco` container | JSON이 아닌 engine/lifecycle 출력 | 고정 O7 record와 Pod name/UID metadata | `rule`이 든 Falco JSON 전체 |
| Pomerium `pomerium` container | 사용자·요청 context가 없는 warn/error | 고정 O7 error record와 Pod name/UID metadata | `authorize`·`authenticate`·`envoy`·`identity_manager`, session component, user/request/session/path/IP key가 있는 record |
| Vault `vault` container | JSON이 아닌 server lifecycle 출력 | 고정 O7 record와 Pod name/UID metadata | audit JSON 전체 |
| Keycloak `keycloak` container | `org.keycloak.events`가 아닌 server log | 고정 O7 record와 Pod name/UID metadata | user/admin event logger 전체 |
| `core/v1 Event` | Python 표준 라이브러리 watcher가 Kubernetes watch API에서 event time·reason·reporting component·involved object name/UID만 출력하고 Alloy가 다시 parse | 고정 O7 record와 allowlist metadata | `message` 원문과 resourceVersion은 생성 단계부터 제외 |

Loki line은 source별 고정 JSON이며 원문 `message`, token, header, body, query, command와 파일
내용을 담을 수 없다. line에는 `event.class/action/outcome/source/dataset`, `observer.*`,
`actor.kind`, `correlation.kind`만 남긴다. Loki entry timestamp는 CRI envelope의 `event.time`이고
collector 시각 `event_ingested`는 structured metadata다. `cluster`, `namespace`, `app`,
`container`, `level`, `event_class`, `retention`만 label이다. Pod name/UID, Event object
name/UID·reason·reporting component와 `event_time`도 structured metadata다.

Alloy는 Kubernetes API로 Pod log를 tail하며 hostPath와 node log file을 마운트하지 않는다.
Event watcher도 API watch 결과를 메모리에서 allowlist JSON으로 바꿀 뿐 원문을 파일에 쓰지 않는다.
Alloy storage는 memory `emptyDir` 32 MiB이고 client WAL은 꺼져 있다. Loki의 2 GiB bounded
`emptyDir`에는 **마스킹 뒤** WAL·active index·compactor 작업 파일만 있으며 Pod 재생성 때 S3
TSDB에서 다시 읽는다.

다음 `O7`은 범위를 넓혀 일정을 지연시키지 않기 위해 1차 수집에서 제외한다.

- Suricata engine, NetBird와 Warpgate systemd는 클러스터 밖 source라 node/host agent가 없다.
- CrowdSec AppSec/LAPI Pod의 현재 logfmt `msg`는 lifecycle과 match context를 안정적으로 분리하는
  source field가 없다. security event는 `WAZUH-01`이 직접 수집하며, operational stream이 제품
  설정에서 분리된 뒤 §9의 후속 수집 작업으로 연다.
- 위 외부 source도 제품 local log를 유지한다. `OBS-01`은 metrics·경보·Grafana UI만 맡으며
  이 log 수집 누락을 대신하지 않는다.

## 저장소·retention·자격증명

Loki 3.6.11 단일 binary 한 replica가 TSDB v13 index와 chunk를 `object-01` SeaweedFS S3의
`loki-chunks` bucket에 path-style TLS로 저장한다. retention은 168시간이고 compactor가 5분마다
retention을 적용한다. retained chunk 전체 14 GiB와 저장 후 증가량 2 GiB/일이 hard cap이며,
초과하면 PVC·bucket·disk를 늘리지 않고 source/event class를 줄인다.

local-path PVC 요청은 **0개**다. 따라서 선언 PVC 합계는 늘지 않으며 96 GiB 경고선 여유도
배포 전 실측값에서 그대로다. S3 14 GiB hard cap은 `object-01`의 bucket data 170 GiB 구획
중 10% 미만이다. 2 GiB `emptyDir`는 PVC가 아니고 `k3s-01` guest disk 정지 기준을 따른다.

`loki` ServiceAccount의 `audience=vault` projected token으로 Pod-local Vault Agent init이
`kv/loki/runtime`의 bucket-scoped key 두 개만 memory `emptyDir`의 AWS shared credentials
형식으로 렌더링한다. Loki container는 ServiceAccount token과 Kubernetes Secret을 마운트하지
않는다. S3 identity는 `Read/List/Write/Delete:loki-chunks`만 허용하고 다른 bucket은 거부한다.
Delete는 compactor retention에만 필요하다.

## 고정 release와 재생성

chart tarball SHA-256, source tag commit, image index/amd64 digest와 렌더 hash는
[`release-metadata.env`](release-metadata.env)가 소유한다. 렌더는 다음 한 경로만 사용한다.

```bash
LOKI01_RENDER_DIR=$(mktemp -d)
helm template loki \
  https://github.com/grafana/helm-charts/releases/download/helm-loki-7.2.0/loki-7.2.0.tgz \
  --namespace loki \
  --kube-version 1.36.2 \
  --skip-tests \
  --values gitops/apps/loki/values-loki-01.yaml \
  > "${LOKI01_RENDER_DIR}/loki.yaml"
helm template alloy \
  https://github.com/grafana/helm-charts/releases/download/alloy-1.11.0/alloy-1.11.0.tgz \
  --namespace loki \
  --kube-version 1.36.2 \
  --skip-tests \
  --values gitops/apps/loki/values-alloy-01.yaml \
  > "${LOKI01_RENDER_DIR}/alloy.yaml"
sed -i 's/[[:space:]]\+$//' "${LOKI01_RENDER_DIR}/loki.yaml" "${LOKI01_RENDER_DIR}/alloy.yaml"
cp "${LOKI01_RENDER_DIR}/loki.yaml" gitops/apps/loki/install.yaml
printf '\n---\n' >> gitops/apps/loki/install.yaml
sed -n '1,$p' "${LOKI01_RENDER_DIR}/alloy.yaml" >> gitops/apps/loki/install.yaml
sha256sum gitops/apps/loki/install.yaml
```

## 완료 증거와 rollback

[`verify-live.sh`](../../tools/loki-01/verify-live.sh)는 `ARGO-ROOT` 잠금 아래 §7 acceptance 여섯
항목만 한 번 검증한다. 30분 고정 관측창의 시간순 최초 5,000건을 고정 표본으로 삼아 O7
field/label을 확인하고, source별 security filter는 같은 전체 시간창에서 0건을 확인한다. Loki
`/labels`의 저cardinality index 집합과 query 결과에 합쳐진 structured metadata를 분리해 판정한다.
S3 저장 후 증가량,
label/structured metadata, local spool 부재, running config의 7일 retention과 compactor 성공,
immutable SHA의 root·child `Synced/Healthy`를 함께 판정한다. 방화벽, DNS, Ingress, OIDC,
Grafana와 metrics 경보는 다시 확인하지 않는다.

### 2026-08-03 라이브 완료 증거

최신 `origin/main`을 포함한 immutable root
`d785e48ed66d6078a27379df6272df69ea624170`과 child 설정
`237707bcae1b33f686818c35f8401b046b74b99b`에서 다음 여섯 항목을 한 번 검증했다.

| acceptance | 라이브 증거 | 판정 |
|---|---|---|
| O7 전용·보안 event 0건 | 고정 표본 5,000건 모두 `event_class=O7`; 같은 창의 Falco rule match, Pomerium authz, Vault audit, Keycloak event 질의는 각각 0건 | 통과 |
| 저장 상한 | `2026-08-03T01:23:08Z`–`01:53:13Z` 1,805초 동안 S3 118,301→272,996 bytes, 증가 154,695 bytes; 일 환산 7,404,792 bytes, retained 관측값 272,996 bytes | 14 GiB·2 GiB/일 이하 |
| label cardinality | index label은 `app`, `cluster`, `container`, `event_class`, `level`, `namespace`, `retention` 일곱 개뿐이고 `resource_uid`는 query structured metadata에 존재 | 통과 |
| 수집 전 마스킹·spool | source는 Kubernetes API, Alloy storage는 memory, client WAL은 disabled, Event 원문 `message`는 생성 단계부터 없음 | 통과 |
| 7일 retention | running config `retention_period: 1w`, retention enabled; compactor retention 성공 timestamp `1785723146`, 성공 operation 2건 | 통과 |
| Argo 상태 | 위 immutable SHA의 `platform-root`와 `loki`가 모두 `Synced/Healthy` | 통과 |

배포 직전·직후 `k3s-01` guest available은 11,289,554,944→10,812,805,120 bytes,
swap은 0, guest root 여유는 85%, PVC 선언 합계는 66.125 GiB로 동일했다. 12 GiB 경고
구간이지만 8 GiB 정지선보다 2,119.895 MiB 높아 배포·검증을 계속했고 신규 PVC는 없다.
검증 후 root는 시작 main SHA로 rollback하고 child와 namespace를 제거했으며 S3 bucket과 runtime
identity는 다음 main sync를 위해 보존했다.

정상 child `targetRevision`은 `main`이다. merge 전에는 최신 `origin/main`에 rebase한 설정
commit을 먼저 push하고, 다음 pointer commit에서 `loki` child만 설정 SHA로 고정한 뒤
`platform-root`를 pointer SHA로 전환한다. 실패하거나 검증이 끝나면 다음 순서로 시작 main
SHA에 rollback한다.

1. `platform-root` automated sync를 잠시 끈다.
2. `Application/loki`를 foreground 삭제해 StatefulSet·Deployment·cluster RBAC·namespace를
   제거한다. S3 bucket과 Vault/SeaweedFS identity는 보존한다.
3. prune 보호한 `AppProject/loki`를 삭제한다.
4. root `targetRevision`과 automated sync를 시작 main SHA로 복원하고 `Synced/Healthy`를 확인한다.
5. 작업 branch의 child 선언이 literal `main`인 것을 확인한 뒤 `ARGO-ROOT` 잠금을 푼다.

S3 bucket·credential 삭제나 disk 확장은 이 rollback 범위가 아니다.
