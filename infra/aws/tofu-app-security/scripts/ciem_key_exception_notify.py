"""미사용 IAM access key를 사람 승인 Slack 버튼으로만 처리한다."""

import boto3
import json
import os
import urllib.request
from datetime import datetime, timezone


iam = boto3.client("iam")
secrets = boto3.client("secretsmanager")


def _slack_bot_token():
    if not os.environ.get("SLACK_CHANNEL_ID"):
        raise RuntimeError("SLACK_CHANNEL_ID is not configured")
    value = secrets.get_secret_value(SecretId=os.environ["SLACK_SECRET_ARN"])
    token = json.loads(value["SecretString"]).get("bot_token")
    if not token:
        raise RuntimeError("Slack bot token is unavailable")
    return token


def _days_since(when):
    if when is None:
        return 99999
    return (datetime.now(timezone.utc) - when).days


def _owner(username):
    for tag in iam.list_user_tags(UserName=username).get("Tags", []):
        if tag["Key"] == "Owner":
            return tag["Value"]
    return "unassigned"


def _post(token, username, key_id, age_days, last_used_days):
    payload = {
        "channel": os.environ["SLACK_CHANNEL_ID"],
        "text": f"Unused IAM access key: {username}/{key_id}",
        "blocks": [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (
                        "*Unused IAM access key*\n"
                        f"User: `{username}`\nKey: `{key_id}`\n"
                        f"Owner: {_owner(username)}\n"
                        f"Age: {age_days}d / last used: {last_used_days}d\n"
                        "No automatic deletion is performed."
                    ),
                },
            },
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "Keep exception"},
                        "action_id": "keep_access_key",
                        "value": json.dumps({"username": username, "key_id": key_id}),
                    },
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "Disable and delete"},
                        "style": "danger",
                        "action_id": "revoke_access_key",
                        "value": json.dumps({"username": username, "key_id": key_id}),
                        "confirm": {
                            "title": {"type": "plain_text", "text": "Delete access key?"},
                            "text": {"type": "plain_text", "text": "This disables and deletes the selected key."},
                            "confirm": {"type": "plain_text", "text": "Delete"},
                            "deny": {"type": "plain_text", "text": "Cancel"},
                        },
                    },
                ],
            },
        ],
    }
    request = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        if not json.loads(response.read()).get("ok"):
            raise RuntimeError("Slack chat.postMessage failed")


def handler(event, context):
    token = _slack_bot_token()
    threshold = int(os.environ["UNUSED_DAYS"])
    checked = flagged = service_keys_excluded = 0

    for page in iam.get_paginator("list_users").paginate():
        for user in page["Users"]:
            # 장기 key가 필요한 네 /service/ identity는 CIEM 사람용 key 검토 대상이 아니다.
            if user["Path"].startswith("/service/"):
                service_keys_excluded += len(iam.list_access_keys(UserName=user["UserName"]).get("AccessKeyMetadata", []))
                continue
            for key in iam.list_access_keys(UserName=user["UserName"]).get("AccessKeyMetadata", []):
                checked += 1
                key_id = key["AccessKeyId"]
                age_days = _days_since(key["CreateDate"])
                last_used = iam.get_access_key_last_used(AccessKeyId=key_id).get("AccessKeyLastUsed", {}).get("LastUsedDate")
                last_used_days = _days_since(last_used)
                # 키가 오래됐다는 이유만으로는 후보로 올리지 않는다. 최근에
                # 사용된 키의 삭제 여부는 마지막 사용 시점(미사용이면 99999일)을
                # 기준으로 판정해 정상적인 장기 키를 보존한다.
                if last_used_days >= threshold:
                    flagged += 1
                    _post(token, user["UserName"], key_id, age_days, last_used_days)

    return {
        "statusCode": 200,
        "checked": checked,
        "flagged": flagged,
        "service_keys_excluded": service_keys_excluded,
        "basis": "GetAccessKeyLastUsed",
    }
