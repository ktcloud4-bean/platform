# 에이전트 작업 지침

이 저장소는 온프레미스 랩의 베어메탈, 네트워크, 가상화, 통합인증과 공급망 보안을 정의한다. 답변과 기록은 한국어로 작성한다.

## 먼저 읽을 문서

| 문서 | 읽는 시점 |
|---|---|
| `docs/backlog.md` | 세션 시작 시 항상 |
| `docs/architecture.md` | 서비스 배치·의존성·보안 경계를 바꿀 때 |
| `docs/adr/README.md` | 선택 이유·대안·재검토 조건을 바꿀 때 |
| `docs/ip-plan.md` | IP·VLAN·DNS·도메인을 다룰 때 |
| `docs/capacity-plan.md` | VM 자원 배정·PVC 용량·정지 기준을 다룰 때 |
| `infra/opnsense/README.md` | OPNsense를 조회하거나 변경할 때 |
| `infra/proxmox/tofu/README.md` | Proxmox VM을 OpenTofu로 계획하거나 적용할 때 |
| `infra/aws/tofu/README.md` | AWS 오프사이트 착지점을 계획하거나 적용할 때 |
| `README.md` | 저장소 구조나 운영 원칙을 바꿀 때 |

백로그 작업에 ADR이 연결되어 있으면 작업 전에 해당 ADR을 함께 읽는다.

주소와 설정값은 해당 단일 원본을 참조하고 다른 문서에 복제하지 않는다.

## 백로그 작업 규칙

1. 한 세션은 `docs/backlog.md`의 작업 ID 하나를 맡는다.
2. 모든 선행 작업이 `DONE`인 항목만 실행한다.
3. 같은 `잠금`을 가진 작업은 동시에 실행하지 않는다.
4. 작업자는 완료 증거를 확보하면 같은 세션에서 맡은 ID를 `DONE`으로 갱신하고, 모든 선행이 충족된 직접 후속 ID만 `READY`로 연다.
5. 라이브 상태가 문서의 전제와 다르면 변경하지 말고 차이와 영향 작업을 보고한다.
6. OPNsense·Proxmox·OpenTofu state처럼 공유 상태를 다루는 작업은 계획과 적용을 한 작업자가 끝까지 소유한다.
7. 작업 ID 하나는 최신 `origin/main`에서 만든 전용 브랜치와 worktree 하나가 소유한다. 작업 파일을 `main` worktree에서 직접 수정·커밋하지 않는다.

## 승인

- 작업 배정은 명시된 범위의 Git·라이브 적용, 서비스 재기동, 검증과 rollback을 승인한 것으로 본다. 같은 범위를 다시 묻지 않는다.
- 범위 확대, 잠금 충돌, 중대한 live drift, 데이터·PVC·VM·디스크 삭제, k3s server·물리 호스트 재시작, 방화벽·공개 DNS·외부 노출, credential·암호화 키 교체만 적용 직전에 승인받는다.
- Argo `platform-root`와 production child Application의 `targetRevision`은 `main`을 유지한다. 작업 branch나 commit으로 바꾸지 않는다.

### 완료 후 merge

작업 브랜치에는 여러 WIP 커밋을 허용하지만, `main`에는 백로그 작업 하나당 최종 커밋 하나만 남긴다.

- `main` 통합은 한 번에 한 작업만 수행한다. 통합 순서를 확보한 뒤 최종 검증 직전에 작업 브랜치를 최신 `origin/main`에 rebase하고, 충돌을 자기 브랜치에서 해결한 뒤 전체 증거를 다시 검증한다. 통합 전에 `main`이 바뀌면 이 과정을 반복한다.
- rebase로 원격 작업 브랜치를 갱신할 때는 단독 소유 브랜치에만 `--force-with-lease`를 쓸 수 있다. 공개된 `main`은 rebase하거나 force-push하지 않는다.
- 통합 담당자는 깨끗하고 최신인 `main` worktree에서 작업 브랜치를 한 번만 squash merge한다. 이 squash 결과를 작업 ID와 검증 내용이 담긴 단일 커밋으로 만드는 것만 `main` 통합 커밋으로 허용한다.
- squash 전에는 다른 작업자의 백로그·문서 변경을 보존하고 자기 작업 범위만 staged됐는지 확인한다. 충돌 해결이나 rebase 뒤에는 관련 검증을 다시 실행한다.
- main 반영 전 검증이 가능한 작업은 완료 증거가 없거나 검증이 실패하면 merge하지 않는다.
- Argo가 `main`을 읽어야 검증할 수 있는 작업은 사전 검증·rollback 준비 뒤 최종 squash에 `DONE`과 후속 상태를 포함한다. main push 직후 같은 세션에서 live 검증하며, 검증이 끝나기 전에는 후속 작업을 시작하지 않는다.
- 이 live 검증이 실패하면 공개 main을 고치지 않고 해당 squash를 즉시 revert해 상태·선언을 함께 복구한다. 같은 작업 ID로 재시도하지 않고 새 FIX ID를 만든다.
- 성공한 live 증거만 추가하는 main 커밋은 만들지 않는다. 검증 결과는 완료 보고에 남긴다.
- main push 뒤 원격 SHA와 해당되는 라이브 상태를 다시 검증하기 전에는 작업을 종료하거나 브랜치·worktree를 정리하지 않는다.
- merge 뒤 결함이 발견되면 기존 작업 ID나 공개된 main 이력을 다시 쓰지 않는다. 별도 FIX 작업 ID와 전용 브랜치·worktree에서 보정하고, 그 작업도 main 커밋 하나로 남긴다.
- squash merge된 브랜치는 조상 관계로는 미병합처럼 보일 수 있다. main에 최종 변경이 모두 포함됐음을 확인한 뒤 worktree, 원격 브랜치, 로컬 브랜치 순서로 삭제한다.

## 안전 원칙

- 베어메탈과 네트워크는 자동 교정하지 않는다. 명시된 작업 범위 밖의 변경은 적용하지 않는다.
- `config.xml`, tfstate, kubeconfig, Vault 초기화 출력과 각종 토큰을 원문으로 커밋하지 않는다.
- 설치·삭제·디스크 초기화·인터페이스 전환 전에는 대상과 복구 경로를 다시 확인한다.
- 완료는 파일 생성이 아니라 라이브 검증과 복구 증거까지 포함한다.
