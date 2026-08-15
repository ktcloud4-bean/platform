# SUPPLY-02: k3s 컨테이너 이미지 공급망 인벤토리 및 감사 보고서

이 문서는 `SUPPLY-02` 작업에서 k3s 클러스터 전체 워크로드를 대상으로 산출한 컨테이너 이미지 인벤토리 실측 데이터와 Kyverno Audit 정책 감사 결과를 기록한다.

단일 원본 추출 도구: `gitops/tools/supply-02/inventory.py`

## 1. 인벤토리 요약 지표 (Metrics Summary)

| 지표 항목 | 실측값 | 설명 |
|---|---|---|
| **총 Live 컨테이너 튜플 수** | `140` | k3s 클러스터에서 실제 가동 중인 Pod 컨테이너 인스턴스 총합 |
| **고유 이미지 참조 수 (Unique Images)** | `65` | 레지스트리/저장소/태그/다이제스트 기준 고유 이미지 수 |
| **sha256 다이제스트 고정 이미지 수** | `119` | `@sha256:` 불변 다이제스트로 고정된 컨테이너 수 |
| **Tag-only 미고정 이미지 수** | `21` | sha256 고정 없이 mutable tag로 선언된 컨테이너 수 (`SUPPLY-04` 전환 대상) |
| **Harbor 내부 승격 이미지 수** | `0` | 내부 Harbor(`harbor.imcherry5778.xyz`)에서 소비 중인 이미지 수 |
| **외부 Upstream 직접 참조 수** | `140` | 외부 public registry를 직접 pull 중인 수 (`SUPPLY-03`~`04` Proxy/Curated 대상) |
| **시스템 예외 대상 (System Exceptions)** | `33` | `kube-system`, `kyverno`, `falco`, `wazuh` 등 시스템 컴포넌트 |
| **일반 워크로드 대상 (User Workloads)** | `107` | 플랫폼 사용자 및 애플리케이션 서비스 컴포넌트 |

## 2. 레지스트리별 분포 현황 (Registry Distribution)

| 레지스트리 도메인 | 컨테이너 튜플 수 | 비중 (%) | 분류 |
|---|---|---|---|
| `docker.io` | 90 | 64.3% | 외부 Upstream (Proxy Cache 대상) |
| `quay.io` | 34 | 24.3% | 외부 Upstream (Proxy Cache 대상) |
| `ghcr.io` | 8 | 5.7% | 외부 Upstream (Proxy Cache 대상) |
| `docker.gitea.com` | 3 | 2.1% | 외부 Upstream (Proxy Cache 대상) |
| `reg.kyverno.io` | 3 | 2.1% | 외부 Upstream (Proxy Cache 대상) |
| `public.ecr.aws` | 1 | 0.7% | 외부 Upstream (Proxy Cache 대상) |
| `registry.k8s.io` | 1 | 0.7% | 외부 Upstream (Proxy Cache 대상) |

## 3. 소스별 튜플 비교 및 차이점 분석 (Git vs Render vs Live)

- **Git 선언 튜플 수**: `89`
- **Render 렌더링 튜플 수**: `82`
- **Live 실행 튜플 수**: `140`

### 차이점 발생 원인 분석:
1. **Helm Chart-Generated 컴포넌트**: Vault agent-injector, Cert-Manager webhook, Harbor exporter 등 Helm 릴리스가 런타임에 주입하는 sidecar/initContainer로 인해 Live 튜플 수가 순수 Git 선언 튜플보다 많음.
2. **Replica 확장**: Deployment/StatefulSet의 `replicas >= 2` 설정(Argo CD repo-server 2대 등)으로 인해 Pod 레벨 Live 튜플 수가 선언된 컨트롤러 수보다 확장됨.
3. **DaemonSet 노드 배포**: Falco, Flannel 등 노드당 1대씩 기동되는 데몬셋 런타임 인스턴스.

## 4. Tag-only (sha256 미고정) 잔여 목록 (`SUPPLY-04` 해소 대상)

