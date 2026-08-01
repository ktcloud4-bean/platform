# 목표 아키텍처

이 문서는 확정한 목표와 역할 경계를 기록한다. 실제 진행 상태는 `backlog.md`, 주소는 `ip-plan.md`가 소유한다.

## 설계 기준

- 한 대의 물리 Proxmox에서 운영하는 production-like 랩이다.
- 물리 장애, OPNsense 장애와 Proxmox 장애는 허용한 SPOF다.
- 3개의 VM으로 k3s를 나눠도 물리 장애는 제거되지 않으므로 단일 k3s 노드를 쓴다.
- 격리, 최소 권한, 선언형 재구축, 오프사이트 복구를 HA보다 우선한다.
- HOME과 OOB는 프로젝트 데이터 플레인에 포함하지 않는다.

## 전체 구조

```text
Internet
   │
Cloudflare WAF ── 공개 HTTP 경로만
   │
OPNsense ── 방화벽 · NAT · VLAN 라우팅 · Unbound DNS
   ├─ Suricata IDS ── alert-only 네트워크 관찰
   │ tagged-only 802.1Q
Proxmox
   ├─ k3s-01       플랫폼 워크로드
   ├─ postgres-01  공용 PostgreSQL
   ├─ object-01    SeaweedFS 로컬 S3 · 백업 착지점
   ├─ warpgate-01  특권 세션 중계
   └─ netbird-01   오버레이 제어 플레인

독립 복구: PiKVM/OOB + 장비별 로컬 관리자
오프사이트: AWS S3, AWS 네트워크와는 Site-to-Site VPN
```

관리형 스위치는 현재 필요하지 않다. OPNsense와 Proxmox를 직접 연결하고, 두 번째 물리 노드나 프로젝트용 NAS가 생길 때 재검토한다.

## 실행 단위

모든 Linux VM은 Rocky Linux 9 Minimal을 기본값으로 한다. 다른 배포판이 필요한 제품은 PoC 결과로 예외를 기록한다.

| 실행 단위 | 역할 | 분리 이유 |
|---|---|---|
| OPNsense 베어메탈 | 경계 방화벽·라우터·DNS·네트워크 IDS | 복구 대상인 클러스터와 독립 |
| Proxmox 베어메탈 | 가상화 | 유일한 물리 컴퓨트 노드 |
| `k3s-01` | 단일 서버 k3s | 자원 효율과 local storage 단순성 |
| `postgres-01` | 서비스별 DB·role을 둔 PostgreSQL | 클러스터 재구축과 DB 복구 분리 |
| `object-01` | SeaweedFS S3와 로컬 백업 | k3s 장애와 백업 착지점 분리 |
| `warpgate-01` | SSH 등 특권 세션 중계 | 일반 워크로드·공개 진입점과 분리 |
| `netbird-01` | 원격접속 제어·relay 계열 | 인터넷 노출면을 DMZ에 격리 |

VM 분리는 장애 도메인을 물리적으로 늘리지 않는다. 업데이트 순서, 권한, 방화벽과 복구 단위를 분리하는 것이 목적이다.

각 VM의 vCPU·RAM·디스크 기준값과 호스트 여유 예산은 [`capacity-plan.md`](capacity-plan.md)가 소유한다.

## 부트스트랩과 재현성

유일한 Proxmox의 Day 1은 독립 콘솔에서 대상과 복구 경로를 확인한 뒤 수동 설치한다. 검증된 비밀 아닌 입력을 공식 answer file 템플릿으로 옮기고, 자동설치 ISO는 폐기 가능한 VM·가상 디스크에서만 검증한다. 실제 비밀이 주입된 answer file과 생성 ISO는 Git에 두지 않으며 현재 물리 노드에 자동설치 PoC를 재실행하지 않는다.

설치 직후 PVE Cluster Manager CA 인증서는 암호화된 기준선일 뿐 일반 client가 자동으로 신뢰하는 최종 상태가 아니다. 설치 후 단계에서 Proxmox 내장 ACME와 DNS-01로 `ip-plan.md`의 canonical node 이름에 대한 별도 공인 인증서를 발급한다. 8006은 유지하고 public A/AAAA·NAT·443 reverse proxy는 만들지 않는다. DNS API credential은 설치 ISO에 넣지 않고 Git에서 제외한 구성요소 전용 입력으로 주입하며, 자동 갱신에 필요한 값만 Proxmox의 보호된 ACME plugin config에 남긴다.

