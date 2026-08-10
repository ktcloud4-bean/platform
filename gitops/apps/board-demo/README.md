# Board Demo

`BOARD-DEMO-01`은 GitHub 원본을 Gitea private pull-mirror로 고정해 Jenkins가 서명한
Harbor digest 하나를 배포한다. 애플리케이션은 PostgreSQL 전용 role/database에 TLS로만
접속하며, DB credential은 Vault Agent가 메모리 볼륨에 렌더링한다.

- 외부 노출은 없다. `board.imcherry5778.xyz`는 Unbound 내부 alias이고 Pomerium
  `/platform-users`만 backend `board-demo:80`으로 전달한다.
- bootstrap Job은 별도 Vault KV에서 현재/직전 Cosign 공개키와 Harbor pull robot을 읽어 배포와
  Kyverno가 필요한 Kubernetes Secret을 생성한다. 해당 Secret 원문은 Git에 없다.
- `ImageValidatingPolicy`는 `harbor.imcherry5778.xyz/board-demo/board-app`의 Pod 생성에
  현재 또는 직전 공개키 서명을 필수로 한다.
- 기본 deny 뒤 허용하는 통신은 DNS, Vault TLS, app→`postgres-01:5432`,
  bootstrap→Kubernetes API, Pomerium server→app HTTP뿐이다.

## 운영 경계

PostgreSQL/Vault 선언과 재적용 검증은 다음 전용 entrypoint가 소유한다.

```sh
gitops/tools/board-demo/provision-runtime.sh --check
gitops/tools/board-demo/provision-runtime.sh --apply
```

내부 DNS alias는 지원 API만 쓰며, `rollback`은 이 작업이 만든 정확한 alias 한 건만
제거한다.

```sh
python3 gitops/tools/board-demo/opnsense-alias.py --env-file <mode-0600-env> check
python3 gitops/tools/board-demo/opnsense-alias.py --env-file <mode-0600-env> apply
python3 gitops/tools/board-demo/opnsense-alias.py --env-file <mode-0600-env> rollback
```

Argo immutable SHA·signed Pod/admission·Pomerium route의 완료 증거는 하나의 verifier가
판정한다. `admission`에는 Jenkins build가 남긴 signed/unsigned digest를 정확히 넣는다.

```sh
gitops/tools/board-demo/verify-live.sh argo <root-sha> <child-sha>
gitops/tools/board-demo/verify-live.sh admission <signed-digest> <unsigned-digest>
gitops/tools/board-demo/verify-live.sh route
```

`route`는 legacy `daily-*` 검증 입력을 쓰지 않는다. 마이그레이션된
`imcherry5778`의 현재 password와 TOTP seed는 저장소 밖 mode `0600` 파일
`${KTC_SECRET_ROOT:-$HOME/secrets/ktcloud4-bean}/board-demo/route-password`와
`route-totp`에 각각 두며, 경로가 다르면 `BOARD_DEMO_PASSWORD_FILE`와
`BOARD_DEMO_TOTP_FILE`로만 넘긴다. 원문은 Git·채팅·로그에 남기지 않는다.
