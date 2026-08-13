# SOAR-01 승인형 read-only 흐름 도구

`provision.py`는 기존 `Platform Security` 조직에만 다음 Dashboard 객체를 등록한다.

- `SOAR-01 Local Enrichment:1.0.0`: IPv4·URL·SHA-256만 오프라인 추출하는 앱 등록
- `SOAR-01 Wazuh read-only approval`: Wazuh webhook → 오프라인 보강 → `User Input`
  (manual) 승인 대기 workflow
- `kv/wazuh/manager`의 `soar01_hook_url` 한 필드와 `imcherry5778`의
  `/soar-readers` → `/soar-operators` 단일 그룹 이동

자동 격리·방화벽 변경·계정 변경·외부 email/SMS/subflow 호출은 구현하거나 호출하지 않는다.
hook URL, Vault token, 회복 계정 비밀번호·TOTP, Shuffle session cookie는 출력하거나 Git에
기록하지 않는다.

## 실행 순서

`check`는 읽기 전용이다. Keycloak recovery TOTP는 재사용을 피하려고 다음 30초 slot 하나를
기다린다. 포트포워드는 SSH 종료 때 원격 자식도 정리한다.

```bash
gitops/tools/soar-01/provision.py check
gitops/tools/soar-01/provision.py apply
```

`apply`는 Git 선언의 정적 worker/app Deployment가 아직 Argo에 반영되기 전에 Dashboard
workflow·Vault capability·operator 그룹을 준비한다. Workflow 등록 직후 backend를 한 번 재기동해
영속화된 action/trigger ID로 webhook을 결합한다. 이후 `ARGO-ROOT` 절차로 같은 immutable
SHA의 `shuffle`·`wazuh`를 동기화한다. `apply`를 다시 실행하지 않는다. 중단 또는 검증 실패는
다음 명령으로 이 작업이 만든 hook, workflow, app, Vault field를 지우고 operator를 reader 하나로
되돌린다.

```bash
gitops/tools/soar-01/provision.py rollback
```

`rollback`은 다른 Dashboard 객체를 이름 추측으로 삭제하지 않는다. 같은 SOAR-01 이름의 app이나
workflow가 둘 이상이면 대상 선택 없이 실패한다.

immutable root/child 검증은 `verify-immutable-argo.py`가 `/tmp/argo-root.lock`을 잡고 수행한다.
검증 동안에만 root가 두 child의 `targetRevision` 차이를 ignore하며, 성공·실패와 관계없이 그
temporary ignore field와 세 Application을 literal `main`으로 복구한다.