| 네임스페이스 | 컨트롤러 | 컨테이너 | 이미지 주소 | 비고 |
|---|---|---|---|---|
| `argocd` | `ReplicaSet/argocd-applicationset-controller-54c748fccd` | `standard:argocd-applicationset-controller` | `quay.io/argoproj/argocd:v3.5.0-rc3` | `none` |
| `argocd` | `ReplicaSet/argocd-dex-server-5fbb99cc85` | `standard:dex` | `ghcr.io/dexidp/dex:v2.45.0` | `none` |
| `argocd` | `ReplicaSet/argocd-dex-server-5fbb99cc85` | `init:copyutil` | `quay.io/argoproj/argocd:v3.5.0-rc3` | `none` |
| `argocd` | `ReplicaSet/argocd-notifications-controller-56f9f45f85` | `standard:argocd-notifications-controller` | `quay.io/argoproj/argocd:v3.5.0-rc3` | `none` |
| `argocd` | `ReplicaSet/argocd-redis-69c8cbd569` | `standard:redis` | `public.ecr.aws/docker/library/redis:8.2.3-alpine` | `none` |
| `argocd` | `ReplicaSet/argocd-redis-69c8cbd569` | `init:secret-init` | `quay.io/argoproj/argocd:v3.5.0-rc3` | `none` |
| `argocd` | `ReplicaSet/argocd-repo-server-f54bdc84b` | `standard:argocd-repo-server` | `quay.io/argoproj/argocd:v3.5.0-rc3` | `none` |
| `argocd` | `ReplicaSet/argocd-repo-server-f54bdc84b` | `init:copyutil` | `quay.io/argoproj/argocd:v3.5.0-rc3` | `none` |
| `argocd` | `ReplicaSet/argocd-server-6bc7687ccc` | `standard:argocd-server` | `quay.io/argoproj/argocd:v3.5.0-rc3` | `none` |
| `argocd` | `StatefulSet/argocd-application-controller` | `standard:argocd-application-controller` | `quay.io/argoproj/argocd:v3.5.0-rc3` | `none` |
| `kube-system` | `DaemonSet/svclb-obs-loki-host-gateway-8cb5125c` | `standard:lb-tcp-3100` | `rancher/klipper-lb:v0.4.17` | `system-namespace-kube-system` |
| `kube-system` | `DaemonSet/svclb-traefik-0507a580` | `standard:lb-tcp-80` | `rancher/klipper-lb:v0.4.17` | `system-namespace-kube-system` |
| `kube-system` | `DaemonSet/svclb-traefik-0507a580` | `standard:lb-tcp-443` | `rancher/klipper-lb:v0.4.17` | `system-namespace-kube-system` |
| `kube-system` | `Job/helm-install-traefik` | `standard:helm` | `rancher/klipper-helm:v0.11.1-build20260615` | `system-namespace-kube-system` |
| `kube-system` | `Job/helm-install-traefik-crd` | `standard:helm` | `rancher/klipper-helm:v0.11.1-build20260615` | `system-namespace-kube-system` |
| `kube-system` | `Pod/helper-pod-delete-pvc-3847f34d-abbe-4a55-98e1-0cbbc4ccd6f4` | `standard:helper-pod` | `rancher/mirrored-library-busybox:1.37.0` | `system-namespace-kube-system` |
| `kube-system` | `Pod/helper-pod-delete-pvc-7061170c-89fc-4d2c-8859-eddd938d63a0` | `standard:helper-pod` | `rancher/mirrored-library-busybox:1.37.0` | `system-namespace-kube-system` |
| `kube-system` | `ReplicaSet/coredns-7d8645499d` | `standard:coredns` | `rancher/mirrored-coredns-coredns:1.14.4` | `system-namespace-kube-system` |
| `kube-system` | `ReplicaSet/local-path-provisioner-5fc8cb77c8` | `standard:local-path-provisioner` | `rancher/local-path-provisioner:v0.0.36` | `system-namespace-kube-system` |
| `kube-system` | `ReplicaSet/metrics-server-7c86f97b8d` | `standard:metrics-server` | `rancher/mirrored-metrics-server:v0.8.1` | `system-namespace-kube-system` |
| `kube-system` | `ReplicaSet/traefik-76d68bb8b4` | `standard:traefik` | `rancher/mirrored-library-traefik:3.7.4` | `system-namespace-kube-system` |

## 5. 시스템 Exact 예외 목록 (System Exact Exceptions)

