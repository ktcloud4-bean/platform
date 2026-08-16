# 발표 산출물

`온프레미스–AWS 하이브리드 보안 플랫폼` 발표(22장·본문 약 14분 5초)의 산출물과 근거를 소유한다.
발표 구성·시간·순서 계약은 [`docs/backlog.md`](../backlog.md)의 `13. 발표 아키텍처·슬라이드·대본`이
소유하고, 아키텍처 사실은 [`docs/architecture.md`](../architecture.md)와 Git 선언이 소유한다.
이 문서는 둘 사이의 대조 결과만 기록한다.

## 산출물

| 경로 | 내용 | 소유 작업 |
|---|---|---|
| `architecture/platform-architecture.drawio` | 한 페이지 16:9 논리 아키텍처 원본 | `PRESENT-ARCH-01` |
| `architecture/platform-architecture.svg` | 위 원본을 embed한 SVG | `PRESENT-ARCH-01` |
| `architecture/platform-architecture.drawio.png` | 위 원본을 embed한 PNG | `PRESENT-ARCH-01` |
| `assets/icons/` | vendor 공식 아이콘 원본 | `PRESENT-ARCH-01` |
| `assets/SOURCES.md` | 자산 출처·license·상표 경계 | `PRESENT-ARCH-01` |
| `assets/generated/` | 발표용 생성 이미지 | `PRESENT-VISUAL-01` |
| `assets/evidence/` | 마스킹한 실제 UI 증거 | `PRESENT-EVIDENCE-01` |
| `ktcloud4-bean.pptx` | 22장 발표자료 | `PRESENT-DECK-SKELETON-01` → `PRESENT-DECK-01` |
| `presentation-script.md` | 페이지별 발표 대본 | `PRESENT-SCRIPT-01` |

## 아키텍처 그림의 계약

- **용도**: `PRESENT-VISUAL-01`의 생성 이미지와 `PRESENT-DECK-01`의 슬라이드가 구조·경계·흐름에서
  벗어나지 않았는지 판정하는 기준이다. 이 `.drawio` 자체는 PPT에 넣지 않는다.
- **넣는 것**: 실행 단위와 경계, 접근·공급망·탐지/사람 승인·복구 네 흐름, 허용한 SPOF.
- **넣지 않는 것**: Pod, IP·CIDR, port, 도메인, 계정, 미적용 계획 상태, 검증하지 않은 주장.
- **균형**: 온프레미스 플랫폼이 중심이고 AWS는 HR 대표 워크로드와 오프사이트 착지점이다.
  HR System은 AWS 영역에서 식별되지만 그림 전체를 독점하지 않는다.

## source matrix — 구성요소

그림에 그린 요소마다 Git 선언 위치와 백로그 완료 근거를 짝지었다. 근거 작업은 모두 `DONE`이다.
표에 없는 요소는 그림에 없다.

### 외부 · 경계

| 그림의 요소 | Git 선언 | 근거 작업 |
|---|---|---|
| 팀 사용자·장치 (Keycloak 일상 ID·MFA) | `gitops/apps/keycloak-bootstrap/` | `IAM-01`, `IAM-ENROLL-01`, `IAM-MIG-01`, `NB-ENROLL-01` |
| Cloudflare WAF (sso 프런트엔드만 공개) | `infra/opnsense/config.xml`, `docs/adr/0018-public-keycloak-frontchannel.md` | `EDGE-DESIGN-02`, `EDGE-02` |
| GitHub (`hr-system` source 단일 원본) | `gitops/tools/aws-hr-01/`, `docs/adr/0029-hr-system-testing-and-sonarqube-release-gate.md` | `SCM-01`, `AWS-HR-01`, `UPDATE-02` |
| NetBird (원격 접근 overlay) | `infra/ansible/roles/netbird_server/`, `docs/runbook/netbird-enrollment.md` | `NB-01`, `NB-02`, `NB-ENROLL-01` |
| OPNsense (방화벽·NAT·VLAN·Unbound DNS) | `infra/opnsense/` | `NET-02`, `NET-03`, `DNS-01`, `EDGE-01` |
| Suricata IDS (alert-only) | `infra/opnsense/config.xml` | `NIDS-01` |

