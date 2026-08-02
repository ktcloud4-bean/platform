#!/usr/bin/env python3
"""REG-01 bucket bootstrap과 runtime 최소권한만 판정하는 SigV4 client."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import hmac
import http.client
import json
from pathlib import Path
import socket
import ssl
import stat
import urllib.parse
import xml.etree.ElementTree as ET


def load_env(path: Path) -> dict[str, str]:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) != 0o600:
        raise SystemExit("REG-01 env는 symlink가 아닌 mode 0600 파일이어야 한다")
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def derive_key(secret: str, date: str, region: str) -> bytes:
    def digest(key: bytes, value: str) -> bytes:
        return hmac.new(key, value.encode(), hashlib.sha256).digest()

    key = digest(("AWS4" + secret).encode(), date)
    key = digest(key, region)
    key = digest(key, "s3")
    return digest(key, "aws4_request")


def request(
    method: str,
    bucket: str,
    access: str,
    secret: str,
    ca_file: Path,
    query: str = "",
    connect_host: str | None = None,
    connect_port: int | None = None,
) -> tuple[int, bytes]:
    host, port, region = "s3.imcherry5778.xyz", 8333, "us-east-1"
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date, date = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
    uri = "/" + urllib.parse.quote(bucket, safe="")
    payload_hash = hashlib.sha256(b"").hexdigest()
    host_header = f"{host}:{port}"
    headers_text = f"host:{host_header}\nx-amz-content-sha256:{payload_hash}\nx-amz-date:{amz_date}\n"
    signed = "host;x-amz-content-sha256;x-amz-date"
    canonical = "\n".join([method, uri, query, headers_text, signed, payload_hash])
    scope = f"{date}/{region}/s3/aws4_request"
    to_sign = "\n".join(
        ["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()]
    )
    signature = hmac.new(derive_key(secret, date, region), to_sign.encode(), hashlib.sha256).hexdigest()
    headers = {
        "Authorization": (
            f"AWS4-HMAC-SHA256 Credential={access}/{scope},"
            f"SignedHeaders={signed},Signature={signature}"
        ),
        "Host": host_header,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    context = ssl.create_default_context(cafile=str(ca_file))
    connection = http.client.HTTPSConnection(host, port, context=context, timeout=15)
    if connect_host is not None:
        def connect() -> None:
            raw = socket.create_connection((connect_host, connect_port or port), timeout=15)
            connection.sock = context.wrap_socket(raw, server_hostname=host)
        connection.connect = connect  # type: ignore[method-assign]
    target = uri + ("?" + query if query else "")
    connection.request(method, target, headers=headers)
    response = connection.getresponse()
    return response.status, response.read()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--env-file", type=Path, required=True)
    parser.add_argument("--ca-file", type=Path, required=True)
    parser.add_argument("--connect-host")
    parser.add_argument("--connect-port", type=int)
    parser.add_argument("operation", choices=("create", "head", "deny-other", "inventory"))
    args = parser.parse_args()
    values = load_env(args.env_file)
    if args.operation == "create":
        status, _ = request(
            "PUT",
            "harbor-registry",
            values["HARBOR_S3_BOOTSTRAP_ACCESS_KEY"],
            values["HARBOR_S3_BOOTSTRAP_SECRET_KEY"],
            args.ca_file,
            connect_host=args.connect_host,
            connect_port=args.connect_port,
        )
        expected = {200, 409}
    elif args.operation == "head":
        status, _ = request(
            "HEAD",
            "harbor-registry",
            values["HARBOR_S3_ACCESS_KEY"],
            values["HARBOR_S3_SECRET_KEY"],
            args.ca_file,
            connect_host=args.connect_host,
            connect_port=args.connect_port,
        )
        expected = {200}
    elif args.operation == "deny-other":
        status, _ = request(
            "GET",
            "bkp-02-velero",
            values["HARBOR_S3_ACCESS_KEY"],
            values["HARBOR_S3_SECRET_KEY"],
            args.ca_file,
            connect_host=args.connect_host,
            connect_port=args.connect_port,
        )
        expected = {403}
    else:
        status, body = request(
            "GET",
            "harbor-registry",
            values["HARBOR_S3_ACCESS_KEY"],
            values["HARBOR_S3_SECRET_KEY"],
            args.ca_file,
            "list-type=2",
            connect_host=args.connect_host,
            connect_port=args.connect_port,
        )
        if status != 200:
            raise SystemExit(f"REG-01 S3 inventory: unexpected HTTP {status}")
        root = ET.fromstring(body)
        if (root.findtext(".//{*}IsTruncated") or "false").lower() == "true":
            raise SystemExit("REG-01 S3 inventory pagination은 이번 소규모 검증 범위를 벗어난다")
        objects = []
        for item in root.findall(".//{*}Contents"):
            objects.append(
                (
                    item.findtext("{*}Key") or "",
                    item.findtext("{*}ETag") or "",
                    int(item.findtext("{*}Size") or "0"),
                )
            )
        digest = hashlib.sha256(
            "\n".join(f"{key}\t{etag}\t{size}" for key, etag, size in sorted(objects)).encode()
        ).hexdigest()
        print(json.dumps({"objects": len(objects), "bytes": sum(x[2] for x in objects), "sha256": digest}))
        return
    if status not in expected:
        raise SystemExit(f"REG-01 S3 {args.operation}: unexpected HTTP {status}")
    print(f"REG-01 S3 {args.operation}: HTTP {status}")


if __name__ == "__main__":
    main()