| 네임스페이스 | 컨트롤러 | 컨테이너 | 이미지 주소 | 예외 사유 |
|---|---|---|---|---|
| `falco` | `DaemonSet/falco` | `standard:falco` | `docker.io/falcosecurity/falco:0.44.1@sha256:d0cfe422d6ac0e0f20857798f46c7d7273210e1b064b22821e4e6e7f843cde6b` | `system-security-falco` |
| `falco` | `DaemonSet/falco` | `init:falcoctl-artifact-install` | `docker.io/falcosecurity/falcoctl:0.13.0@sha256:0eeb79adc580ae6a5abfdefd7f8f0fed9151fcb545f015c84e8f1d7b2d8a6b02` | `system-security-falco` |
| `kube-system` | `DaemonSet/svclb-obs-loki-host-gateway-8cb5125c` | `standard:lb-tcp-3100` | `rancher/klipper-lb:v0.4.17` | `system-namespace-kube-system` |
| `kube-system` | `DaemonSet/svclb-traefik-0507a580` | `standard:lb-tcp-80` | `rancher/klipper-lb:v0.4.17` | `system-namespace-kube-system` |
| `kube-system` | `DaemonSet/svclb-traefik-0507a580` | `standard:lb-tcp-443` | `rancher/klipper-lb:v0.4.17` | `system-namespace-kube-system` |
| `kube-system` | `Job/helm-install-traefik` | `standard:helm` | `rancher/klipper-helm:v0.11.1-build20260615` | `system-namespace-kube-system` |
| `kube-system` | `Job/helm-install-traefik-crd` | `standard:helm` | `rancher/klipper-helm:v0.11.1-build20260615` | `system-namespace-kube-system` |
| `kube-system` | `Pod/helper-pod-delete-pvc-3847f34d-abbe-4a55-98e1-0cbbc4ccd6f4` | `standard:helper-pod` | `rancher/mirrored-library-busybox:1.37.0` | `system-namespace-kube-system` |
| `kube-system` | `Pod/helper-pod-delete-pvc-7061170c-89fc-4d2c-8859-eddd938d63a0` | `standard:helper-pod` | `rancher/mirrored-library-busybox:1.37.0` | `system-namespace-kube-system` |
| `kube-system` | `ReplicaSet/coredns-7d8645499d` | `standard:coredns` | `rancher/mirrored-coredns-coredns:1.14.4` | `system-namespace-kube-system` |
| `kube-system` | `ReplicaSet/local-path-provisioner-5fc8cb77c8` | `standard:local-path-provisioner` | `rancher/local-path-provisioner:v0.0.36` | `system-namespace-kube-system` |
| `kube-system` | `ReplicaSet/metrics-server-7c86f97b8d` | `standard:metrics-server` | `rancher/mirrored-metrics-server:v0.8.1` | `system-namespace-kube-system` |
| `kube-system` | `ReplicaSet/traefik-76d68bb8b4` | `standard:traefik` | `rancher/mirrored-library-traefik:3.7.4` | `system-namespace-kube-system` |
| `kyverno` | `ReplicaSet/kyverno-admission-controller-b744d498b` | `standard:kyverno` | `reg.kyverno.io/kyverno/kyverno:v1.18.2@sha256:0a540e2ddf74d0d2d3d45f9ef248d7dbc96576accdbcc6a2dd7eaff9fea56504` | `system-security-kyverno` |
| `kyverno` | `ReplicaSet/kyverno-admission-controller-b744d498b` | `init:kyverno-pre` | `reg.kyverno.io/kyverno/kyvernopre:v1.18.2@sha256:cd8cb4a31d25b3992734fb8f24a90ef691c90ce49338c89bea96792160eacb98` | `system-security-kyverno` |
| `kyverno` | `ReplicaSet/kyverno-reports-controller-799f4f6995` | `standard:controller` | `reg.kyverno.io/kyverno/reports-controller:v1.18.2@sha256:f09cf305170014e191b94e1c54f5be73163d8824eefad49349675c4efe43159a` | `system-security-kyverno` |
| `wazuh` | `Job/wazuh-oidc-security-sync-v2` | `standard:renderer` | `docker.io/library/python:3.13.7-alpine3.22@sha256:9ba6d8cbebf0fb6546ae71f2a1c14f6ffd2fdab83af7fa5669734ef30ad48844` | `system-security-wazuh` |
| `wazuh` | `Job/wazuh-oidc-security-sync-v2` | `standard:securityadmin` | `docker.io/wazuh/wazuh-indexer:4.14.7@sha256:853230e332b3b171ee9c30db91186830d5d66461e8ee0173abb57ede5c4b5d37` | `system-security-wazuh` |
| `wazuh` | `Job/wazuh-oidc-security-sync-v2` | `standard:role-mapping` | `docker.io/library/python:3.13.7-alpine3.22@sha256:9ba6d8cbebf0fb6546ae71f2a1c14f6ffd2fdab83af7fa5669734ef30ad48844` | `system-security-wazuh` |
| `wazuh` | `Job/wazuh-oidc-security-sync-v2` | `init:vault-agent` | `hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54` | `system-security-wazuh` |
| `wazuh` | `Job/wazuh-retention-bootstrap` | `standard:retention` | `docker.io/library/python:3.13.7-alpine3.22@sha256:9ba6d8cbebf0fb6546ae71f2a1c14f6ffd2fdab83af7fa5669734ef30ad48844` | `system-security-wazuh` |
| `wazuh` | `Job/wazuh-retention-bootstrap` | `init:vault-agent` | `hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54` | `system-security-wazuh` |
| `wazuh` | `ReplicaSet/wazuh-04-relay-6b76b558f` | `standard:wazuh-04-relay` | `docker.io/library/python:3.13.7-alpine3.22@sha256:9ba6d8cbebf0fb6546ae71f2a1c14f6ffd2fdab83af7fa5669734ef30ad48844` | `system-security-wazuh` |
| `wazuh` | `ReplicaSet/wazuh-04-relay-6b76b558f` | `standard:wazuh-04-relay-agent` | `docker.io/wazuh/wazuh-agent:4.14.7@sha256:460758c8de2a6227818d5e415c514199e77179f5bbaec77aca5c246c99932ed2` | `system-security-wazuh` |
| `wazuh` | `ReplicaSet/wazuh-04-relay-6b76b558f` | `init:vault-agent` | `hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54` | `system-security-wazuh` |
| `wazuh` | `ReplicaSet/wazuh-06-notifier-665bc7bb9d` | `standard:wazuh-06-notifier` | `docker.io/library/python:3.13.7-alpine3.22@sha256:9ba6d8cbebf0fb6546ae71f2a1c14f6ffd2fdab83af7fa5669734ef30ad48844` | `system-security-wazuh` |
| `wazuh` | `ReplicaSet/wazuh-06-notifier-665bc7bb9d` | `init:vault-agent` | `hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54` | `system-security-wazuh` |
| `wazuh` | `ReplicaSet/wazuh-dashboard-64686c5448` | `standard:wazuh-dashboard` | `docker.io/wazuh/wazuh-dashboard:4.14.7@sha256:48ef2aff42f62ecc7c4a4879f8364696cc26e31634acd9bc3f92a09c3aca413c` | `system-security-wazuh` |
| `wazuh` | `ReplicaSet/wazuh-dashboard-64686c5448` | `init:vault-agent` | `hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54` | `system-security-wazuh` |
| `wazuh` | `StatefulSet/wazuh-indexer` | `standard:wazuh-indexer` | `docker.io/wazuh/wazuh-indexer:4.14.7@sha256:853230e332b3b171ee9c30db91186830d5d66461e8ee0173abb57ede5c4b5d37` | `system-security-wazuh` |
| `wazuh` | `StatefulSet/wazuh-indexer` | `init:vault-agent` | `hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54` | `system-security-wazuh` |
| `wazuh` | `StatefulSet/wazuh-manager-master` | `standard:wazuh-manager` | `docker.io/wazuh/wazuh-manager:4.14.7@sha256:a65dcdb61e48b7064bd7250c5cbd6aceeb9b8043a1a413931a8868793146f06d` | `system-security-wazuh` |
| `wazuh` | `StatefulSet/wazuh-manager-master` | `init:vault-agent` | `hashicorp/vault:2.0.3@sha256:a296a888b118615dc01d5f1a6846e6d4a7277946caaed5b447008fff5fe06b54` | `system-security-wazuh` |

## 6. Kyverno ImageValidatingPolicy Audit 동작 검증

- **적용 정책**: `policies/k3s-image-supply-chain-audit.yaml` (`ImageValidatingPolicy`)
- **동작 모드**: `validationActions: [Audit]`, `failurePolicy: Ignore`, `background: true`
- **결과**: Enforce 전환 0건, 기존 워크로드 차단/재시작 실패 0건 확인.
- **후속 연계**: `SUPPLY-03` (Harbor upstream proxy cache 구축) 및 `SUPPLY-04` (curated project 승격 & digest 고정)로 순차 해소.