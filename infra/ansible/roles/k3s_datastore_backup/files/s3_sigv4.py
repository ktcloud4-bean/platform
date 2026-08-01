#!/usr/bin/env python3
"""의존성 없이 사용하는 제한된 S3 SigV4 client library.

BKP-01은 bucket 하나의 create/versioning과 backup object PUT/GET/HEAD/LIST만
필요하다. credential이나 응답 본문을 예외 메시지에 포함하지 않는다.
"""

from __future__ import annotations

import datetime as dt
import hashlib
import hmac
import http.client
import ssl
import urllib.parse
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path


class S3Error(RuntimeError):
    """비밀이나 응답 본문을 포함하지 않는 S3 오류."""


@dataclass(frozen=True)
class Endpoint:
    host: str
    port: int
    region: str
    ca_file: Path


@dataclass(frozen=True)
class Identity:
    access_key: str
    secret_key: str


@dataclass(frozen=True)
class Response:
    status: int
    headers: dict[str, str]
    body: bytes


def _hmac_sha256(key: bytes, value: str) -> bytes:
    return hmac.new(key, value.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret: str, date: str, region: str) -> bytes:
    date_key = _hmac_sha256(("AWS4" + secret).encode("utf-8"), date)
    region_key = _hmac_sha256(date_key, region)
    service_key = _hmac_sha256(region_key, "s3")
    return _hmac_sha256(service_key, "aws4_request")


def _quote(value: str, *, safe: str = "") -> str:
    return urllib.parse.quote(value, safe=safe)


class S3Client:
    def __init__(self, endpoint: Endpoint, identity: Identity) -> None:
        if not endpoint.host or endpoint.port < 1 or endpoint.port > 65535:
            raise ValueError("유효한 S3 endpoint가 필요합니다")
        if len(identity.access_key) < 16 or len(identity.secret_key) < 32:
            raise ValueError("최소 길이를 충족한 S3 credential이 필요합니다")
        self.endpoint = endpoint
        self.identity = identity
        self.context = ssl.create_default_context(cafile=str(endpoint.ca_file))

    def request(
        self,
        method: str,
        bucket: str,
        *,
        key: str | None = None,
        query: list[tuple[str, str]] | None = None,
        body: bytes = b"",
        content_type: str | None = None,
    ) -> Response:
        parameters = sorted(query or [])
        canonical_query = urllib.parse.urlencode(parameters, quote_via=urllib.parse.quote)
        canonical_uri = "/" + _quote(bucket)
        if key is not None:
            canonical_uri += "/" + _quote(key, safe="/")

        now = dt.datetime.now(dt.timezone.utc)
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        date = now.strftime("%Y%m%d")
        host_header = f"{self.endpoint.host}:{self.endpoint.port}"
        payload_hash = hashlib.sha256(body).hexdigest()

        headers_to_sign = {
            "host": host_header,
            "x-amz-content-sha256": payload_hash,
            "x-amz-date": amz_date,
        }
        if content_type is not None:
            headers_to_sign["content-type"] = content_type
        signed_names = ";".join(sorted(headers_to_sign))
        canonical_headers = "".join(
            f"{name}:{headers_to_sign[name].strip()}\n" for name in sorted(headers_to_sign)
        )
        canonical_request = "\n".join(
            [method, canonical_uri, canonical_query, canonical_headers, signed_names, payload_hash]
        )
        scope = f"{date}/{self.endpoint.region}/s3/aws4_request"
        string_to_sign = "\n".join(
            [
                "AWS4-HMAC-SHA256",
                amz_date,
                scope,
                hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
            ]
        )
        signature = hmac.new(
            _signing_key(self.identity.secret_key, date, self.endpoint.region),
            string_to_sign.encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()
        headers = {
            "Authorization": (
                "AWS4-HMAC-SHA256 "
                f"Credential={self.identity.access_key}/{scope},"
                f"SignedHeaders={signed_names},Signature={signature}"
            ),
            "Host": host_header,
            "x-amz-content-sha256": payload_hash,
            "x-amz-date": amz_date,
        }
        if content_type is not None:
            headers["Content-Type"] = content_type

        target = canonical_uri + ("?" + canonical_query if canonical_query else "")
        connection = http.client.HTTPSConnection(
            self.endpoint.host,
            self.endpoint.port,
            context=self.context,
            timeout=60,
        )
        try:
            connection.request(method, target, body=body, headers=headers)
            raw = connection.getresponse()
            response = Response(
                status=raw.status,
                headers={name.lower(): value for name, value in raw.getheaders()},
                body=raw.read(),
            )
        finally:
            connection.close()
        return response

    @staticmethod
    def require(response: Response, expected: set[int], action: str) -> Response:
        if response.status not in expected:
            raise S3Error(f"S3 {action} 실패: HTTP {response.status} (응답 본문 미출력)")
        return response

    def create_bucket(self, bucket: str) -> Response:
        return self.require(self.request("PUT", bucket), {200}, "bucket create")

    def enable_versioning(self, bucket: str) -> Response:
        body = (
            b'<?xml version="1.0" encoding="UTF-8"?>'
            b'<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
            b"<Status>Enabled</Status></VersioningConfiguration>"
        )
        return self.require(
            self.request(
                "PUT",
                bucket,
                query=[("versioning", "")],
                body=body,
                content_type="application/xml",
            ),
            {200},
            "versioning enable",
        )

    def get_versioning(self, bucket: str) -> str:
        response = self.require(
            self.request("GET", bucket, query=[("versioning", "")]),
            {200},
            "versioning get",
        )
        try:
            root = ET.fromstring(response.body)
        except ET.ParseError as error:
            raise S3Error("S3 versioning XML parsing 실패 (응답 본문 미출력)") from error
        status = root.findtext(".//{*}Status") or ""
        if status not in {"Enabled", "Suspended"}:
            raise S3Error("S3 versioning 상태가 없거나 알 수 없음 (응답 본문 미출력)")
        return status

    def head_bucket(self, bucket: str) -> Response:
        return self.require(self.request("HEAD", bucket), {200}, "bucket head")

    def delete_bucket(self, bucket: str) -> Response:
        return self.require(self.request("DELETE", bucket), {200, 204}, "bucket delete")

    def put_object(self, bucket: str, key: str, body: bytes) -> Response:
        return self.require(
            self.request("PUT", bucket, key=key, body=body),
            {200},
            "object put",
        )

    def get_object(self, bucket: str, key: str) -> bytes:
        return self.require(
            self.request("GET", bucket, key=key),
            {200},
            "object get",
        ).body

    def head_object(self, bucket: str, key: str) -> Response:
        return self.require(self.request("HEAD", bucket, key=key), {200}, "object head")

    def list_objects(self, bucket: str, prefix: str) -> list[tuple[str, int]]:
        response = self.require(
            self.request(
                "GET",
                bucket,
                query=[("list-type", "2"), ("prefix", prefix)],
            ),
            {200},
            "object list",
        )
        root = ET.fromstring(response.body)
        if (root.findtext(".//{*}IsTruncated") or "false").lower() == "true":
            raise S3Error("S3 list 결과가 pagination되어 안전하게 중단합니다")
        objects: list[tuple[str, int]] = []
        for content in root.findall(".//{*}Contents"):
            key = content.findtext("{*}Key")
            size = content.findtext("{*}Size")
            if key is None or size is None:
                raise S3Error("S3 list 응답에 key 또는 size가 없습니다")
            objects.append((key, int(size)))
        return objects
