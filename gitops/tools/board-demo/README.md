# BOARD-DEMO-01 GitHub source mirror

`provision-mirror.sh`는 GitHub `ktcloud4-bean/board-app`의 private pull-mirror를
Gitea `ktcloud4-bean/board-app`에 만든다. GitHub 조직 전체의 자동 mirror는 만들지 않고,
선언한 저장소 하나만 소유한다.

입력은 저장소 밖 `/home/imcherry/secrets/ktcloud4-bean/gitea-github-mirror.env`의
호출자 소유 mode `0600` 파일이다. 다음 한 줄 외 다른 활성 값은 허용하지 않는다.

```text
GITHUB_MIRROR_TOKEN=github_pat_...
```

토큰은 GitHub `ktcloud4-bean/board-app`만 선택하고 `Contents: Read-only`로 제한한다.
도구는 값을 출력하지 않으며, Gitea에는 private mirror 인증으로만 전달한다.

```bash
gitops/tools/board-demo/provision-mirror.sh --check
gitops/tools/board-demo/provision-mirror.sh --apply
```

`--apply`는 Gitea의 `ktcloud4-bean` 로컬 조직이 없을 때만 만들고, repository가 없을 때만
30분 주기의 pull-mirror를 만든다. 이미 존재하는 객체는 private·mirror·원본 URL이 모두
일치할 때만 사용하며, 즉시 sync한 GitHub/Gitea `main` SHA가 같아야 성공한다.
