# DEMO-ONPREM-01 실행기

네 세션은 같은 진입점으로 `attack`, `control`, `evidence`, `reset`만 실행한다.

```bash
gitops/tools/demo-onprem/demo.sh session1 attack
gitops/tools/demo-onprem/demo.sh session1 control
gitops/tools/demo-onprem/demo.sh session1 evidence
gitops/tools/demo-onprem/demo.sh session1 reset
```

`session1`을 `session2`~`session4`로 바꾸면 같은 순서로 실행된다. 전체 라이브 판정은
`verify-immutable-argo.py`가 immutable commit SHA에 root와 변경 child를 고정한 동안 이
명령만 순서대로 호출한다. Session 3 `evidence`는 Shuffle의 실제 사람 입력에서 멈추며,
자동으로 Continue/Stop을 누르거나 승인 URL을 출력하지 않는다.

보호 입력은 `/home/imcherry/secrets/ktcloud4-bean` 아래 mode `0600` 파일만 읽는다. 계정
비밀번호·TOTP, cookie, token, hook URL, SQL query 원문은 출력하지 않는다.