### 가상화 · 실행 단위

| 그림의 요소 | Git 선언 | 근거 작업 |
|---|---|---|
| Proxmox VE (단일 물리 노드) | `infra/proxmox/tofu/` | `PVE-01`, `IAC-01`, `PVE-ACME-01` |
| k3s-01 (단일 server 노드) | `infra/ansible/roles/k3s_baseline/` | `K3S-01` |
| netbird-01 | `infra/ansible/roles/netbird_server/` | `NB-01`, `NB-02` |
| warpgate-01 | `infra/ansible/roles/warpgate_baseline/` | `WG-01`, `WG-03`, `WG-04` |
| postgres-01 | `infra/ansible/roles/postgres_baseline/` | `PG-01` |
| object-01 (SeaweedFS S3) | `infra/ansible/roles/seaweedfs_s3/` | `S3-DESIGN-01`, `S3-01`, `S3-02` |

### k3s — 접근 · 인증

| 그림의 요소 | Git 선언 | 근거 작업 |
|---|---|---|
| Traefik | `gitops/apps/ingress/` | `K3S-01`, `INGRESS-01` |
| Pomerium Core | `gitops/apps/pomerium/` | `POM-01` |
| Keycloak | `gitops/apps/keycloak/`, `gitops/apps/keycloak-bootstrap/` | `KC-01`, `IAM-01` |
| CrowdSec AppSec | `gitops/apps/crowdsec/`, `docs/adr/0012-crowdsec-appsec-origin-waf.md` | `WAF-DESIGN-01`, `CROWDSEC-PERF-01` |
| Dashy | `gitops/apps/pomerium/dashy-*` | `POM-01`, `AWS-HR-02` |
| Headlamp | `gitops/apps/headlamp/` | `HEADLAMP-01`, `HEADLAMP-02` |

### k3s — 공급망 · 배포

| 그림의 요소 | Git 선언 | 근거 작업 |
|---|---|---|
| Gitea | `gitops/apps/gitea/` | `SCM-01`, `SCM-02` |
| Jenkins | `gitops/apps/jenkins/` | `CI-01`, `CI-01-FIX-01` |
| SonarQube | `gitops/apps/sonarqube/` | `QUALITY-01`, `QUALITY-02`, `QUALITY-03` |
| Trivy | `gitops/apps/jenkins/` (pipeline gate) | `SCAN-01` |
| Cosign | `gitops/apps/jenkins/` (pipeline gate) | `SIGN-01`, `SUPPLY-04` |
| Harbor | `gitops/apps/harbor/`, `docs/adr/0028-container-supply-chain-promotion.md` | `REG-01`, `SUPPLY-DESIGN-01`, `SUPPLY-04`, `SUPPLY-06` |
| Argo CD | `gitops/bootstrap/`, `gitops/root/` | `GITOPS-01`, `GITOPS-02` |
| Kyverno (k3s admission) | `gitops/apps/kyverno/`, `policies/` | `POL-01`, `POL-02`, `SUPPLY-02`, `POL-03` |

### k3s — 탐지 · 대응

| 그림의 요소 | Git 선언 | 근거 작업 |
|---|---|---|
| Wazuh | `gitops/apps/wazuh/` | `WAZUH-01` ~ `WAZUH-06` |
| Shuffle (사람 승인) | `gitops/apps/shuffle/`, `docs/adr/0017-team-identity-and-shuffle-rbac.md` | `SOAR-DASH-01`, `SOAR-01` |
| Falco | `gitops/apps/falco/` | `FALCO-01` |
| Suricata (OPNsense) | `infra/opnsense/config.xml` | `NIDS-01`, `AUDIT-01` |

### k3s — 시크릿 · 인증서 · 백업 · 자동화

| 그림의 요소 | Git 선언 | 근거 작업 |
|---|---|---|
| Vault | `gitops/apps/vault/`, `infra/vault/`, `docs/adr/0006-vault-seal-and-bootstrap-boundary.md` | `VAULT-01`, `VAULT-02`, `VAULT-03`, `KMS-01` |
| cert-manager | `gitops/apps/cert-manager/`, `docs/adr/0016-cert-manager-vault-pki-lifecycle.md` | `CERTMGR-01`, `PKI-01` |
| Velero | `gitops/apps/velero/` | `BKP-01`, `BKP-02`, `BKP-07` |
| AWX | `gitops/apps/awx/` | `AWX-01` ~ `AWX-07` |
| Renovate | `gitops/apps/renovate/` | `UPDATE-01`, `UPDATE-02` |

