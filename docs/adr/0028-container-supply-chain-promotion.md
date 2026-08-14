# ADR-0028: 컨테이너 공급망 승격과 소비 경계

- 상태: `Accepted`
- 날짜: 2026-08-14
- 대체: [ADR-0027](0027-container-registry-hub-and-replica.md)
- 관련 작업: `SUPPLY-DESIGN-01-FIX-01`, `SUPPLY-01`~`08`, `REG-01`, `SCAN-01`,
  `SIGN-01`, `AWS-HR-01`

## 배경

[ADR-0027](0027-container-registry-hub-and-replica.md)은 Harbor를 허브, ECR을 EKS용
복제본으로 선택했지만 구현자가 안전한 승격 경로를 만들기에는 다음 경계가 부족했다.

- 현재 Harbor 선언은 내장 Trivy를 끄고, Jenkins가 Trivy 취약점 gate와 CycloneDX SBOM
  생성, OCI 1.1 referrer 첨부와 Cosign 서명을 수행한다. 따라서 Harbor가 스캔·SBOM·서명을
  "수행"한다는 표현은 실제 책임과 다르다.
- Harbor proxy cache는 upstream pull과 rate limit을 줄이는 캐시다. push 대상이 아니며
  upstream에서 artifact가 사라지면 영구 보관 원본처럼 사용할 수 없다. 이를 최종 workload
  경로로 쓰면 Harbor가 단일 원본이라는 결정과 충돌한다.
- 서명된 artifact의 Harbor replication은 image push event만으로 완결되지 않는다. image,
  SBOM과 signature가 모두 생긴 뒤 manual 또는 scheduled replication을 실행해야 하며,
  비동기 job 성공만으로 ECR에 referrer 관계가 보존됐다고 단정할 수 없다.
- EKS의 VPC CNI·CoreDNS·kube-proxy는 AWS 관리형 add-on이지만 AWS Load Balancer
  Controller는 이 저장소가 Helm과 자체 ECR mirror로 관리한다. 네 항목을 같은 AWS 공식
  예외로 묶으면 customer ECR 통제를 우회한다.
- ECR의 기존 untagged lifecycle rule은 OCI 1.1 signature와 attestation referrer 보존을
  증명하지 않았다. subject image만 남고 검증 증거가 먼저 만료되는 정책은 허용할 수 없다.
- Harbor의 AWS ECR adapter는 Access ID와 Secret을 저장한다. 온프레미스 Harbor에 native
  AWS workload identity가 없는 현재 구조에서 Jenkins key를 없애면서 전체 standing AWS
  key가 세 개로 줄어든다는 기존 완료 기준은 성립하지 않는다.

Harbor의 공식 문서는 proxy cache를 pull cache로 정의하고 upstream이 artifact를 삭제하면
제공하지 않는다고 설명한다. 또한 Cosign 연관 artifact를 비-Harbor registry로 보낼 때는
manual/scheduled replication만 지원하며 대상 registry에서 관계가 같은 방식으로 표현된다고
보장하지 않는다. ECR은 OCI 1.1 Referrers API를 지원하므로 최종 호환성은 destination에서
직접 검증한다.

## 결정

### 1. 저장 위치가 아니라 검증된 승격 상태를 신뢰 경계로 삼는다

Harbor는 유일한 **승격 원본**, ECR은 EKS용 **읽기 소비 복제본**으로 유지한다. 다만 Harbor에
존재한다는 사실만으로 신뢰하지 않고 다음 상태를 모두 통과한 digest만 release로 취급한다.

```text
Git/source
   │
   ▼
Jenkins candidate build 또는 upstream proxy fetch
   │  exact OCI digest 확정
   ▼
Trivy gate ── CycloneDX SBOM 생성·Cosign attestation
   │
   ▼
image signature와 SBOM attestation signature를 Harbor에서 검증
   │
   ▼
Harbor trusted project로 승격
   │
   ├──────────────► k3s: Harbor digest를 admission 후 pull
   │
   ▼
scheduled Harbor → ECR replication
   │
   ▼
ECR에서 image digest·SBOM attestation·두 signature 재검증
   │
   ▼
GitOps가 검증된 ECR digest만 선언 ──► EKS
```

승격 단위는 tag가 아니라 `registry/repository@sha256` subject, SBOM attestation digest,
Cosign key fingerprint와 scan 판정을 묶은 tuple이다. multi-arch image는 OCI index digest와
실제 node architecture의 child manifest가 모두 같은 승격 기록에 속한다. tag는 사람이 찾기
위한 별칭이며 admission·rollback·복제 판정의 근거가 아니다.

복제 실패, destination referrer 누락, signature 불일치 또는 scan 실패가 있으면 GitOps
digest를 바꾸지 않는다. 직전 검증 release가 계속 서비스하며 실패 artifact는 candidate로
남는다. EKS 장애 시 Harbor로 reverse pull하거나 VPN을 통한 runtime pull로 우회하지 않는다.

### 2. first-party와 third-party artifact의 유입을 분리한다

