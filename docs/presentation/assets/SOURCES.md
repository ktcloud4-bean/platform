# 발표 자산 출처

이 문서는 `docs/presentation/assets/` 아래 자산의 원본 URL, license와 상표 경계를 소유한다.
자산을 추가하면 이 표에 같은 항목을 채운 뒤에 발표물에 쓴다.

## 원칙

- vendor 공식 배포본을 먼저 쓴다. CNCF 프로젝트는 `cncf/artwork`, 그 밖의 self-hosted 제품은
  해당 제품의 공식 저장소를 우선한다.
- 공식 배포본이 없을 때만 Dashboard Icons 모음을 쓰고, 원본 URL과 license를 함께 기록한다.
- AWS 서비스는 파일을 받지 않고 draw.io에 내장된 AWS Architecture Icons shape을 쓴다.
- 어떤 로고도 재도안·색상 변경·비율 왜곡을 하지 않는다. 크기만 조정한다.
- 로고는 해당 제품을 **식별**하는 용도로만 쓴다. 후원·인증·제휴를 뜻하지 않는다.
- 자산을 받은 뒤 실제 파일 형식을 확인한다. SPA로 만든 제품 사이트는 없는 경로에도
  HTTP 200과 HTML을 돌려주므로 상태 코드만으로는 이미지를 받았는지 알 수 없다.
  `file` 결과가 확장자와 맞는지 검사하는 절차는 `docs/presentation/README.md`에 있다.

## 상표 경계

모든 제품명·로고·등록상표는 각 권리자의 자산이다. 이 저장소는 어떤 상표도 소유하지 않으며,
발표에서 다음을 주장하지 않는다.

- 제품 vendor의 후원, 보증, 인증, 제휴 관계
- 제품의 공식 파트너·리셀러·인증 구현체 지위
- 로고를 팀·프로젝트·산출물의 식별자로 삼는 것