### k3s — 관측

| 그림의 요소 | Git 선언 | 근거 작업 |
|---|---|---|
| Prometheus | `gitops/apps/obs/` | `OBS-01`, `OBS-09`, `OBS-20` |
| Grafana | `gitops/apps/obs/` | `OBS-01`, `OBS-02` |
| Loki | `gitops/apps/loki/` | `LOKI-01`, `LOKI-02` |

### AWS

| 그림의 요소 | Git 선언 | 근거 작업 |
|---|---|---|
| Site-to-Site VPN | `infra/aws/tofu-app-vpn/`, `infra/opnsense/` | `AWS-NET-01` |
| VPC · private subnet (IGW·NAT 없음) | `infra/aws/tofu-app-network/` | `AWS-HR-01` |
| internal ALB | `gitops/apps/hr-system/ingress.yaml`, `infra/aws/tofu-app-eks/iam_alb_controller.tf` | `AWS-HR-01` |
| Amazon EKS (private endpoint) | `infra/aws/tofu-app-eks/eks.tf` | `AWS-HR-01` |
| `frontend` | `gitops/apps/hr-system/deployments.yaml` | `AWS-HR-01`, `QUALITY-04` |
| `employee-service` | `gitops/apps/hr-system/deployments.yaml` | `AWS-HR-01`, `QUALITY-04`, `QUALITY-06` |
| `hr-service` | `gitops/apps/hr-system/deployments.yaml` | `AWS-HR-01`, `QUALITY-04`, `QUALITY-06` |
| Kyverno (EKS admission) | `gitops/apps/kyverno-eks/` | `SUPPLY-01`, `SUPPLY-01-FIX-01`, `SUPPLY-01-FIX-02` |
| Aurora PostgreSQL | `infra/aws/tofu-app-db/rds.tf` | `AWS-HR-01`, `AWS-DB-SEC-01` |
| Amazon ECR | `infra/aws/tofu-app-ecr/` | `SUPPLY-06`, `SUPPLY-07`, `SUPPLY-08` |
| AWS Secrets Manager | `infra/aws/tofu-app-db/`, `gitops/apps/hr-system/deployments.yaml` | `AWS-HR-01` |
| IAM · IRSA | `infra/aws/tofu-app-eks/iam_hr_services.tf`, `gitops/apps/hr-system/serviceaccounts.yaml` | `AWS-HR-01` |
| AWS KMS | `infra/aws/tofu-kms/` | `KMS-01` |
| Amazon S3 (오프사이트) | `infra/aws/tofu/s3.tf`, `infra/ansible/roles/seaweedfs_offsite_backup/` | `BKP-04`, `BKP-09` |

## source matrix — 흐름

| 흐름 | 그림이 주장하는 것 | 근거 작업 |
|---|---|---|
| 접근 | 사용자 → NetBird overlay(sso 인증면만 Cloudflare) → OPNsense → Traefik → Pomerium → 내부 서비스 | `EDGE-01`, `EDGE-02`, `NB-ENROLL-01`, `POM-01` |
| 접근 (HR) | Pomerium → S2S VPN → internal ALB → 세 서비스 → Aurora | `AWS-NET-01`, `AWS-HR-01`, `AWS-HR-02` |
| 공급망 | GitHub → Gitea → Jenkins(test·SonarQube·Trivy·Cosign) → Harbor 승격 | `SCM-01`, `CI-01`, `QUALITY-03`, `QUALITY-05`, `SCAN-01`, `SIGN-01`, `SUPPLY-04` |
| 공급망 (EKS) | Harbor → ECR scheduled replication → Argo CD digest 선언 → Kyverno admission | `SUPPLY-06`, `SUPPLY-07`, `SUPPLY-01-FIX-02` |
| 공급망 (권한) | IRSA·Secrets Manager가 EKS 워크로드의 AWS 권한과 DB credential을 결정 | `AWS-HR-01` |
| 탐지·대응 | Suricata·CrowdSec·Falco·audit event → Wazuh → Shuffle 보강 → 사람 승인 | `NIDS-01`, `FALCO-01`, `AUDIT-01`, `WAZUH-01`, `SOAR-01` |
| 백업·복구 | Velero·PostgreSQL·Vault snapshot → SeaweedFS S3 → AWS S3 | `BKP-07`, `BKP-09`, `BKP-11`, `BKP-12`, `DEMO-RECOVERY-01` |
| 백업·복구 (seal) | Vault ↔ AWS KMS auto-unseal, Shamir 복귀 경로 보존 | `KMS-01` |
| 독립 복구 | NetBird direct peer → Warpgate 특권 세션 | `WG-03`, `WG-04`, `NB-ENROLL-01` |

