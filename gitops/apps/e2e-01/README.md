# E2E-01 공급망 admission 경계

이 child는 `E2E-01` 검증 namespace와 그 namespace의 Pod에만 적용되는 Kyverno
`ImageValidatingPolicy` 한 건을 소유한다. cluster-scoped kind이지만
`matchConditions`가 `e2e-01` namespace만 정확히 선택한다. `policies/`의 기존
`ClusterPolicy` 승격과 예외·만료는 `POL-02`가 소유한다.

AppProject는 기존 `kyverno.io/Policy`와 새 `policies.kyverno.io/ImageValidatingPolicy` kind를
모두 허용한다. 이는 시작 main의 기존 policy를 Argo가 추적해 prune하고 rollback 때 복원하기
위한 전환 경계다. 라이브 정책 카탈로그는 새 image policy 한 건이며 다른 namespace는
`matchConditions`에서 제외된다.

## 체인과 digest handoff

```text
Gitea source -> Jenkins dynamic agent -> SonarQube quality gate
             -> Trivy image gate -> Harbor image/SBOM digest
             -> Cosign current-key signature -> 작업 branch의 digest 선언
             -> Argo CD child -> Kyverno admission -> Pod Running
```

Jenkins는 GitHub 쓰기 credential을 갖지 않는다. pipeline의
`e2e01-release-handoff`가 낸 signed digest를 작업자가 검증 commit의 Pod 선언에 넣고,
`ARGO-ROOT` 잠금 아래 그 immutable SHA를 child가 읽는다. 같은 pass build는 scan 뒤 image
label만 바꾼 별도 digest를 `e2e-unsigned-*` tag로 올리되 서명하지 않는다. 이 digest는
pipeline을 다시 실행하지 않고 admission 거부 입력으로만 쓴다.

정상 image는 장시간 `Running`을 판정할 수 있도록 package DB가 없는 고정 Kubernetes pause
base를 쓴다. Sonar stage는 `QUALITY-01`의 기존 `quality01-pass` project와
project-scoped token, ClusterIP Service를 그대로 사용하고 `sonar.qualitygate.wait=true`가
성공하기 전에는 build·push·sign으로 진행하지 않는다. 새 SonarQube project, 외부 scanner
route와 Jenkins plugin은 만들지 않는다.

## trust와 registry credential 전달

Vault의 소유 원본은 바꾸지 않는다. `provision.sh --apply`가 다음 값만 파생 경로로 복사한다.

- `kv/jenkins/runtime`의 current/previous Cosign 공개키와 기존 `ci01-evidence` robot
- `kv/sonarqube/verification`의 pass project token

`e2e-01-verifier` Vault role은 `kv/e2e-01/runtime`만 읽고, Jenkins에 추가한 policy는
`kv/e2e-01/jenkins`만 읽는다. Sync hook은 audience `vault` projected token과 명시적 Vault
Agent init을 사용해 공개키 Secret 두 개와 registry pull Secret을 `e2e-01` namespace에 한 번
materialize한다. 같은 registry pull Secret은 Kyverno v1.18.2의 실제 image verifier가 읽는
`kyverno` namespace에도 한 번 복사한다. 이는 지속 동기화 operator가 아니며 원문은 Git, Job
로그와 명령 인자에 넣지 않는다. image policy는 registry credential을 이 사본에서,
current/previous trust는 `e2e-01` namespace의 exact Secret을 `resource.get`으로 읽는다.

공식 문서는 v1.18부터 `namespace/name` registry Secret 참조를 지원한다고 설명하지만, 고정한
v1.18.2 admission binary의 registry informer는 실제로 `kyverno` namespace 하나만 watch한다.
따라서 policy는 `kyverno/e2e-01-registry`를 plain name으로 읽는다. bootstrap ServiceAccount는
그 exact Secret을 `get/update`하고 최초 1회 생성할 수 있으며, Job은 성공 뒤 삭제된다.

파생 KV 적용기는 Vault Pod image에 `jq`가 없으므로 source JSON을 stdout에 출력하지 않고
호출자 소유 mode `0700` 임시 디렉터리의 파일로만 받은 뒤 workstation `jq`로 허용 필드만
줄인다. 파생 payload는 stdin으로 Vault Pod에 돌려보내고 trap에서 임시파일을 제거한다.

current와 previous 공개키 중 하나가 일치하면 허용하되 새 artifact는 pipeline이 current로만
서명한다. Kyverno v1.18.2 IVP가 옵션 생성에 요구하는 공식 Rekor URL은 명시하지만,
tlog/Fulcio/Rekor를 사용하지 않는 SIGN-01 경계와 맞춰 tlog/SCT 확인은 끄고,
`resource.get`으로 exact Secret의 공개키를 읽어 Cosign v3 static-key verifier에 넘긴다.
이 verifier는 Sigstore Bundle OCI 1.1 referrer를 자동 감지하므로 legacy tag나 trust 없는
embedded key로 우회하지 않는다. 키 회전 뒤에는 이 작업의 provision을 다시 실행해 파생 trust를
갱신하고, previous 제거 시점은 `POL-02`가 결정한다.

## 동기화와 rollback

| wave | 자원 | 성공 조건 |
|---|---|---|
| `-3` | Namespace | `e2e-01` 하나만 생성 |
| `-2` | ServiceAccount·RBAC·공개 trust/agent/script ConfigMap | one-shot bootstrap 입력 준비 |
| `-1` | Sync hook Job | runtime Secret 세 개 준비 후 Job 삭제 |
| `0` | Kyverno image policy | exact namespace match로 `e2e-01`의 Harbor release Pod만 Deny action으로 강제 |

라이브 적용 전에는 아래 세 명령만 실행한다. pipeline은 `pipeline` mode 한 번뿐이고,
`admission` mode는 그 결과 digest 두 개를 입력으로 사용한다.

```bash
gitops/tools/e2e-01/provision.sh --check
gitops/tools/e2e-01/provision.sh --apply
gitops/tools/e2e-01/check-capacity.sh

gitops/tools/e2e-01/verify-live.sh pipeline
gitops/tools/e2e-01/verify-live.sh admission <signed-digest> <unsigned-digest>
```

정상 `platform-root`와 child는 `targetRevision: main`이다. merge 전에는 최신 main에 rebase한
config SHA와 child pointer SHA를 사용하고, pipeline digest가 생기면 Pod 선언 commit과 새
pointer commit을 push해 Argo가 그 digest를 생성하게 한다. 증거 뒤 Pod 선언을 제거한 cleanup
SHA까지 sync한 다음 시작 main SHA로 root를 돌린다.

rollback은 root를 시작 main SHA로 복원해 `Application/e2e-01`을 foreground 삭제하고,
namespace와 image policy·runtime Secret이 사라진 뒤 `AppProject/e2e-01`만 수동 삭제한다.
`kyverno/e2e-01-registry`는 namespace 밖 파생 사본이므로 정확한 이름으로 함께 삭제한다.
Gitea seed는 `gitops/tools/ci-01/provision.sh --seed-rollback <시작-main-SHA>`로 시작 main의
기존 세 파일을 복원하고 E2E 전용 두 파일을 제거한다. 작업을 중단할 때만
`gitops/tools/e2e-01/provision.sh --destroy`로 파생 KV/policy/role과 Jenkins role 추가 policy를
제거한다. 기존 Jenkins/Harbor/SonarQube/Cosign 원본은 rollback 대상이 아니다.
