"""Slack HTTP callback: validate and enqueue only, never perform the action inline."""

import base64
import boto3
import hashlib
import hmac
import json
import os
import time
import urllib.parse


secrets = boto3.client("secretsmanager")
lambda_client = boto3.client("lambda")
ALLOWED_ACTIONS = {
    "keep_access_key",
    "revoke_access_key",
    "acknowledge_permission_drift",
    "lock_account_risk",
    "approve_exception_risk",
}


def _response(status, body):
    return {"statusCode": status, "body": body, "headers": {"Content-Type": "text/plain; charset=utf-8"}}


def _signing_secret():
    try:
        result = secrets.get_secret_value(SecretId=os.environ["SLACK_SECRET_ARN"])
        secret = json.loads(result["SecretString"]).get("signing_secret")
    except Exception:
        # 시크릿 미주입·권한 오류·형식 오류 모두 action 전에 fail closed한다.
        return None
    return secret or None


def _valid_signature(headers, body):
    timestamp = headers.get("x-slack-request-timestamp", "")
    signature = headers.get("x-slack-signature", "")
    try:
        timestamp_number = int(timestamp)
    except (TypeError, ValueError):
        return False
    if abs(time.time() - timestamp_number) > 300:
        return False
    signing_secret = _signing_secret()
    if signing_secret is None:
        return False
    expected = "v0=" + hmac.new(
        signing_secret.encode(), f"v0:{timestamp}:{body}".encode(), hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, signature)


def _idempotency_key(payload, action):
    container = payload.get("container") or {}
    stable = {
        "action_id": action["action_id"],
        "user_id": payload["user"]["id"],
        "message_ts": container.get("message_ts", ""),
        "value": action.get("value", ""),
    }
    return hashlib.sha256(json.dumps(stable, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def handler(event, context):
    headers = {key.lower(): value for key, value in (event.get("headers") or {}).items()}
    body = event.get("body") or ""
    try:
        if event.get("isBase64Encoded"):
            body = base64.b64decode(body).decode("utf-8")
    except Exception:
        return _response(400, "invalid body")

    # 비밀이 아직 외부 주입되지 않았거나 서명이 틀리면 어떤 action도 큐잉하지 않는다.
    if not _valid_signature(headers, body):
        return _response(401, "invalid signature")

    try:
        form = urllib.parse.parse_qs(body, strict_parsing=True)
        payload = json.loads(form["payload"][0])
        action = payload["actions"][0]
        action_id = action["action_id"]
        value = json.loads(action["value"])
        user = payload["user"]
        response_url = payload["response_url"]
    except (IndexError, KeyError, TypeError, ValueError):
        return _response(400, "invalid Slack action")

    allowed_users = set(json.loads(os.environ["ALLOWED_USER_IDS_JSON"]))
    if user.get("id") not in allowed_users:
        return _response(403, "unauthorized Slack user")
    if action_id not in ALLOWED_ACTIONS:
        return _response(400, "unsupported action")

    work = {
        "action_id": action_id,
        "value": value,
        "approver_id": user["id"],
        "approver_name": user.get("username") or user["id"],
        "response_url": response_url,
        "action_key": _idempotency_key(payload, action),
    }
    try:
        lambda_client.invoke(
            FunctionName=os.environ["EXECUTOR_FUNCTION"],
            InvocationType="Event",
            Payload=json.dumps(work).encode(),
        )
    except Exception:
        # Slack에 성공 응답을 주면 재시도 기회를 잃으므로 장애를 명시적으로 반환한다.
        raise
    return _response(200, "accepted")
