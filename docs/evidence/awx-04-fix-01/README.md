# AWX-04-FIX-01 완료 증거

실패 원인은 `AWX-04 platform 운영 원본`의 project update가 Vault AppRole login HTTP 400으로
중단된 것이었다. 보정은 `kv/awx/scm-lookup`의 `vault_role_id`·`vault_secret_id`만 canonical
Role ID와 새 Secret ID로 교체한다. private deploy key·host key·AppRole 값은 출력하거나 Git에
기록하지 않는다.

- `refresh-scm-lookup.sh --check`은 새 AppRole로 `kv/awx/scm`의 deploy key read 권한만
  판정한다.
- 과거 immutable SHA의 동기화 operation이 남은 경우에는 `recover-main`이 그 operation만
  `Terminating`으로 끝내고, 선언된 automated sync가 literal `main`으로 다시 수렴하게 한다.
  이어 SCM project update 성공과 fixed `scm_revision`을 판정한다.
- 최종 root/AWX는 literal `main`, `Synced/Healthy`이며 EE·RBAC·PVC·OPNsense는 변경하지 않는다.

## 실행 결과

- AppRole lookup check가 deploy key read 권한을 통과했다. 값 원문은 출력하지 않았다.
- AWX-05의 stale operation을 `Terminating`으로 끝낸 뒤 latest main automated sync가 수렴했다.
- SCM project update `55`가 성공했고 root/AWX는 같은 latest main SHA에서 `Synced/Healthy`다.
