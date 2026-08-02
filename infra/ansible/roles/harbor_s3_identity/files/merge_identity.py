#!/usr/bin/env python3
"""REG-01 identities만 SeaweedFS s3.json에 안전하게 병합한다."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import tempfile


CONFIG = Path("/etc/seaweedfs/s3.json")
RESERVED = {"reg-01-bucket-bootstrap", "reg-01-harbor"}


def identity(name: str, credential: dict[str, str], actions: list[str]) -> dict[str, object]:
    return {"name": name, "credentials": [credential], "actions": actions}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("check", "apply"), required=True)
    parser.add_argument("--phase", choices=("bootstrap", "final"), required=True)
    args = parser.parse_args()
    supplied = json.load(os.fdopen(0, encoding="utf-8"))
    bucket = supplied["bucket"]
    if bucket != "harbor-registry":
        raise SystemExit("unexpected REG-01 bucket")

    current = json.loads(CONFIG.read_text(encoding="utf-8"))
    current_identities = current.get("identities")
    if not isinstance(current_identities, list):
        raise SystemExit("live s3.json identities is not a list")
    preserved = [item for item in current_identities if item.get("name") not in RESERVED]

    runtime = supplied["runtime"]
    bootstrap = supplied["bootstrap"]
    desired = list(preserved)
    if args.phase == "bootstrap":
        desired.append(identity("reg-01-bucket-bootstrap", bootstrap, [f"Admin:{bucket}"]))
    desired.append(
        identity(
            "reg-01-harbor",
            runtime,
            [f"Read:{bucket}", f"List:{bucket}", f"Write:{bucket}"],
        )
    )

    preserved_keys = {
        credential.get("accessKey")
        for item in preserved
        for credential in item.get("credentials", [])
    }
    requested_keys = {runtime.get("accessKey"), bootstrap.get("accessKey")}
    if None in requested_keys or preserved_keys & requested_keys:
        raise SystemExit("REG-01 access key is missing or collides with an existing identity")
    for credential in (runtime, bootstrap):
        if len(credential.get("accessKey", "")) < 16 or len(credential.get("secretKey", "")) < 32:
            raise SystemExit("REG-01 credential does not meet minimum length")

    updated = dict(current)
    updated["identities"] = desired
    changed = updated != current
    if args.mode == "check" or not changed:
        print(f"changed={'true' if changed else 'false'} phase={args.phase}")
        return

    metadata = CONFIG.stat()
    descriptor, temporary = tempfile.mkstemp(prefix=".s3.json.reg-01-", dir=CONFIG.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(updated, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, metadata.st_mode & 0o777)
        os.chown(temporary, metadata.st_uid, metadata.st_gid)
        os.replace(temporary, CONFIG)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f"changed=true phase={args.phase}")


if __name__ == "__main__":
    main()
