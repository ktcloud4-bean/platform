"""성공한 AttachRolePolicy만 Slack human-in-the-loop 경계 위반으로 알린다."""

import boto3
import json
import os
import urllib.request


secrets = boto3.client("secretsmanager", region_name=os.environ["SECRETS_REGION"])


def _token():
    if not os.environ.get("SLACK_CHANNEL_ID"):
        raise RuntimeError("SLACK_CHANNEL_ID is not configured")
    result = secrets.get_secret_value(SecretId=os.environ["SLACK_SECRET_ARN"])
    token = json.loads(result["SecretString"]).get("bot_token")
    if not token:
        raise RuntimeError("Slack bot token is unavailable")
    return token


def _username(identity):
    arn = identity.get("arn", "")
    if ":assumed-role/" in arn:
        return arn.rsplit("/", 1)[-1]
    return identity.get("principalId", "unknown")


def handler(event, context):
    detail = event["detail"]
    request = detail["requestParameters"]
    role_name = request["roleName"]
    policy_arn = request["policyArn"]
    username = _username(detail.get("userIdentity", {}))
    value = json.dumps(
        {
            "event_id": detail.get("eventID", context.aws_request_id),
            "role_name": role_name,
            "policy_arn": policy_arn,
            "username": username,
        }
    )
    payload = {
        "channel": os.environ["SLACK_CHANNEL_ID"],
        "text": f"Permission boundary violation: {role_name}",
        "blocks": [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (
                        "*Permission boundary violation*\n"
                        f"Role: `{role_name}`\nPolicy: `{policy_arn.rsplit('/', 1)[-1]}`\n"
                        f"Actor session: `{username}`\n"
                        "The event matched a successful AttachRolePolicy call only."
                    ),
                },
            },
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "Detach and revoke sessions"},
                        "style": "danger",
                        "action_id": "lock_account_risk",
                        "value": value,
                        "confirm": {
                            "title": {"type": "plain_text", "text": "Revoke active sessions?"},
                            "text": {"type": "plain_text", "text": "This detaches the policy and closes current AWS and Keycloak sessions."},
                            "confirm": {"type": "plain_text", "text": "Revoke"},
                            "deny": {"type": "plain_text", "text": "Cancel"},
                        },
                    },
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "Acknowledge exception"},
                        "action_id": "approve_exception_risk",
                        "value": value,
                    },
                ],
            },
        ],
    }
    request = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps(payload).encode(),
        headers={"Authorization": f"Bearer {_token()}", "Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        if not json.loads(response.read()).get("ok"):
            raise RuntimeError("Slack chat.postMessage failed")
    return {"statusCode": 200, "result": "alerted"}