그 이후 Proxmox VM은 OpenTofu, VM OS와 k3s bootstrap은 Ansible, Kubernetes 애플리케이션은 Argo CD가 소유한다. 선택 이유와 자동화 경계는 [ADR-0001](adr/0001-proxmox-bootstrap-reproducibility.md)을 따른다.

OpenTofu는 공인 인증서가 라이브에서 검증된 뒤 TLS 검증 우회를 제거한다. Proxmox 인증서의 발급자·private key·갱신 경계와 검토한 대안은 [ADR-0009](adr/0009-proxmox-native-acme-management-tls.md)을 따른다.

## k3s 기준선

- 단일 server 노드와 기본 SQLite datastore를 사용한다.
- 기본 Traefik을 유일한 Kubernetes ingress controller로 사용한다.
- 기본 `local-path` StorageClass로 동적 프로비저닝한다.
- Longhorn과 Ceph는 한 물리 노드에서 복제 효과가 없으므로 사용하지 않는다.
- Kubernetes NetworkPolicy와 Kyverno는 워크로드가 안정된 뒤 Audit부터 적용한다.

`local-path`의 PVC 요청 용량은 기본적으로 디렉터리의 하드 쿼터가 아니다. 예를 들어 `20Gi`를 요청해도 provisioner는 그 이상 쓰는 것을 막지 않으며, 노드 파일시스템을 가득 채울 수 있다. 따라서 다음 통제를 함께 둔다.

- PVC별 요청값과 실제 사용량을 모두 관찰한다.
- k3s VM 디스크에 운영 여유 공간을 예약한다.
- 이미지·로그·백업 보존기간을 제한한다.
- 데이터 투입 전 `local` PV 타입과 Velero 파일 백업 호환성을 복구 테스트로 검증한다.

Git에는 PVC 선언만 저장하고 PVC 데이터나 노드 디렉터리명을 기록하지 않는다. PVC 예산 값과 노드 여유 공간의 정지 기준은 [`capacity-plan.md`](capacity-plan.md)가 소유한다.

## 서비스 배치

| 영역 | 서비스 | 위치 |
|---|---|---|
| 인증 | Keycloak | k3s |
| 웹 접근 정책·포털 | Pomerium Core | k3s |
| ingress·리버스 프록시 | Traefik | k3s |
| 오리진 WAF | CrowdSec AppSec(Coraza + OWASP CRS) | k3s; Traefik route middleware가 판정 연결 |
| 네트워크 IDS | Suricata alert-only | OPNsense |
| 원격 네트워크 접근 | NetBird | 전용 VM |
| 특권 세션 | Warpgate | 전용 VM |
| 시크릿·내부 PKI | Vault | k3s |
| GitOps | Argo CD | k3s |
| Kubernetes 관리 UI | Headlamp | k3s |
| SCM·CI·품질·레지스트리 | Gitea · Jenkins · SonarQube · Harbor | k3s |
| 자동화 | AWX · Renovate | k3s |
| 공급망 검증 | Trivy · Cosign · Kyverno | k3s |
| 런타임 탐지 | Falco | k3s |
| Kubernetes 백업 | Velero + node-agent/Kopia | k3s |
| 운영 로그 | Loki | k3s, 후순위 |
| 메트릭·경보 | kube-prometheus-stack | k3s, 최종 단계 |
| 보안 관제·SIEM/HIDS | Wazuh | 배치 미정; 최종 capacity gate에서 결정 |
| SOAR | Shuffle | 배치 미정; Wazuh·경보·runbook 이후 마지막 단계 |
| 외부 웹 WAF | Cloudflare WAF | 외부 서비스 |
| 오프사이트 백업 | AWS S3 | 외부 서비스 |

NetBox는 채택하지 않았다. 물리 장비 증가, 포트·케이블 관리, API IP 할당 또는 공통 인벤토리 수요가 생길 때만 조건부 PoC를 한다. 채택 전까지 `ip-plan.md`가 주소의 단일 원본이다.

## HTTP 요청 경로

```text
보호된 웹 애플리케이션
Client → [Cloudflare WAF] → OPNsense PF/NAT (Suricata IDS 관찰) → Traefik
       → route-scoped bouncer → CrowdSec AppSec(Coraza + CRS) 판정 → Pomerium → Service

Keycloak 인증 endpoint
Client → Cloudflare WAF → OPNsense PF/NAT (Suricata IDS 관찰) → Traefik → Keycloak

NetBird control·relay
Client → OPNsense의 명시적 공개 port → netbird-01
                    └→ Suricata IDS 관찰

클러스터 내부
Service → Kubernetes Service DNS → Service
```