CNCF·Linux Foundation 마크는
[Linux Foundation Trademark Usage](https://www.linuxfoundation.org/trademark-usage)와
[cncf/artwork LICENSE.md](https://github.com/cncf/artwork/blob/master/LICENSE.md)를 따른다.
`Certified Kubernetes` 계열 마크는 conformant 구현에만 쓸 수 있으므로 사용하지 않는다.
AWS 상표는 [AWS Trademark Guidelines](https://aws.amazon.com/trademark-guidelines/)를 따르며
AWS 로고 자체는 발표물에 넣지 않고 서비스 아이콘만 쓴다.

## license 요약

| 출처 | 모음 license | 로고 자체의 권리 |
|---|---|---|
| [cncf/artwork](https://github.com/cncf/artwork) | 저장소의 [LICENSE.md](https://github.com/cncf/artwork/blob/master/LICENSE.md) 발췌 + Linux Foundation 상표 정책 | CNCF / 각 프로젝트 |
| 제품 공식 저장소 | 각 저장소의 license (아래 표) | 각 제품 vendor |
| [homarr-labs/dashboard-icons](https://github.com/homarr-labs/dashboard-icons) | Apache-2.0 (모음 자체) | 각 권리자. 저장소 고지: *"All product names, trademarks, and registered trademarks are the property of their respective owners. Icons are used for identification purposes only and do not imply endorsement."* |
| draw.io 내장 AWS Architecture Icons | draw.io 배포본에 포함 | Amazon Web Services, Inc. |

## icons/ — vendor 공식 (CNCF artwork)

받은 시점 기준 `main` 브랜치의 `icon/color` 변형이다.

| 파일 | 제품 | 원본 URL |
|---|---|---|
| `k3s.svg` | K3s | https://raw.githubusercontent.com/cncf/artwork/main/projects/k3s/icon/color/k3s-icon-color.svg |
| `keycloak.svg` | Keycloak | https://raw.githubusercontent.com/cncf/artwork/main/projects/keycloak/icon/color/keycloak-icon-color.svg |
| `cert-manager.svg` | cert-manager | https://raw.githubusercontent.com/cncf/artwork/main/projects/cert-manager/icon/color/cert-manager-icon-color.svg |
| `harbor.svg` | Harbor | https://raw.githubusercontent.com/cncf/artwork/main/projects/harbor/icon/color/harbor-icon-color.svg |
| `kyverno.svg` | Kyverno | https://raw.githubusercontent.com/cncf/artwork/main/projects/kyverno/icon/color/kyverno-icon-color.svg |
| `falco.svg` | Falco | https://raw.githubusercontent.com/cncf/artwork/main/projects/falco/icon/color/falco-icon-color.svg |
| `velero.svg` | Velero | https://raw.githubusercontent.com/cncf/artwork/main/projects/velero/icon/color/velero-icon-color.svg |
| `prometheus.svg` | Prometheus | https://raw.githubusercontent.com/cncf/artwork/main/projects/prometheus/icon/color/prometheus-icon-color.svg |
| `headlamp.svg` | Headlamp | https://raw.githubusercontent.com/cncf/artwork/main/projects/headlamp/icon/color/headlamp-icon-color.svg |
| `kubernetes.svg` | Kubernetes | https://raw.githubusercontent.com/cncf/artwork/main/projects/kubernetes/icon/color/kubernetes-icon-color.svg |
| `argo-cd.svg` | Argo (Argo CD) | https://raw.githubusercontent.com/cncf/artwork/main/projects/argo/icon/color/argo-icon-color.svg |

## icons/ — vendor 공식 (제품 저장소)

| 파일 | 제품 | 원본 URL | 저장소 license |
|---|---|---|---|
| `gitea.svg` | Gitea | https://raw.githubusercontent.com/go-gitea/gitea/main/public/assets/img/logo.svg | MIT |
| `pomerium.svg` | Pomerium | https://raw.githubusercontent.com/pomerium/documentation/main/static/img/logo.svg | Apache-2.0 |
| `seaweedfs.svg` | SeaweedFS | https://raw.githubusercontent.com/seaweedfs/seaweedfs/master/note/seaweedfs.svg | Apache-2.0 |
| `trivy.png` | Trivy (Aqua Security) | https://raw.githubusercontent.com/aquasecurity/trivy/main/docs/imgs/logo.png | Apache-2.0 |
| `dashy.png` | Dashy | https://raw.githubusercontent.com/Lissy93/dashy/master/docs/assets/logo.png | MIT |
| `shuffle.png` | Shuffle | https://raw.githubusercontent.com/Shuffle/Shuffle/main/frontend/src/assets/img/logo.png | AGPL-3.0 |

## icons/ — Dashboard Icons

모두 `https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/<이름>.svg` 에서 받았다.
모음 license는 Apache-2.0이고 로고 권리는 각 권리자에게 있다.

| 파일 | 제품 | 권리자 |
|---|---|---|
| `opnsense.svg` | OPNsense | Deciso B.V. |
| `proxmox.svg` | Proxmox VE | Proxmox Server Solutions GmbH |
| `traefik.svg` | Traefik | Traefik Labs |
| `crowdsec.svg` | CrowdSec | CrowdSec SAS |
| `vault.svg` | HashiCorp Vault | HashiCorp (IBM) |
| `jenkins.svg` | Jenkins | Software in the Public Interest / Jenkins project |
| `sonarqube.svg` | SonarQube | Sonar (SonarSource SA) |
| `wazuh.svg` | Wazuh | Wazuh Inc. |
| `loki.svg` | Grafana Loki | Grafana Labs |
| `grafana.svg` | Grafana | Grafana Labs |
| `awx.svg` | AWX | Red Hat, Inc. |
| `renovate.svg` | Renovate | Mend.io |
| `netbird.svg` | NetBird | NetBird GmbH |
| `warpgate.svg` | Warpgate | Warp Tech |
| `postgresql.svg` | PostgreSQL | PostgreSQL Community Association |
| `github.svg` | GitHub | GitHub, Inc. (Microsoft) |
| `cloudflare.svg` | Cloudflare | Cloudflare, Inc. |
| `cosign.svg` | Cosign (Sigstore) | Sigstore / OpenSSF |

`proxmox.svg`는 색 정보 없는 단색 실루엣이다. 발표에서 어두운 배경에 쓸 때는
채우기 색만 배경 대비에 맞춰 바꾸고 형태는 그대로 둔다.

## 아이콘 없이 표기하는 구성요소

| 구성요소 | 이유 | 표기 방법 |
|---|---|---|
| Suricata | OISF가 공개 배포하는 벡터 로고를 확인하지 못했다 | 다이어그램에서 `IDS` 표식과 제품명 텍스트로만 표기 |

## AWS 서비스 아이콘

파일로 받지 않고 draw.io 내장 `mxgraph.aws4` shape을 쓴다. 발표 PPTX에서 같은 아이콘이 필요하면
[AWS Architecture Icons](https://aws.amazon.com/architecture/icons/) 공식 배포본을 내려받아
`assets/icons/aws/`에 두고 이 문서에 항목을 추가한다.

| 다이어그램 요소 | draw.io shape |
|---|---|
| Site-to-Site VPN | `mxgraph.aws4.site_to_site_vpn` |
| Elastic Load Balancing (internal ALB) | `mxgraph.aws4.elastic_load_balancing` |
| Amazon Aurora | `mxgraph.aws4.aurora` |
| Amazon ECR | `mxgraph.aws4.ecr` |
| AWS Secrets Manager | `mxgraph.aws4.secrets_manager` |
| AWS IAM (IRSA) | `mxgraph.aws4.identity_and_access_management` |
| AWS KMS | `mxgraph.aws4.key_management_service` |
| Amazon S3 | `mxgraph.aws4.s3` |

EKS는 Pod 아이콘 대신 Kubernetes 로고와 `Amazon EKS · private endpoint` 컨테이너 제목으로 표기한다.

## generated/ — 생성 이미지

`PRESENT-VISUAL-01`이 소유한다. 생성 이미지를 넣을 때 prompt, 생성 도구, 생성 시점과
사람이 보정한 범위를 이 문서에 함께 기록한다.

## evidence/ — 실제 UI 증거

`PRESENT-EVIDENCE-01`이 소유한다. 화면별 캡처 범위, 캡처 시점, 마스킹한 항목과 판정 문구를
이 문서에 함께 기록한다. 계정·email·내부 URL/IP·token·cookie·OTP·Secret·고객 데이터 원문은
캡처에 남기지 않는다.
