#!/usr/bin/env python3
"""BKP-01 bootstrap·복원 검증용 제한된 S3 CLI."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path
from types import ModuleType


def load_library() -> ModuleType:
    candidates = [
        Path(__file__).with_name("s3_sigv4.py"),
        Path(__file__).parents[2]
        / "roles"
        / "k3s_datastore_backup"
        / "files"
        / "s3_sigv4.py",
    ]
    library = next((path for path in candidates if path.is_file()), None)
    if library is None:
        raise SystemExit("s3_sigv4.py를 찾을 수 없습니다")
    specification = importlib.util.spec_from_file_location("bkp01_s3_sigv4", library)
    if specification is None or specification.loader is None:
        raise SystemExit("s3_sigv4.py import specification 생성 실패")
    module = importlib.util.module_from_spec(specification)
    sys.modules[specification.name] = module
    specification.loader.exec_module(module)
    return module


def read_config(path: str) -> dict[str, object]:
    if path == "-":
        return json.load(sys.stdin)
    source = Path(path)
    if source.stat().st_mode & 0o077:
        raise SystemExit("BKP-01 credential config는 mode 0600이어야 합니다")
    with source.open(encoding="utf-8") as stream:
        return json.load(stream)


def write_exclusive(path: Path, body: bytes) -> None:
    descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(body)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--operation",
        choices=(
            "create-bucket",
            "enable-versioning",
            "get-versioning",
            "head-bucket",
            "delete-bucket",
            "put-object",
            "get-object",
            "head-object",
            "list-objects",
        ),
        required=True,
    )
    parser.add_argument("--config", default="-")
    parser.add_argument("--identity", choices=("bootstrap", "backup"), required=True)
    parser.add_argument("--ca-file", type=Path)
    parser.add_argument("--bucket")
    parser.add_argument("--key")
    parser.add_argument("--prefix", default="")
    parser.add_argument("--file", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    source = read_config(args.config)
    endpoint = source["endpoint"]
    identity_value = source[args.identity]
    bucket = args.bucket or source["bucket"]
    ca_file = args.ca_file
    if ca_file is None:
        raise SystemExit("--ca-file이 필요합니다")

    library = load_library()
    client = library.S3Client(
        library.Endpoint(
            host=endpoint["host"],
            port=int(endpoint["port"]),
            region=endpoint["region"],
            ca_file=ca_file,
        ),
        library.Identity(
            access_key=identity_value["access_key"],
            secret_key=identity_value["secret_key"],
        ),
    )

    result: dict[str, object] = {"bucket": bucket, "operation": args.operation}
    if args.operation == "create-bucket":
        result["status"] = client.create_bucket(bucket).status
    elif args.operation == "enable-versioning":
        result["status"] = client.enable_versioning(bucket).status
    elif args.operation == "get-versioning":
        result.update({"status": 200, "versioning": client.get_versioning(bucket)})
    elif args.operation == "head-bucket":
        result["status"] = client.head_bucket(bucket).status
    elif args.operation == "delete-bucket":
        if args.identity != "bootstrap" or bucket != source["bucket"]:
            raise SystemExit("delete-bucket은 canonical BKP-01 bucket과 bootstrap identity만 허용합니다")
        result["status"] = client.delete_bucket(bucket).status
    elif args.operation == "put-object":
        if args.key is None or args.file is None:
            raise SystemExit("put-object에는 --key와 --file이 필요합니다")
        body = args.file.read_bytes()
        result.update(
            {
                "status": client.put_object(bucket, args.key, body).status,
                "key": args.key,
                "bytes": len(body),
                "sha256": hashlib.sha256(body).hexdigest(),
            }
        )
    elif args.operation == "get-object":
        if args.key is None or args.output is None:
            raise SystemExit("get-object에는 --key와 --output이 필요합니다")
        body = client.get_object(bucket, args.key)
        write_exclusive(args.output, body)
        result.update(
            {
                "status": 200,
                "key": args.key,
                "bytes": len(body),
                "sha256": hashlib.sha256(body).hexdigest(),
                "output": str(args.output),
            }
        )
    elif args.operation == "head-object":
        if args.key is None:
            raise SystemExit("head-object에는 --key가 필요합니다")
        response = client.head_object(bucket, args.key)
        result.update(
            {
                "status": response.status,
                "key": args.key,
                "bytes": int(response.headers.get("content-length", "0")),
                "version_id_present": "x-amz-version-id" in response.headers,
            }
        )
    elif args.operation == "list-objects":
        objects = client.list_objects(bucket, args.prefix)
        result.update(
            {
                "status": 200,
                "prefix": args.prefix,
                "objects": len(objects),
                "bytes": sum(size for _, size in objects),
                "keys": [key for key, _ in objects],
            }
        )
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