## Git 선언 대조 결과

### `architecture.md`의 stale `Board Demo` 행

`docs/architecture.md`의 서비스 배치 표에 아직 남아 있는

> `| 내부 데모 애플리케이션 | Board Demo | k3s; Pomerium 뒤, PostgreSQL TLS·Vault runtime 분리 |`

행은 현재 선언·백로그와 맞지 않는다.

- `BOARD-DEMO-02 DONE`이 `gitops/apps/board-demo`, root Application/AppProject, Pomerium route,
  Jenkins job·credential, Vault KV·policy, Harbor project, OPNsense alias를 모두 제거했다.
  현재 저장소에 `board-demo` 선언은 없다.
- `AWS-HR-02 DONE`이 Dashy의 Board Demo 타일을 HR 포털 타일로 교체해 `Board Demo 타일 0건`을 확인했다.

따라서 이 그림에 Board Demo를 넣지 않았고, 내부 데모 애플리케이션 자리는 AWS 대표 워크로드인
HR System이 대신한다. `architecture.md`의 해당 행 삭제는 이 작업의 소유 범위 밖이므로
별도 보정 작업이 필요하다.

### 그림에 넣지 않은 선언

선언은 있지만 한 페이지 논리 아키텍처의 목적에 맞지 않아 제외했다. 누락이 아니라 제외다.

| 선언 | 제외 이유 |
|---|---|
| `gitops/apps/demo-onprem/` | 촬영용 합성 fixture다. 상시 플랫폼 구성요소가 아니라 `DEMO-ONPREM-01`의 데모 하네스다 |
| `gitops/apps/e2e-01/` | 배포 검증용 합성 E2E 워크로드다. 사용자 경로가 아니다 |
| `gitops/apps/coredns/`, `gitops/apps/hr-system-bootstrap/`, `gitops/root/aws-load-balancer-controller-*` | 플랫폼 내부 부속이다. 그림의 흐름 네 개를 설명하는 데 필요하지 않다 |
| `gitops/tools/*` | 일회성 검증 도구다 |
| Suricata IPS 승격, Shuffle 자동 대응, 두 번째 k3s 노드, NetBox, 관리형 스위치 | `architecture.md`가 의도적으로 유보한 항목이다. 미적용 계획은 그리지 않는다 |
| Cloudflare 뒤 `access` Portal·관리 realm | 공개하지 않은 경로다. 그리면 공개 진입면을 잘못 읽게 된다 |

### 그림이 단순화한 것

| 선언 | 그림의 표현 |
|---|---|
| Wazuh manager·indexer·dashboard 구성요소 | `Wazuh` 한 요소 |
| kube-prometheus-stack(Prometheus·Alertmanager·Grafana) | `Prometheus`와 `Grafana` 두 요소 |
| Harbor curated·proxy cache project 구분 | `Harbor` 한 요소. proxy cache는 승격 원본이 아니므로 흐름에 넣지 않았다 |
| Keycloak 프로젝트 realm과 관리 realm 분리 | `Keycloak` 한 요소 |
| Jenkins의 test·coverage·quality gate 단계 | `Jenkins 품질 · 공급망 gate` 묶음 |

## 재생성과 검증