대괄호의 Cloudflare는 외부 요청일 때만 지난다. Keycloak은 Pomerium의 IdP이므로 Pomerium 뒤에 두지 않는다. Harbor registry API, SeaweedFS S3 API와 비 HTTP 프로토콜도 Pomerium Portal 경로와 분리한다.

역할은 겹치지 않는다.

| 구성요소 | 책임 |
|---|---|
| OPNsense | L3/L4 방화벽·NAT; HTTP reverse proxy가 아님 |
| Suricata | north-south·라우팅된 VLAN 간 흐름의 네트워크 위협 탐지; 신원 정책이나 WAF가 아님 |
| Cloudflare | 공개 HTTP의 엣지 WAF·프록시 |
| Traefik | k3s 진입·TLS·호스트/경로 라우팅 |
| CrowdSec AppSec | 별도 process에서 Coraza·OWASP CRS로 선택한 route의 HTTP 공격 검사 |
| Pomerium | Keycloak 신원으로 Route 접근 결정·업스트림 프록시 |
| 애플리케이션 | 서비스 내부 RBAC |

OPNsense, Proxmox와 k3s ingress는 같은 공개 DNS zone을 사용해도 인증서 private key와 DNS API token을 공유하지 않는다. 각 계층이 별도 인증서를 발급하고, Vault PKI는 내부 TLS·mTLS에 사용한다.

오리진 WAF middleware는 전역 기본값이 아니다. 먼저 전용 내부 test route에서만 검증하고,
Keycloak·NetBird·관리 UI와 기존 공개 route에는 각 소유 작업의 별도 승인·회귀 검증 없이
붙이지 않는다. CrowdSec AppSec의 검사 process는 Traefik 밖에 두지만, community bouncer
plugin 등록은 Traefik의 전역 정적 설정과 Pod 재기동을 요구한다. 따라서 실제 attach 범위가
route 하나여도 plugin source·version·hash, AppSec image·rule snapshot, 재기동 영향과
rollback을 적용 전에 승인받는다. 선택 이유와 금지 범위는
[ADR-0012](adr/0012-crowdsec-appsec-origin-waf.md)를 따른다.

## 탐지·관측 경계

Suricata는 OPNsense에서 PCAP 기반 alert-only IDS로 운영한다. 외부·VLAN 간 흐름을 관찰하되 차단 권한은 주지 않는다. IPS 승격은 정상 트래픽, 오탐, 처리량과 독립 복구를 검증한 뒤의 조건부 작업이며 목표 기준선이 아니다.

Suricata가 모든 공격면을 볼 수 있는 것은 아니다.

- origin TLS의 HTTP 요청은 Traefik에서 복호화된 뒤 해당 route의 bouncer가 별도 CrowdSec
  AppSec(Coraza + OWASP CRS)에 전달해 판정을 받는다.
- 같은 k3s 노드 안의 Pod 간 트래픽은 OPNsense를 지나지 않으므로 NetworkPolicy와 Falco가 담당한다.
- Pomerium·애플리케이션 RBAC는 신원과 리소스 권한을 결정하며 IDS 경보로 대체하지 않는다.

보안 이벤트와 운영 데이터는 다음처럼 분리한다.

```text
Suricata · CrowdSec AppSec(Coraza/CRS) · Falco · 각종 audit event → Wazuh → Wazuh Dashboard → Shuffle
서비스 · 수집기 · 탐지 엔진 운영 로그       → Loki  → Grafana
노드 · 서비스 · 파이프라인 숫자형 상태      → Prometheus → Alertmanager · Grafana
```

Wazuh는 Loki를 입력으로 삼지 않고 각 보안 소스에서 직접 이벤트를 받는다. 소스에는 제한된 로컬 로그를 남겨 중앙 수집 장애가 방화벽·접근 통제·탐지 엔진의 동작을 중단시키지 않게 한다. Wazuh active response와 방화벽 자동 차단은 수동 대응 절차가 검증되기 전에는 사용하지 않는다.

## 인증·권한

Keycloak은 팀 사용자, MFA, OIDC/SAML의 중앙 IdP다. 프로젝트 realm과 Keycloak 관리용 realm을 분리한다.