| 구분 | 유입 | 최종 원본 | 필수 gate |
|---|---|---|---|
| 자체 build | Jenkins가 일반 Harbor candidate project에 push | 일반 Harbor trusted project | exact build digest의 Trivy, image signature·signed CycloneDX attestation |
| upstream | registry별 Harbor proxy project가 digest로 fetch | proxy가 아닌 일반 Harbor curated project | OCI copy digest의 Trivy, image signature·signed CycloneDX attestation |
| EKS 관리형 add-on | AWS가 관리하는 리전별 공식 ECR | AWS 공식 ECR | exact add-on identity·registry 예외와 AWS lifecycle |

Proxy cache는 discovery·rate-limit·일시 장애 완충에만 쓴다. workload 선언은 proxy project를
참조하지 않는다. upstream artifact는 `SUPPLY-04`에서 normal curated project로 copy하고
플랫폼 서명을 붙인 뒤 소비한다. 이 서명은 upstream 제작자 신원이 아니라 "플랫폼이 이
digest와 scan/SBOM을 검토해 배포를 승인했다"는 뜻이다.

Harbor 내장 Trivy는 계속 꺼 둔다. Jenkins가 artifact 생산과 보안 gate를 소유하고, Harbor는
artifact·referrer 저장, immutable/retention과 replication을 소유한다. scanner를 이중으로
운영해 서로 다른 DB 시점의 판정을 만들지 않는다.

### 3. Harbor에서 ECR로는 완성된 release를 scheduled push한다

Cosign image signature와 SBOM attestation이 image 뒤에 생성되므로 event-based replication은 쓰지
않는다. Harbor `aws-ecr` adapter의 scheduled push rule이 trusted project의 완성된 release만
정확한 ECR repository로 보낸다. schedule 지연보다 짧은 배포 완료를 약속하지 않으며,
promotion verifier는 정해진 bounded timeout 안에서 다음을 모두 확인한다.

1. Harbor와 ECR의 subject digest가 같다.
2. ECR의 OCI 1.1 referrer discovery에서 image signature와 CycloneDX attestation이 보인다.
3. ECR 주소에서 기존 current 또는 previous Cosign public key로 `cosign verify`와
   `cosign verify-attestation`이 각각 통과하고 attestation payload의 `bomFormat`이
   `CycloneDX`다.
4. ECR repository의 immutable tag 정책과 충돌하지 않고 EKS에서 exact digest pull이 된다.

Harbor job의 `Success`만으로 2~3을 대신하지 않는다. adapter가 ECR에 referrer를 완전하게
복제하지 못하면 Jenkins direct ECR push를 되살리지 않고 `SUPPLY-06`을 중단해 이 ADR을
재검토한다.

삭제는 replication trigger로 전파하지 않는다. Harbor와 ECR retention은 subject와 모든
referrer를 하나의 release로 보존해야 하며, ECR lifecycle preview에서 untagged rule이
signature/attestation을 먼저 지우지 않는다는 증거를 확보한 뒤 적용한다. rollback은 양쪽에 남은
이전 검증 digest를 Git에서 다시 선택하며 rebuild·retag로 대체하지 않는다.

### 4. admission은 registry·digest·증거를 별도 판정한다

k3s와 EKS는 각각 다음 세 경계를 독립 규칙으로 판정한다.

1. 허용 registry/repository인가.
2. 선언이 digest로 고정됐는가.
3. 해당 digest의 플랫폼 Cosign image signature와 signed CycloneDX attestation이 검증되는가.

Audit의 policy violation 동작과 webhook 자체의 오류 동작을 섞지 않는다. inventory 단계는
rule의 failure action을 Audit으로 두고 registry 장애를 기존 workload 중단으로 전파하지
않도록 webhook failure policy를 Ignore로 둔다. Enforce 승격 뒤에는 violation을 Deny하고
webhook failure policy를 Fail로 바꾼다. registry credential·latency·timeout을 먼저 실증하지
않은 policy는 Enforce하지 않는다. 현재 Kyverno 1.18의 신규 image 정책은 stable
`ImageValidatingPolicy`로 작성하고, 기존 `e2e-01` legacy `ClusterPolicy`는 이 작업에서
마이그레이션하지 않는다.

`kube-system`이나 `kyverno` namespace 전체를 제외하지 않는다. bootstrap 또는 vendor lifecycle
때문에 플랫폼 서명을 적용할 수 없는 항목은 namespace, controller kind/name, ServiceAccount와
exact registry/repository를 함께 고정한 예외만 허용한다. EKS의 VPC CNI·CoreDNS·kube-proxy는
AWS가 해당 리전에 게시한 공식 ECR 값만 이 예외를 사용한다. 자체 ECR mirror에서 배포하는
AWS Load Balancer Controller, Argo CD와 Redis bootstrap image는 일반 customer ECR 정책을
통과해야 한다.

EKS Kyverno는 Amazon registry credential helper와 전용 Pod Identity/IRSA read role을 사용하고
static Docker credential을 두지 않는다. k3s Kyverno의 private Harbor 조회 credential은
Vault 원본에서 exact namespace Secret으로 파생하고 admission controller에 read만 허용한다.

### 5. AWS credential의 잔여 위험을 숨기지 않는다