그림은 draw.io 데스크톱으로 직접 편집해도 되고, `.drawio`를 열어 수정한 뒤 아래 절차로
내보내기만 다시 해도 된다.

```bash
# 아이콘 형식 검사 — 확장자와 실제 형식이 어긋난 파일이 있으면 안 된다.
# 제품 사이트가 SPA면 없는 경로에도 HTTP 200과 HTML을 돌려주므로 상태 코드만으로는
# 이미지를 받았는지 알 수 없다. 받은 파일은 반드시 형식을 확인한다.
for f in docs/presentation/assets/icons/*; do
  case "$f" in
    *.svg) file -b "$f" | grep -qiE 'svg|xml'  || echo "형식 불일치: $f" ;;
    *.png) file -b "$f" | grep -qi  'PNG image' || echo "형식 불일치: $f" ;;
  esac
done

# 구조 lint — 오류 0건이어야 한다
python3 .claude/skills/drawio-skill/scripts/validate.py \
  docs/presentation/architecture/platform-architecture.drawio --score

# 육안 검토용 preview (embed 없이)
drawio -x -f png --width 2400 -o /tmp/preview.png \
  docs/presentation/architecture/platform-architecture.drawio --no-sandbox

# 최종 산출물 (embed 포함)
drawio -x -f svg -e -o docs/presentation/architecture/platform-architecture.svg \
  docs/presentation/architecture/platform-architecture.drawio --no-sandbox
drawio -x -f png -e -s 2 -o docs/presentation/architecture/platform-architecture.drawio.png \
  docs/presentation/architecture/platform-architecture.drawio --no-sandbox
python3 .claude/skills/drawio-skill/scripts/repair_png.py \
  docs/presentation/architecture/platform-architecture.drawio.png
```

`PRESENT-ARCH-01`에서 확인한 결과는 다음과 같다.

| 검증 | 결과 |
|---|---|
| 아이콘 형식 일치 | 35종 모두 확장자와 실제 형식 일치 |
| `validate.py` 구조 오류 | 0건 (경고 40건은 컨테이너·배경을 통과하는 흐름선과 의도한 겹침) |
| preview PNG 육안 검토 | 잘림·겹침·저대비 0건 |
| `.svg` embed | `content` 속성에 `mxfile` 존재 |
| `.drawio.png` embed·IEND | embed 청크 존재, IEND 정상 종료 |
| 두 산출물 재열기 | draw.io CLI가 다시 읽어 PNG로 내보내기 성공 |
| source matrix 누락 | 0건 (그림의 모든 요소가 위 표에 있다) |
| Secret·실데이터 | 0건 (IP·계정 ID·ARN·도메인·port·key 패턴 스캔) |

## 22장 와이어프레임 (`ktcloud4-bean.pptx`)

`PRESENT-DECK-SKELETON-01`이 소유한다. 실제 제목·핵심 메시지·시간과 자산 계약만 들어 있고
최종 기술 내용·생성 이미지·실제 UI는 아직 없다.

### 템플릿에서 가져온 디자인 자산

사용자가 제공한 15장 원본 템플릿(Git에 복제하지 않는 참고 입력)에서 아래 값을 뽑아 재현했다.
원본 슬라이드는 해커톤 주제의 사진 자산 중심이라 그대로 복제하지 않고, 색·모티프·타이포 규칙만 옮겼다.

| 자산 | 값 |
|---|---|
| 캔버스 | 26.667in × 15.000in (16:9) |
| 검정 · 흰색 | `000000` · `FFFFFF` |
| neon green | `15E954` |
| 카드 회색 | `F6F6F6` · `EEEEEE` |
| 보조 텍스트 | `666666` |
| 폰트 | Pretendard (Bold / Regular) |
| 모티프 | 검정 헤더 바, 각진 사각형, 좌상단 green 블록, 우측 화살표 반복 |

**폰트 의존성**: 원본 템플릿과 같은 Pretendard를 지정했다. 이 저장소의 렌더 환경에는 Pretendard가
없어 QA 렌더는 Noto Sans CJK KR로 대체되므로, 최종 슬라이드는 Pretendard가 설치된 PowerPoint에서
한 번 더 확인한다.

### layout 8종

