# ADR-0027: 컨테이너 레지스트리 허브와 복제 경계

- 상태: `Superseded` ([ADR-0028](0028-container-supply-chain-promotion.md))
- 날짜: 2026-08-14
- 관련 작업: `SUPPLY-DESIGN-01`, `SUPPLY-01`~`08`, `REG-01`, `AWS-HR-01`

## 배경

플랫폼은 온프레미스 k3s에 Harbor(`REG-01`), AWS EKS에 HR 워크로드와 ECR(`AWS-HR-01`)을
각각 운영하고 있다. 현재 구조에서는 Jenkins가 AWS ECR publisher 정적 IAM Access Key를
직접 소유한 채 ECR로 이미지를 푸시하고, k3s 내 160개 이미지 참조 중 119건만 digest가
고정되어 있으며 41건은 upstream 레지스트리를 직접 참조하는 digest 미고정 상태다.

이로 인해 클라우드 장기 자격증명이 CI 파이프라인에 분산되고, 온프레미스와 클라우드 간
이미지 취약점 스캔·Cosign 서명·SBOM 거버넌스가 파편화되어 단일 통제 지점(Single Point of
Control)이 부재하다.

## 결정

Harbor를 자체 빌드 이미지, upstream proxy cache, 복제 원본의 유일한 단일 통제 지점으로
정의하고, AWS ECR은 EKS 전용 다운스트림 복제본(Downstream Replica)으로 한정한다.

```text
[ Developer / Git ]
         │
         ▼
    [ Jenkins ] ──(build & push)──► [ Harbor (Hub) ] ──(Cosign sign / Trivy scan)
                                           │
                    ┌──────────────────────┴──────────────────────┐
                    ▼                                             ▼
        [ k3s Workloads ]                               [ Harbor ECR Adapter ]
    (Pull via Harbor Proxy Cache)                         (Async Replication)
                                                                  │ (S2S VPN)
                                                                  ▼
                                                          [ AWS ECR (Replica) ]
                                                                  │ (VPC Endpoint)
                                                                  ▼
                                                          [ EKS Workloads ]
```

### 1. Harbor 허브와 ECR 복제본 경계

- **Harbor (Hub)**: 모든 CI 빌드 산출물(HR System 등)의 최초 push 대상이며, 외부
  upstream(Docker Hub, Quay, k8s.gcr.io 등)의 proxy cache 프로젝트를 소유한다.
  Trivy 취약점 스캔, Cosign 이미지 서명 및 SBOM 생성을 Harbor 허브에서 일원화하여
  수행한다.
- **AWS ECR (Replica)**: EKS 워크로드 배포 전용 읽기 복제본이다. Harbor의 내장
  복제 규칙(`aws-ecr` 어댑터)을 통해 서명 및 SBOM 메타데이터와 함께 비동기 복제된다.
  Jenkins의 ECR 직접 push용 IAM 사용자(`SUPPLY-08`)는 폐기하고, Harbor 소유의 최소권한
  ECR 복제 자격증명(Vault 관리)으로 통합한다.

### 2. 이미지 pull이 Site-to-Site VPN을 건너지 않는 이유

- 온프레미스-AWS Site-to-Site VPN은 단일 IPsec 터널 기반으로 대역폭과 처리량에 한계가
  있으며 일시적 터널 순단 위험이 존재한다.
- EKS 노드의 Pod 기동, HPA 스케일아웃 또는 노드 교체 시 발생하는 대용량 컨테이너 이미지
  레이어 다운로드가 VPN을 경유하면 HR 트래픽, DB 연결, Argo CD 제어면 트래픽과 대역폭을
  경쟁하게 되며, VPN 장애가 EKS 워크로드 기동 장애로 전파된다.
- 따라서 EKS 노드는 동일 VPC 내의 사설 ECR VPC Endpoint(Interface/S3 Gateway)를 통해서만
  이미지를 pull하며, 이미지는 사전 비동기 복제된 ECR 사본을 소비한다.

### 3. EKS 관리형 애드온의 AWS 소유 ECR 유지 예외

- VPC CNI, CoreDNS, kube-proxy, AWS Load Balancer Controller 등 AWS EKS 관리형 애드온
  (Managed Add-ons)은 AWS 리전별 공식 ECR(`*.dkr.ecr.ap-northeast-2.amazonaws.com` 등)에서
  직접 배포 및 자동 패치된다.
- 관리형 애드온 이미지를 Harbor로 가져와 재태깅/복제하는 것은 AWS EKS add-on update
  수명주기와 불필요하게 충돌하고 운영 복잡성을 급증시킨다.
- 따라서 EKS Kyverno Admission 정책에서 AWS 공식 관리형 애드온 레지스트리를 명시적
  허용 목록(allowlist) 예외로 등록하여 AWS 소유 ECR에서 직접 pull하도록 허용한다.

