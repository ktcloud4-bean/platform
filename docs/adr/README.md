# 아키텍처 결정 기록

ADR(Architecture Decision Record)은 목표 구조를 선택한 이유, 검토한 대안과 재검토 조건을 보존한다. 최종 구조는 [`architecture.md`](../architecture.md), 작업 상태와 의존성은 [`backlog.md`](../backlog.md), 주소는 [`ip-plan.md`](../ip-plan.md)가 계속 소유한다.

## 기록 원칙

- 확정한 결정만 `Accepted`로 기록한다. 미결정 항목은 백로그의 `DEFERRED`와 재검토 조건으로 남긴다.
- 주소, 제품 버전, 명령, 비밀과 라이브 상태를 ADR에 복제하지 않는다.
- 구현이 바뀌어도 과거 ADR을 소급 수정하지 않는다. 새 ADR이 기존 ADR을 `Superseded`로 대체한다.
- 백로그 작업자는 작업 범위에 연결된 ADR을 읽고, 라이브 전제가 다르면 적용하지 않고 보고한다.
- 한 ADR은 하나의 결정을 다루고 1페이지 안팎으로 유지한다.

## 목록

| ID | 결정 | 상태 | 주요 재검토 조건 |
|---|---|---|---|
| [ADR-0001](0001-proxmox-bootstrap-reproducibility.md) | Proxmox 수동 기준 설치 후 자동설치 PoC | `Accepted` | 동일 사양 테스트 장비·두 번째 물리 노드 확보 |
| [ADR-0002](0002-single-node-k3s-and-local-storage.md) | 단일 k3s와 local storage | `Accepted` | 서로 다른 물리 장애 도메인 확보 |
| [ADR-0003](0003-service-vm-boundaries.md) | 서비스 VM 경계 | `Accepted` | 물리 노드·전용 NAS·제품 요구사항 변화 |
| [ADR-0004](0004-zero-trust-identity-and-management-access.md) | 통합인증과 관리 접근 | `Accepted` | 관리 클러스터 증가·운영자 역할 확대 |
| [ADR-0005](0005-backup-and-offsite-recovery.md) | 계층별 백업과 S3 오프사이트 | `Accepted` | 외부 NAS·PBS·두 번째 물리 사이트 확보 |
| [ADR-0006](0006-vault-seal-and-bootstrap-boundary.md) | Vault Shamir Day 1과 bootstrap 경계 | `Superseded` | ADR-0015에서 AWS KMS로 전환 |
| [ADR-0007](0007-detection-and-observability-staging.md) | 탐지·관측의 역할과 배포 순서 | `Accepted` | 자원 gate 통과·경보 품질과 대응 절차 검증 |
| [ADR-0008](0008-opentofu-provider-and-state-boundary.md) | OpenTofu provider와 state 경계 | `Accepted` | 원격 state 착지점 확보·provider 1.0·NetBox 전환 |
| [ADR-0009](0009-proxmox-native-acme-management-tls.md) | Proxmox 네이티브 ACME DNS-01 관리 TLS | `Accepted` | CT 비공개 요구·사설 CA trust 자동화·다중 cluster |
| [ADR-0010](0010-seaweedfs-local-s3.md) | 로컬 S3 구현을 SeaweedFS로 전환 | `Accepted` | 클라이언트 호환 실패·독립 storage 확보·유지 상태 변화 |
| [ADR-0011](0011-aws-site-to-site-vpn-boundary.md) | AWS 사설 연동을 policy-based Site-to-Site VPN으로 구현 | `Accepted` | VPC·사이트 증가·터널 이중화 요구·WAN 주소 정책 변화 |
| [ADR-0012](0012-crowdsec-appsec-origin-waf.md) | 오리진 WAF를 CrowdSec AppSec 경로로 전환 | `Accepted` | bouncer 유지 중단·Traefik plugin 정책 변화·격리 PoC 실패 |
| [ADR-0013](0013-keycloak-secret-consumption.md) | Keycloak 시크릿을 명시적 Vault Agent init으로 소비 | `Accepted` | 소비 앱 증가·무중단 DB 자격증명 회전 |
| [ADR-0014](0014-dashy-access-portal.md) | 애플리케이션 포털을 Dashy로 분리 | `Accepted` | groups/OIDC 지원 중단·동적 카탈로그 요구 |
| [ADR-0015](0015-vault-aws-kms-auto-unseal.md) | Vault seal을 AWS KMS auto-unseal로 전환 | `Accepted` | access key·KMS 장애시간·replica 증가 |
| [ADR-0016](0016-cert-manager-vault-pki-lifecycle.md) | Kubernetes 내부 인증서 lifecycle을 cert-manager와 Vault PKI로 분리 | `Accepted` | Secret key 금지·다중 cluster·제품 지원 변화 |
| [ADR-0017](0017-team-identity-and-shuffle-rbac.md) | 팀 신원 이름과 Shuffle 권한 수명주기 | `Accepted` | GitHub lifecycle 연동·다중 조직·privileged access governance |
| [ADR-0018](0018-public-keycloak-frontchannel.md) | 외부 OIDC 온보딩용 Keycloak 사용자 프런트엔드 공개 | `Accepted` | 외부 IdP·Cloudflare origin 기능 변화·clientless Portal 요구 |
| [ADR-0019](0019-private-aws-service-egress.md) | 애플리케이션 AWS egress를 service endpoint로 제한 | `Accepted` | EKS endpoint 방식·추가 AWS API·egress proxy·공유 VPC |
| [ADR-0020](0020-aws-opentofu-state-recovery-backend.md) | AWS legacy OpenTofu state를 분리 S3 backend로 복구 | `Accepted` | state 접근 경계·Jenkins 실행 범위·provider import 지원·AWS 토폴로지 |
| [ADR-0021](0021-aws-hr-aurora-serverless.md) | HR DB를 Aurora PostgreSQL Serverless v2로 선택 | `Accepted` | HR 부하·credit/비용·HA/reader 요구·Aurora 제약 변화 |
| [ADR-0022](0022-aws-hr-shared-vpc-gitops.md) | HR EKS를 기존 AWS shared VPC와 기존 k3s Argo CD에 통합 | `Accepted` | VPC 분리·라우팅 허브·독립 EKS GitOps control plane 요구 |
| [ADR-0023](0023-aws-shared-vpn-service-boundary.md) | AWS shared VPN을 단일 selector로 통합하고 service rule로 제한 | `Accepted` | VPC·site·tenant 분리 또는 dual tunnel 요구 |
| [ADR-0024](0024-warpgate-native-postgresql-sessions.md) | PostgreSQL 운영 세션을 Warpgate native TLS relay로 중계 | `Accepted` | DB 운영 권한·JIT credential·다중 cluster 요구 |
| [ADR-0025](0025-alertmanager-slack-egress-identity.md) | Alertmanager Slack egress를 전용 source identity와 CONNECT allowlist로 분리 | `Accepted` | 다중 node·Slack hostname·egress gateway 변화 |
| [ADR-0026](0026-aws-security-control-boundary.md) | AWS 보안 통제를 계정 기준선과 앱 보안 root로 분리 | `Accepted` | 계정·리전 구조, egress, 보존, 승인 경계 변화 |
| [ADR-0027](0027-container-registry-hub-and-replica.md) | Harbor를 단일 허브로, ECR을 EKS 전용 복제본으로 분리 | `Accepted` | 고대역폭 전용선 도입·OCI 복제 표준 변화·EKS 완전 온프레미스 통합 |

## 형식

새 ADR은 `배경`, `결정`, `검토한 대안`, `결과`, `재검토 조건`을 포함한다. 관련 백로그 ID는 탐색을 돕는 참조일 뿐 상태를 소유하지 않는다.