| layout | 쓰는 슬라이드 |
|---|---|
| `COVER` 표지 | 1 |
| `AGENDA` 목차 | 2 |
| `BODY` 기본 본문 | 3, 4, 5, 6, 12, 13, 14, 15, 20 |
| `FULL-IMAGE` 전체 이미지 + 강조 레이어 | 8, 9, 10, 11 |
| `EVIDENCE-2` 두 화면 증거 | 16, 17 |
| `MATRIX` 결과 매트릭스 | 7, 18 |
| `SWOT` 2×2 | 19 |
| `CLOSE` Q&A · Thank You | 21, 22 |

8~11장은 이미지 placeholder를 `x=1.00, y=2.90, w=24.67, h=10.60`으로 고정하고 강조 레이어만 바꾼다.
승인 이미지가 나오면 네 장 모두 같은 좌표에 배치한다.

### 시간 배분

본문 845초(14분 5초). Q&A와 데모 영상 재생 시간은 포함하지 않는다.

| 장 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 초 | 15 | 20 | 35 | 45 | 30 | 35 | 55 | 40 | 50 | 55 | 50 |

| 장 | 12 | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21 | 22 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 초 | 50 | 55 | 45 | 45 | 50 | 50 | 50 | 35 | 30 | Q&A | 5 |

### 슬라이드마다 채워야 할 계약

각 장에 `PURPOSE`·`MESSAGE`·`ASSET`·`EVIDENCE` 네 칸이 있고 같은 내용이 speaker notes에도 있다.
`PRESENT-DECK-01`은 이 계약을 지우지 않고 그 자리에 최종 내용을 채운다.

### 재생성과 검증

```bash
# 생성 스크립트는 세션 작업물이므로 저장소에 두지 않는다.
# 편집은 PowerPoint에서 직접 하고, 아래 검증만 다시 돌린다.

python3 .claude/skills/pptx/scripts/office/validate.py docs/presentation/ktcloud4-bean.pptx
markitdown docs/presentation/ktcloud4-bean.pptx | \
  grep -iE "\bx{3,}\b|lorem|ipsum|\bTODO|\[insert"        # 잔여 placeholder 0건
python3 .claude/skills/pptx/scripts/office/soffice.py --headless --convert-to pdf \
  docs/presentation/ktcloud4-bean.pptx
pdftoppm -jpeg -r 80 ktcloud4-bean.pdf slide                # 22장 육안 검토
```

`PRESENT-DECK-SKELETON-01`에서 확인한 결과는 다음과 같다.

| 검증 | 결과 |
|---|---|
| Office validator | `All validations PASSED` |
| `markitdown` 장수·순서 | 22장, 확정 22장 순서와 일치 |
| 잔여 placeholder | 0건 (Lorem Ipsum·xxx·TODO·[insert] 검사) |
| PowerPoint timing·transition | 각 0건 |
| speaker notes | 22장 전부 |
| 8~11장 이미지 좌표 | 네 장 동일 (`914400, 2651760, 22555505, 9692640` EMU) |
| 시간 합계 | 845초 = 14분 5초 |
| LibreOffice/PDF 22장 육안 검토 | 잘림·겹침·저대비 0건 |
| 최종 기술 내용·생성 이미지·실제 UI | 0건 (계약과 placeholder만) |

Office validator는 `--original` 없이 돌렸다. 이 PPTX는 템플릿 파일에서 파생한 것이 아니라
템플릿의 색·모티프·타이포 규칙만 재현해 새로 생성했으므로 baseline으로 삼을 원본이 없다.

## 후속 작업 경계

- `PRESENT-DECK-SKELETON-01`은 이 그림을 슬라이드에 넣지 않는다. 22장 layout과 자산 placeholder만 만든다.
- `PRESENT-VISUAL-01`은 이 그림을 생성 이미지 prompt의 구조 기준으로 쓰고, 결과 이미지가
  경계·흐름·SPOF 표기에서 벗어나면 수정 prompt를 만든다.
- `PRESENT-DECK-01`은 승인된 생성 이미지 한 장을 8~11장에 같은 좌표로 배치하고, 공식 아이콘이
  필요하면 `assets/icons/`의 원본을 쓴다.
