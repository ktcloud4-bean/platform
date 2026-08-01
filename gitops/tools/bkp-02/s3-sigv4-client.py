#!/usr/bin/env python3
"""stdlib만으로 전용 SeaweedFS S3 bucket을 검증하는 제한된 SigV4 client."""

from __future__ import annotations

import argparse
import datetime
import hashlib
import hmac
import http.client
import json
import ssl
import sys
import urllib.parse
import xml.etree.ElementTree as ET


def hmac_sha256(key: bytes, value: str) -> bytes:
    return hmac.new(key, value.encode(), hashlib.sha256).digest()


def signing_key(secret: str, date: str, region: str) -> bytes:
    key_date = hmac_sha256(("AWS4" + secret).encode(), date)
    key_region = hmac_sha256(key_date, region)
    key_service = hmac_sha256(key_region, "s3")
    return hmac_sha256(key_service, "aws4_request")


def signed_request(
    method: str,
    canonical_uri: str,
    parameters: list[tuple[str, str]],
    identity: dict[str, str],
    host: str,
    port: int,
    region: str,
    context: ssl.SSLContext,
) -> tuple[int, bytes]:
    canonical_query = urllib.parse.urlencode(parameters, quote_via=urllib.parse.quote)
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date = now.strftime("%Y%m%dT%H%M%SZ")
    date = now.strftime("%Y%m%d")
    host_header = f"{host}:{port}"
    payload_hash = hashlib.sha256(b"").hexdigest()
    canonical_headers = (
        f"host:{host_header}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amz_date}\n"
    )
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = "\n".join(
        [method, canonical_uri, canonical_query, canonical_headers, signed_headers, payload_hash]
    )
    scope = f"{date}/{region}/s3/aws4_request"
    string_to_sign = "\n".join(
        ["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical_request.encode()).hexdigest()]
    )
    signature = hmac.new(
        signing_key(identity["secret_key"], date, region),
        string_to_sign.encode(),
        hashlib.sha256,
    ).hexdigest()
    headers = {
        "Authorization": (
            "AWS4-HMAC-SHA256 "
            f"Credential={identity['access_key']}/{scope},"
            f"SignedHeaders={signed_headers},Signature={signature}"
        ),
        "Host": host_header,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amz_date,
    }
    connection = http.client.HTTPSConnection(host, port, context=context, timeout=30)
    request_target = canonical_uri + ("?" + canonical_query if canonical_query else "")
    connection.request(method, request_target, body=b"", headers=headers)
    response = connection.getresponse()
    return response.status, response.read()


def list_objects(
    bucket: str,
    prefix: str,
    identity: dict[str, str],
    host: str,
    port: int,
    region: str,
    context: ssl.SSLContext,
) -> list[tuple[str, int]]:
    uri = "/" + urllib.parse.quote(bucket, safe="")
    status, body = signed_request(
        "GET", uri, [("list-type", "2"), ("prefix", prefix)], identity, host, port, region, context
    )
    if status != 200:
        raise SystemExit(f"S3 list 실패: HTTP {status} (응답 본문 미출력)")
    root = ET.fromstring(body)
    if (root.findtext(".//{*}IsTruncated") or "false").lower() == "true":
        raise SystemExit("S3 list 결과가 pagination되어 안전하게 중단합니다")
    objects: list[tuple[str, int]] = []
    for content in root.findall(".//{*}Contents"):
        key = content.findtext("{*}Key")
        size = content.findtext("{*}Size")
        if key is None or size is None:
            raise SystemExit("S3 list 응답에 key 또는 size가 없습니다")
        objects.append((key, int(size)))
    return objects


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--operation", choices=("create", "head", "list", "delete", "delete-prefix"), required=True
    )
    parser.add_argument("--identity", choices=("bootstrap", "velero"), required=True)
    parser.add_argument("--host", default="s3.imcherry5778.xyz")
    parser.add_argument("--port", type=int, default=8333)
    parser.add_argument("--region", default="us-east-1")
    parser.add_argument("--ca-file", required=True)
    parser.add_argument("--prefix", default="")
    parser.add_argument("--expected-objects", type=int)
    parser.add_argument("--expected-bytes", type=int)
    args = parser.parse_args()

    source = json.load(sys.stdin)
    identity = source[args.identity]
    bucket = source["bucket"]
    context = ssl.create_default_context(cafile=args.ca_file)

    if args.operation in ("list", "delete-prefix"):
        objects = list_objects(
            bucket, args.prefix, identity, args.host, args.port, args.region, context
        )
        total_bytes = sum(size for _, size in objects)
        if args.operation == "list":
            print(
                json.dumps(
                    {"bucket": bucket, "prefix": args.prefix, "objects": len(objects), "bytes": total_bytes}
                )
            )
            return

        allowed_prefix = "cluster-k3s-01/kopia/bkp-02-restore-test/"
        if args.identity != "velero" or args.prefix != allowed_prefix:
            raise SystemExit("delete-prefix는 BKP-02 test Kopia prefix와 final identity만 허용합니다")
        if args.expected_objects is None or args.expected_bytes is None:
            raise SystemExit("delete-prefix에는 expected object 수와 byte가 필요합니다")
        if len(objects) != args.expected_objects or total_bytes != args.expected_bytes:
            raise SystemExit("delete-prefix 사전 object 수 또는 byte가 승인한 값과 다릅니다")
        for key, _ in objects:
            uri = "/" + urllib.parse.quote(bucket, safe="") + "/" + urllib.parse.quote(key, safe="/")
            status, _ = signed_request(
                "DELETE", uri, [], identity, args.host, args.port, args.region, context
            )
            if status not in (200, 204):
                raise SystemExit(f"S3 object delete 실패: HTTP {status} (key 미출력)")
        remaining = list_objects(
            bucket, args.prefix, identity, args.host, args.port, args.region, context
        )
        if remaining:
            raise SystemExit("delete-prefix 뒤 object가 남았습니다")
        print(
            json.dumps(
                {
                    "bucket": bucket,
                    "prefix": args.prefix,
                    "deleted_objects": len(objects),
                    "deleted_bytes": total_bytes,
                    "remaining_objects": 0,
                }
            )
        )
        return

    methods = {"create": "PUT", "head": "HEAD", "list": "GET", "delete": "DELETE"}
    method = methods[args.operation]
    canonical_uri = "/" + urllib.parse.quote(bucket, safe="")
    status, _ = signed_request(
        method, canonical_uri, [], identity, args.host, args.port, args.region, context
    )
    expected = {"create": {200}, "head": {200}, "delete": {200, 204}}
    if status not in expected[args.operation]:
        raise SystemExit(f"S3 {args.operation} 실패: HTTP {status} (응답 본문 미출력)")
    print(json.dumps({"bucket": bucket, "operation": args.operation, "status": status}))


if __name__ == "__main__":
    main()
