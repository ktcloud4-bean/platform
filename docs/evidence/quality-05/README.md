# QUALITY-05 완료 증거

## 범위

HR System의 GitHub/Gitea mirror SHA를 고정한 Jenkins quality gate와 제품
`test → JUnit/coverage 게시 → Sonar gate → image build` 순서를 연결했다.
검증용 Argo 포인터는 `platform-root=1ed4b4da81b874720c595fea144b4219defacae9`,
Jenkins child 선언은 `c1d79367281d81e667ac26ea78848cdd0ce16477`로 고정했다.
두 Application은 검증 중 `Synced/Healthy`였다. 검증 종료 후 두 포인터는
최종 선언에서 다시 `main`으로 복구한다.

## 제품·credential 경계

- GitHub `ktcloud4-bean/hr-system` `main`과 Gitea mirror `main`은
  `fbeae1d43011e40080acf1b3da7e1a9dc5a80ced`로 일치했다.
- `frontend`의 Vitest와 `@vitest/coverage-v8`를 3.2.6으로 올렸고,
  `npm audit --audit-level=high`는 `0 vulnerabilities`였다.
- `gitops/tools/quality-05/provision.sh --apply` 및 `--check`를 실행해
  기존 Sonar token을 보존하고 GitHub read token만 `kv/hr-system/jenkins`에
  추가했다. Jenkins Vault Agent/JCasC는 `hr_system_github_token` 파일과
  `github-hr-system-readonly` credential id만 참조하며 secret 원문은 저장하지
  않는다.

## Jenkins 양성 증거

| 항목 | 결과 |
|---|---|
| build | `hr-system-image-build #41`, `SUCCESS` |
| source | `fbeae1d43011e40080acf1b3da7e1a9dc5a80ced`, `github-mirror-match=true` |
| 테스트 보고서 | HTTP 200, JUnit total 25, fail 0, skip 0 |
| coverage/Sonar | Python Cobertura 2개와 frontend LCOV 게시, `quality05-sonar-quality-gate=pass`, project `hr-system`, version `0.1.0` |
| release handoff | `frontend`, `employee-service`, `hr-service` 세 컴포넌트 모두 `hr-system-release-handoff=ready` |
| agent | `ci01-buildah-vn1pt`; PostgreSQL sidecar가 포함된 동적 agent가 실행됨 |

Jenkins 선언의 PostgreSQL sidecar는 검증·서명된 Harbor digest
`sha256:9a70e4d1c03a5066080292db2dd95ee3965d3651316e21989fa0935afb8ce8ca`를
사용하고, `/home/jenkins/agent` working directory와 PVC 없는 임시 container
storage를 사용한다.

## Jenkins 의도적 실패 증거

| 항목 | 결과 |
|---|---|
| build | `hr-system-image-build #42`, `FAILURE` |
| fixture | `tests/test_quality05_fixture_failure.py`의 `QUALITY-05 intentional fixture failure`가 실제 수집·실패 |
| 테스트 보고서 | HTTP 200, JUnit total 26, fail 1, skip 0 |
| 공급망 단계 | image build/push 명령과 `hr-system-release-handoff=ready` 모두 없음 |

실패 fixture는 pytest `test_*.py` 수집 규칙을 따르도록 수정했고, component
subshell의 pytest 실패를 명시적으로 `exit 1`로 전파했다. 이 보정 전에는
fixture가 수집되지 않거나 subshell의 assignment 성공으로 test gate가
계속되는 결함이 콘솔에서 확인됐으며, 같은 제품 작업 범위에서 수정했다.

## 라이브 보정 기록

- 기존 `board-demo-registry`의 삭제된 Harbor robot으로 Kyverno 검증이 실패한
  실제 원인을 Harbor 로그에서 확인하고, `curated-platform` project-scoped
  pull-only robot으로 Secret만 교체했다. Kyverno `failurePolicy=Fail`은
  완화하지 않았다.
- Jenkins GitHub private repository SHA 확인은 Bearer가 아닌 Git transport용
  Basic auth credential로 고정했다. 임시 Gitea mirror-sync token은 매번 DB에서
  삭제해 잔여 0건을 확인했다.

## 범위 밖

새 dashboard, 실사용자·AWS·EKS·Aurora 변경, PVC/VM 삭제, 자동 배포와 Git write
권한은 추가하지 않았다. 기존 `QUALITY-01` scanner 음성 증거는 재사용했고,
QUALITY-05 제품 fixture 음성만 위에서 한 번 실행했다.