- 그룹은 팀·직무 소속을 나타낸다.
- Keycloak client role은 애플리케이션 권한을 나타낸다.
- 그룹에 client role을 매핑하고 사용자에게 직접 권한을 붙이는 것은 예외로 한다.
- Pomerium은 명시적인 `groups` claim으로 Route를 허용한다.
- AWS는 전용 SAML client와 role 매핑으로 `AssumeRoleWithSAML`을 사용한다.
- EKS 워크로드 AWS 권한은 Keycloak이 아니라 Pod Identity 또는 IRSA가 담당한다.

일상 계정과 특권 계정을 분리한다. 초기 특권 계정은 온프레미스 총괄 운영자 한 명만 발급하고, 다른 사용자는 필요한 client role만 추가한다. 공동 관리자·공유 계정은 만들지 않는다.

Pomerium Routes Portal에는 일상 관리 UI만 노출한다. OPNsense, Proxmox, Keycloak 관리, Vault 복구, NetBird 복구와 Pomerium 복구는 Pomerium을 유일한 경로로 삼지 않는다.

Headlamp는 k3s의 일상 조회·로그·exec·장애 분석을 위한 관리 UI다. Pomerium은 Headlamp Route 진입을 제한하고, Keycloak OIDC 토큰을 신뢰하도록 구성한 Kubernetes API와 Kubernetes RBAC가 실제 API 권한을 결정한다. Headlamp에 공유 `cluster-admin` ServiceAccount를 주지 않는다. Argo CD가 소유한 선언 리소스는 Git으로 변경하며, Headlamp 직접 변경은 복구 작업으로 제한하고 즉시 Git 상태와 대조한다. IdP나 Headlamp 장애 때 사용할 관리자 kubeconfig는 클러스터 밖에 break-glass로 유지한다.

## Vault

Day 1은 Community Edition, Integrated Storage(Raft), 수동 Shamir unseal을 사용한다. share와 초기 root token은 사용자가 저장소 밖에서 보관한다. AWS KMS auto-unseal은 기반 안정화 후 별도 마이그레이션으로 적용하며 Site-to-Site VPN의 선행조건으로 만들지 않는다.

Vault PKI는 내부 workload 인증서용이며 Proxmox·OPNsense·ingress의 공인 관리 인증서를 자동으로 대체하지 않는다. 사설 CA로 옮기려면 모든 관리 client의 trust 배포와 Vault 장애 시 복구 독립성을 먼저 별도 결정으로 검증한다.

사용할 기능은 다음으로 제한한다.

| 기능 | 용도 |
|---|---|
| KV v2 | 정적 애플리케이션 시크릿 |
| Kubernetes auth | ServiceAccount 기반 워크로드 인증 |
| Database secrets engine | 지원 서비스의 단기 PostgreSQL 자격증명 |
| PKI | 내부 TLS·mTLS 인증서 |
| Audit device | Vault 접근 감사 로그 |
| Raft snapshot | 암호화된 Vault 데이터 복구 |

root token은 초기화와 복구에만 사용한다. GitOps가 Vault의 원문 시크릿을 소유하지 않으며, 애플리케이션별 policy와 auth role을 분리한다.

Keycloak은 cluster-wide injector나 privileged CSI DaemonSet 없이 Pod에 명시한 Vault Agent init
container로 기동 시점 값만 메모리에 렌더링한다. 상시 Keycloak container에는 Kubernetes
ServiceAccount token을 주지 않는다. 상세 선택과 회전 조건은 [ADR-0013](adr/0013-keycloak-secret-consumption.md)이 소유한다.

## 데이터와 백업

같은 물리 노드의 VM·SeaweedFS는 빠른 복구 사본이지 물리 장애 대비 오프사이트 백업이 아니다.

`object-01`은 단일 VM 안에서도 SeaweedFS master, volume server, filer와 S3 gateway를
각각 선언하고 데이터·metadata 경로를 영속화한다. 애플리케이션에는 TLS S3 endpoint만
제공하고 나머지 구성요소·관리 endpoint는 관리 경로로 제한한다. 이 분리는 운영 경계일
뿐 한 물리 노드와 한 디스크 안에서 HA를 만들지는 않는다. 필요한 S3 API는 제품의 호환
표만 믿지 않고 백업 생산자별 실제 복원으로 검증한다.