### 4. Admission Control 및 failurePolicy 선택

- k3s와 EKS 클러스터 모두 Kyverno 정책을 통해 비인가 레지스트리 차단, digest 고정 및
  서명 검증을 강제한다.
- **전환 및 감사 단계 (Audit)**: `validationFailureAction: Audit`과 `failurePolicy: Ignore`를
  사용하여 기존 워크로드의 정상 배포를 보장하면서 위반 목록을 수집한다.
- **강제 단계 (Enforce)**: 검증 완료 후 `validationFailureAction: Enforce`와
  `failurePolicy: Fail`을 적용하여 보안 정책을 충족하지 않는 Pod 생성을 fail-closed로
  엄격히 거부한다.
- **시스템 네임스페이스 제외**: `kube-system`, `kyverno` 등 핵심 제어면 네임스페이스는
  admission webhook 장애 시 클러스터 bootstrap 마비를 방지하기 위해 정책 대상에서
  명시적으로 제외한다.

### 5. Digest 미고정 41건 처리 방침

현재 k3s 기준선 분석에서 전체 이미지 참조 160건 중 119건은 digest가 고정되어 있으나,
41건은 upstream tag-only(미고정) 상태다(Harbor 경유 1건).

- **1단계 (Audit 현황 확보, `SUPPLY-02`)**: 전 네임스페이스 대상 Kyverno Audit 정책으로
  미고정 41건 및 직접 upstream 참조 목록을 확정한다.
- **2단계 (Proxy Cache 구성, `SUPPLY-03`)**: Harbor에 실제 사용 중인 upstream(Docker Hub,
  Quay 등) proxy cache 프로젝트를 생성하고 Docker Hub 인증 pull을 연동하여 rate limit을 회피한다.
- **3단계 (점진적 경로 전환, `SUPPLY-04`)**: `gitops/apps/*` 선언의 upstream 직접 참조를
  Harbor proxy 경로 및 고유 digest(`@sha256:...`)로 전환하여 Audit 위반을 0건으로 줄인다.
- **4단계 (Enforce 승격, `SUPPLY-05`)**: 잔여 위반 0건 확인 후 허가 밖 레지스트리 및
  digest 미고정 차단을 Enforce로 전환한다.

## 검토한 대안

1. **완전 통일: Harbor 단일 레지스트리 사용**
   - EKS 노드가 VPN을 통해 온프레미스 Harbor에서 모든 이미지를 pull하게 되어 VPN 대역폭
     고갈, 레이턴시 급증, VPN 장애 시 EKS 노드/Pod 기동 불능 위험이 발생하므로 채택하지 않는다.
2. **완전 통일: ECR 단일 레지스트리 사용**
   - 온프레미스 k3s가 AWS ECR을 기본 레지스트리로 참조하면 온프레미스 독립성 및 폐쇄망
     원칙이 훼손되고, 12시간 주기 IAM 인증 토큰 갱신 오버헤드와 ECR 데이터 전송 비용이
     발생하므로 채택하지 않는다.
3. **현상 유지: Harbor와 ECR 독립 분리 및 Jenkins 각자 push**
   - Jenkins가 AWS ECR publisher IAM Access Key를 장기 보관해야 하여 보안 취약점이 남고,
     빌드 산출물의 서명·스캔·SBOM 정책이 온프레미스와 AWS로 분산되어 일관된 거버넌스 통제가
     불가능하므로 채택하지 않는다.

## 결과

- 모든 컨테이너 이미지에 대해 Harbor를 단일 원본이자 보안 통제 허브로 확립하고, ECR을
  EKS 전용 복제본으로 분리하여 고성능·고가용성 사설 pull 경로를 보장한다.
- Jenkins의 ECR publisher 정적 IAM 사용자를 폐기함으로써 AWS 정적 자격증명 노출 표면을
  축소한다.
- k3s와 EKS 모두에서 비인가 레지스트리 및 digest 미고정 이미지 배포를 Kyverno Enforce로
  차단하여 공급망 보안 수준을 완성한다.
- Harbor proxy cache 및 ECR replication 설정 관리가 추가되며, `capacity-plan.md`에 정의된
  `object-01` 스토리지 및 k3s 가용 자원 기준선을 지속적으로 모니터링해야 한다.

## 재검토 조건

- AWS Direct Connect 또는 고대역폭 다중 터널 도입으로 온프레미스-AWS 간 이미지 레이어
  전송 대역폭과 가용성 문제가 완전히 해소될 때
- Harbor의 OCI 1.1 artifact 복제 지원 사양이나 ECR 복제 프로토콜에 근본적 변경이 발생할 때
- EKS 워크로드가 온프레미스로 완전히 통합되거나 멀티 리전/멀티 클러스터 토폴로지로 확장될 때
