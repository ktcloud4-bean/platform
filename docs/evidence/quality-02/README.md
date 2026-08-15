# QUALITY-02 완료 증거

검증일: 2026-08-15
브랜치: `feat/quality-02`

## 결론

SonarQube는 **실제 애플리케이션 source의 release gate로 사용되지 않는다**. 현재 확인된
사용은 `QUALITY-01`의 합성 JavaScript project와 그 project를 재사용하는 `E2E-01` 검증뿐이다.
따라서 실제 제품 pipeline을 연결하지 않고, 현재 SonarQube Deployment·30 GiB PVC·PostgreSQL
DB·Vault/Jenkins credential도 삭제하지 않는다. 보존 후 폐기는 `QUALITY-03`에서 별도 승인으로
수행한다.

## 판정 증거

| 항목 | 결과 |
|---|---|
| 제품 source 후보 | `board-app/Jenkinsfile`에 Sonar 참조 0건. `aws/hr-system`에는 source·Dockerfile·requirements가 있으나 build/CI metadata는 `frontend/package.json` 외 Jenkinsfile·`sonar-project.properties`·Maven/Gradle 선언이 없다. |
| 제품 CI gate | `board-app/Jenkinsfile`은 checkout·dependency test·build·Trivy·Harbor/SBOM·Cosign 단계만 가지며 Sonar stage가 없다. |
| 플랫폼 CI 선언 | `gitops/tools/ci-01/seed/Jenkinsfile:35-49`의 Sonar stage는 `math.js`와 `quality01-pass`를 사용한다. |
| E2E 범위 | `gitops/apps/e2e-01/README.md:29-31`이 새 project를 만들지 않고 기존 합성 `quality01-pass`를 재사용한다고 명시한다. |
| 라이브 Sonar 상태 | API `UP`, version `26.7.0.124771`. project는 `quality01-fail`, `quality01-pass` 두 개뿐이다. |
| 최근 분석 | `quality01-fail`: `2026-08-02T08:50:35+0000`, gate `ERROR`, `coverage=0.0`; `quality01-pass`: `2026-08-02T14:38:58+0000`, gate `OK`. |
| owner | 두 project 모두 제품 owner 표기가 없고 `platform-users`·`sonar-users` 등 플랫폼 공용 권한만 확인됐다. 실제 제품 project·owner는 0건이다. |
| 라이브 자원 | SonarQube `Deployment 1/1`, Pod `Running 1/1`, PVC `sonarqube-data Bound 30Gi`. 삭제하지 않았다. |

`platform-root`는 이 작업과 무관한 `feat/supply-05-fix-01`의 검증 SHA
`83b45d71e9538a038323f473bf75ba1b4c7a8599`를 일시적으로 가리키고 있었다. 다른 작업의
`ARGO-ROOT` 검증을 건드리지 않았으며, QUALITY-02는 SonarQube API와 선언의 read-only 판정만
수행했다.

## 보존 및 후속 폐기 조건

현재 자원은 다음 승인 전까지 유지한다.

1. `BKP-03`의 PostgreSQL native backup으로 `sonarqube` DB를 보존하고, `BKP-02`의 local-PV
   filesystem backup으로 `sonarqube-data` PVC를 별도 보존한다. `ADR-0005`에 따라 로컬 사본을
   오프사이트 사본으로 간주하지 않으며, `BKP-04` 경로와 격리 restore 증거를 함께 확보한다.
2. `sonarqube` namespace/Application/PVC, PostgreSQL `sonarqube` DB·role, Vault의
   `kv/sonarqube/runtime`·`kv/sonarqube/verification` 및 관련 auth role/policy,
   Pomerium route/egress, Jenkins의 `e2e01_sonar_token` 파생 credential 각각에 대해 대상·보존
   기간·삭제 승인자를 확인한다.
3. `E2E-01`이 합성 `quality01-pass` gate를 계속 호출하므로, 이를 제거·대체하거나 보존할지
   먼저 결정한다. 이 의존성을 확인하기 전에는 Sonar token과 SonarQube DB/PVC를 회수하지
   않는다.
4. 승인 뒤에만 정확한 대상의 GitOps prune, DB/PVC 삭제, Vault credential/policy/role 회수와
   Jenkins credential 정리를 수행한다. 이번 작업에서는 이 작업을 수행하지 않는다.

후속 작업은 `QUALITY-03 READY`로 열었다.

## 2026-08-15 후속 결정

위 결론은 `QUALITY-02` 검증 시점에 제품 연결이 없었다는 snapshot으로 유효하다. 이후 제품
소유자가 SonarQube를 유지하고 권위 GitHub `ktcloud4-bean/hr-system`에 실제 테스트와 80%
coverage gate를 도입하기로 결정했다. 이에 따라 폐기 범위였던 `QUALITY-03`은
[ADR-0029](../../adr/0029-hr-system-testing-and-sonarqube-release-gate.md)의 채택 설계 작업으로
대체했고, 구현을 `QUALITY-04`~`06`으로 분리했다. 이 후속 결정으로 SonarQube·DB·PVC·credential
삭제 조건은 활성 작업이 아니며 기존 자원을 그대로 보존한다. 당시 read-only 판정 증거와
라이브 수치는 소급 변경하지 않는다.