| 대상 | 백업 방식 | 착지점 |
|---|---|---|
| 선언형 인프라 | Git, OpenTofu, Ansible, GitOps | 원격 Git |
| K3s SQLite·server token | K3s datastore 전용 백업 | SeaweedFS S3 → AWS S3 |
| Kubernetes 리소스·PVC | Velero + node-agent/Kopia | SeaweedFS S3 → AWS S3 |
| PostgreSQL | DB 네이티브 백업과 복구 검증 | SeaweedFS S3 → AWS S3 |
| Vault | Raft snapshot과 구성 백업 | SeaweedFS S3 → AWS S3 |
| 로컬 S3 데이터 | 별도 검증한 방식으로 오프사이트 사본 생성 | AWS S3 |
| NetBird·Warpgate | 제품 DB·구성 백업 | SeaweedFS S3 → AWS S3 |
| VM 전체 | 두 번째 SSD 추가 후 Proxmox backup | 별도 SSD; 앱 백업은 계속 S3 |

Velero는 K3s SQLite를 백업하지 않는다. CSI snapshot을 지원하지 않는 local storage에서는 snapshot 완료를 가정하지 않고 파일 백업과 실제 restore를 검증한다. 로그는 백업 자산이 아니라 보존기간을 가진 운영 데이터로 취급한다.

S3 복구 자격증명, K3s server token과 Shamir share처럼 전체 장애 때 필요한 값은 Vault에만 두지 않는다. 암호화한 break-glass 사본을 클러스터 밖에서 보관해 복구의 순환 의존을 끊는다.

## AWS 연동

- OPNsense와 AWS VPC는 Site-to-Site VPN으로 사설 경로를 만든다.
- S3·STS·KMS의 공인 AWS API endpoint 사용은 금지하지 않는다.
- Keycloak은 AWS 콘솔 임시 권한을 위한 SAML IdP다.
- AWS S3는 온프레미스 장애와 분리된 최종 백업 사본이다.
- AWS KMS auto-unseal은 Day 1 범위가 아니다.

## 의도적으로 유보한 것

| 항목 | 재검토 조건 |
|---|---|
| NetBox | 두 번째 물리 노드, 관리형 스위치, 공통 인벤토리 수요 |
| 관리형 스위치 | Proxmox 외 프로젝트 물리 장비 추가 |
| 두 번째 k3s 노드·Longhorn·Ceph | 서로 다른 물리 장애 도메인 확보 |
| AWS KMS auto-unseal | Vault 백업·복구와 Shamir 운영 검증 완료 |
| Shuffle 자동 대응 | 경보 품질과 수동 incident runbook 검증 완료 |

## 결정 기록

이 문서는 확정한 목표만 유지한다. 선택 이유, 검토한 대안과 재검토 조건은 [ADR 목록](adr/README.md)이 소유하며, 결정이 바뀌면 기존 기록을 덮어쓰지 않고 새 ADR로 대체한다.

## 구현 기준 문서

구현 작업은 시작 시 제품 버전을 고정하고 해당 버전 문서를 다시 확인한다.

- [K3s datastore](https://docs.k3s.io/datastore), [K3s networking services](https://docs.k3s.io/networking/networking-services)
- [Proxmox VE unattended installation과 certificate management](https://pve.proxmox.com/pve-docs/pve-admin-guide.pdf), [Cloudflare API token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
- [Rancher local-path-provisioner](https://github.com/rancher/local-path-provisioner)
- [SeaweedFS](https://github.com/seaweedfs/seaweedfs), [SeaweedFS Amazon S3 API](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)
- [Velero file-system backup](https://velero.io/docs/v1.18/file-system-backup/)
- [Vault seal/unseal](https://developer.hashicorp.com/vault/docs/concepts/seal), [AWS KMS seal](https://developer.hashicorp.com/vault/docs/configuration/seal/awskms)
- [Pomerium Routes Portal](https://www.pomerium.com/docs/capabilities/routes-portal)
- [Headlamp in-cluster](https://headlamp.dev/docs/latest/installation/in-cluster/), [Headlamp OIDC](https://headlamp.dev/docs/latest/installation/in-cluster/oidc/)
- [OPNsense intrusion detection](https://docs.opnsense.org/manual/ips.html), [OPNsense Wazuh Agent](https://docs.opnsense.org/manual/wazuh-agent.html)
- [CrowdSec AppSec](https://docs.crowdsec.net/docs/log_processor/data_sources/appsec/), [Traefik Kubernetes bouncer](https://docs.crowdsec.net/u/bouncers/traefik/), [Traefik plugin install configuration](https://doc.traefik.io/traefik/reference/install-configuration/experimental/plugins/)
- [NetBox source-of-truth model](https://netboxlabs.com/docs/netbox/introduction/)
- [Shuffle self-hosted install](https://github.com/Shuffle/Shuffle/blob/main/.github/install-guide.md)
