#!/usr/bin/env python3
"""AWS Signature Version 4로 서명한 query-protocol POST 최소 구현.

이 host에 AWS CLI나 boto3를 설치하지 않기 위해 표준 라이브러리만 쓴다. 백업 경로에
필요한 호출은 `sns:Publish`와 `monitoring:PutMetricData` 둘뿐이고, 둘 다 form
urlencoded POST 하나로 끝난다. 그 두 호출 때문에 별도 공급망을 늘리지 않는다.

자격증명은 환경변수로만 받는다. argv, 로그, 예외 메시지에 넣지 않는다.

사용법:
    aws-sigv4-post.py <service> <region> <key>=<value> [<key>=<value> ...]

예:
    aws-sigv4-post.py sns ap-northeast-2 \\
        Action=Publish Version=2010-03-31 TopicArn=... Message=...
"""

import datetime
import hashlib
import hmac
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

ALGORITHM = "AWS4-HMAC-SHA256"
CONTENT_TYPE = "application/x-www-form-urlencoded; charset=utf-8"
SIGNED_HEADERS = "content-type;host;x-amz-date"
TIMEOUT_SECONDS = 20


def _hmac_sha256(key: bytes, message: str) -> bytes:
    return hmac.new(key, message.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret: str, datestamp: str, region: str, service: str) -> bytes:
    """SigV4의 날짜·region·service 단계별 파생 키."""
    key = _hmac_sha256(("AWS4" + secret).encode("utf-8"), datestamp)
    key = _hmac_sha256(key, region)
    key = _hmac_sha256(key, service)
    return _hmac_sha256(key, "aws4_request")


def post(service: str, region: str, params: "dict[str, str]") -> "tuple[int, str]":
    access_key = os.environ.get("AWS_ACCESS_KEY_ID", "")
    secret_key = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    if not access_key or not secret_key:
        raise SystemExit("AWS_ACCESS_KEY_ID와 AWS_SECRET_ACCESS_KEY 환경변수가 필요하다")
    if os.environ.get("AWS_SESSION_TOKEN"):
        raise SystemExit("세션 토큰을 쓰는 임시 자격증명은 이 구현의 범위가 아니다")

    host = "{0}.{1}.amazonaws.com".format(service, region)
    endpoint = "https://{0}/".format(host)
    body = urllib.parse.urlencode(params).encode("utf-8")

    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")

    canonical_request = "\n".join(
        [
            "POST",
            "/",
            "",
            "content-type:" + CONTENT_TYPE,
            "host:" + host,
            "x-amz-date:" + amzdate,
            "",
            SIGNED_HEADERS,
            hashlib.sha256(body).hexdigest(),
        ]
    )

    scope = "{0}/{1}/{2}/aws4_request".format(datestamp, region, service)
    string_to_sign = "\n".join(
        [
            ALGORITHM,
            amzdate,
            scope,
            hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
        ]
    )

    signature = hmac.new(
        _signing_key(secret_key, datestamp, region, service),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()

    authorization = "{0} Credential={1}/{2}, SignedHeaders={3}, Signature={4}".format(
        ALGORITHM, access_key, scope, SIGNED_HEADERS, signature
    )

    request = urllib.request.Request(
        endpoint,
        data=body,
        method="POST",
        headers={
            "Content-Type": CONTENT_TYPE,
            "X-Amz-Date": amzdate,
            "Authorization": authorization,
        },
    )

    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        # AWS는 오류 코드를 본문에 담아 돌려준다. 자격증명은 본문에 들어가지 않는다.
        return error.code, error.read().decode("utf-8", "replace")


def main(argv: "list[str]") -> int:
    if len(argv) < 4:
        sys.stderr.write(__doc__ or "")
        return 2

    service, region = argv[1], argv[2]
    params = {}
    for item in argv[3:]:
        if "=" not in item:
            sys.stderr.write("key=value 형식이 아닌 인자: {0}\n".format(item.split("=")[0]))
            return 2
        key, value = item.split("=", 1)
        params[key] = value

    status, payload = post(service, region, params)
    sys.stdout.write(payload)
    if not payload.endswith("\n"):
        sys.stdout.write("\n")
    if status != 200:
        sys.stderr.write("AWS {0} 호출이 HTTP {1}로 실패했다\n".format(service, status))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
