#!/usr/bin/env python3
"""CI-01의 사람 입력 파일 하나를 저장소 밖에 mode 0600으로 만든다.

Jenkins local 복구 admin 암호만 사람이 보관한다. Gitea deploy key, Harbor robot
credential과 pinned host key는 provision.sh가 만들어 Vault로 직접 옮기며 이 파일에
남기지 않는다. 값은 출력하지 않는다.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
from secrets import token_hex


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    target = args.output
    if target.exists() or target.is_symlink():
        raise SystemExit(f"이미 존재한다. 기존 입력을 덮어쓰지 않는다: {target}")
    target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)

    body = "\n".join(
        [
            "# CI-01 Jenkins 사람 입력. 이 파일 하나만 사람이 보관한다.",
            f"JENKINS_ADMIN_PASSWORD={token_hex(32)}",
            "",
        ]
    )
    descriptor = os.open(target, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(body)
    print(f"CI-01 입력 생성 완료: {target} (mode 0600, key 1개)")


if __name__ == "__main__":
    main()