Harbor ECR replication은 `/service/harbor/` 전용 IAM user 한 개와 active access key 한 개를
쓴다. 권한은 대상 ECR repository의 layer upload·manifest read/write와 account-wide
`GetAuthorizationToken`으로 제한하고 delete, repository policy/lifecycle, 다른 AWS API를
허용하지 않는다.

key 원본은 저장소 밖 입력과 Vault가 소유하며 Git·Kubernetes Secret·검증 출력에 넣지 않는다.
Harbor endpoint가 동작하려면 encrypted Harbor DB에도 working copy가 저장된다는 사실을
문서와 backup 경계에 포함한다. 회전은 두 번째 key 생성 → Vault와 Harbor endpoint 갱신 →
ping·시험 replication → 이전 key 폐기 순서로 한다.

따라서 `SUPPLY-08` 뒤 standing AWS access key는 `backup`, `vault_auto_unseal`,
`argocd_credential_issuer`, `harbor_ecr_replicator` 네 건이다. 완전한 keyless가 필요해지면
Harbor가 session credential을 안전하게 갱신할 수 있는지 먼저 확인한 뒤 IAM Roles Anywhere
또는 AWS 안의 pull worker를 별도 ADR로 검토한다.

### 6. 숫자 snapshot은 ADR이 아니라 inventory 작업이 소유한다

이미지 참조 총계와 digest 미고정 건수는 chart rendering, live controller와 완료 시점에 따라
변한다. ADR에는 숫자를 고정하지 않는다. `SUPPLY-02`가 같은 추출기로
`cluster/namespace/controller/container/image/digest/registry/exception` tuple을 산출하고,
Git 선언·렌더 결과·live policy report의 차이를 기록한다.

새 registry, tag-only 참조, signature/attestation 누락 또는 범위가 넓어진 예외를 drift로 취급한다.
정상 release 수와 retention 값은 현재 용량과 rollback 요구를 측정한 구현 작업이 소유한다.

## 검토한 대안

1. **Proxy cache를 production 원본으로 사용**
   - upstream 삭제와 cache policy에 최종 가용성이 종속되고 플랫폼이 retention을 완전히
     소유하지 못하므로 채택하지 않는다.
2. **Harbor push event로 즉시 ECR 복제**
   - image event 시점에는 SBOM과 signature가 아직 없을 수 있어 불완전 release를 먼저
     배포할 수 있으므로 채택하지 않는다.
3. **Jenkins가 Harbor와 ECR에 각각 push**
   - 두 경로의 결과와 credential이 다시 분기되고 ECR direct publisher 제거 목적을
     무효화하므로 채택하지 않는다.
4. **`kube-system` 전체 정책 제외**
   - 사용자 관리 controller까지 검증을 우회하고 AWS 공식 add-on 예외의 범위를 증명할 수
     없으므로 채택하지 않는다.
5. **Harbor ECR credential이 없다고 간주**
   - adapter의 실제 secret 저장 경계와 standing key 수를 숨기므로 채택하지 않는다.

## 결과

- Harbor는 cache가 아니라 검증을 끝낸 normal project를 기준으로 단일 승격 원본이 된다.
- Jenkins, Harbor와 Kyverno의 책임이 각각 생산·검증, 저장·복제, admission으로 분리된다.
- ECR에 artifact가 있다는 사실이 아니라 destination에서 image signature·CycloneDX attestation을 재검증한
  결과가 EKS 배포 gate가 된다.
- AWS 관리형 add-on만 exact 예외를 사용하고 GitOps 관리 controller는 일반 정책을 통과한다.
- VPN 또는 Harbor 장애는 이미 복제된 EKS image pull에 영향을 주지 않고, 복제 실패는 새
  release만 멈춘다.
- 온프레미스 ECR replication용 standing key 한 건이 남는 비용을 명시적으로 수용한다.

## 재검토 조건

- Harbor ECR adapter가 OCI 1.1 image·signature·attestation을 destination에서 검증 가능하게 복제하지
  못할 때
- Harbor가 on-prem workload identity 또는 자동 갱신 가능한 AWS session credential을 지원할 때
- ECR lifecycle이 subject와 referrer를 같은 release 단위로 보존하지 못할 때
- AWS 관리형 add-on의 registry·서명 전달 방식 또는 EKS admission bootstrap 경계가 바뀔 때
- AWS Direct Connect, multi-region ECR 또는 두 번째 Harbor가 생겨 replication topology가
  달라질 때

## 제품 제약 근거

- [Harbor proxy cache 동작](https://goharbor.io/docs/main/administration/configure-proxy-cache/)
- [Harbor Cosign artifact와 replication trigger](https://goharbor.io/docs/main/working-with-projects/working-with-images/sign-images/)
- [Amazon ECR OCI 1.1 reference artifact](https://docs.aws.amazon.com/AmazonECR/latest/userguide/images.html)
- [EKS add-on의 리전별 공식 image registry](https://docs.aws.amazon.com/eks/latest/userguide/add-ons-images.html)
- [Kyverno ImageValidatingPolicy의 signature·attestation 판정](https://kyverno.io/docs/policy-types/image-validating-policy/)
