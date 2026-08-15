"""CloudTrail 기반 SAML reader role 권한 드리프트를 사람 검토용으로 알린다."""

import boto3
import json
import os
import time
import urllib.request
from datetime import datetime, timedelta, timezone


access_analyzer = boto3.client("accessanalyzer")
iam = boto3.client("iam")
secrets = boto3.client("secretsmanager")


def _actions(document):
    actions = set()
    for statement in document.get("Statement", []):
        values = statement.get("Action", [])
        if isinstance(values, str):
            values = [values]
        actions.update(value for value in values if isinstance(value, str))
    return actions


def _current_actions(role_name):
    actions = set()
    for policy_name in iam.list_role_policies(RoleName=role_name).get("PolicyNames", []):
        actions.update(_actions(iam.get_role_policy(RoleName=role_name, PolicyName=policy_name)["PolicyDocument"]))
    return actions


def _slack_token():
    if not os.environ.get("SLACK_CHANNEL_ID"):
        raise RuntimeError("SLACK_CHANNEL_ID is not configured")
    result = secrets.get_secret_value(SecretId=os.environ["SLACK_SECRET_ARN"])
    token = json.loads(result["SecretString"]).get("bot_token")
    if not token:
        raise RuntimeError("Slack bot token is unavailable")
    return token


def _post(token, role_name, job_id, unused_actions):
    preview = "\n".join(f"• `{action}`" for action in sorted(unused_actions)[:30])
    payload = {
        "channel": os.environ["SLACK_CHANNEL_ID"],
        "text": f"CIEM permission drift review: {role_name}",
        "blocks": [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (
                        f"*CIEM permission drift review*\nRole: `{role_name}`\n"
                        f"CloudTrail-observed policy has not used these current inline permissions during the configured period:\n{preview}\n"
                        "The IAM declaration is not changed automatically. Review the IaC owner before changing a policy."
                    ),
                },
            },
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "Acknowledge review"},
                        "action_id": "acknowledge_permission_drift",
                        "value": json.dumps({"role_name": role_name, "job_id": job_id}),
                    }
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
    role_name = event["role_name"]
    account_id = boto3.client("sts").get_caller_identity()["Account"]
    role_arn = f"arn:aws:iam::{account_id}:role/{role_name}"
    end = datetime.now(timezone.utc)
    start = end - timedelta(days=int(os.environ["LOOKBACK_DAYS"]))
    response = access_analyzer.start_policy_generation(
        policyGenerationDetails={"principalArn": role_arn},
        cloudTrailDetails={
            "trails": [{"cloudTrailArn": os.environ["CLOUDTRAIL_ARN"], "allRegions": True}],
            "accessRole": os.environ["ACCESS_ANALYZER_ROLE_ARN"],
            "startTime": start,
            "endTime": end,
        },
    )
    job_id = response["jobId"]
    deadline = time.monotonic() + 480
    generated = None
    while time.monotonic() < deadline:
        generated = access_analyzer.get_generated_policy(jobId=job_id)
        status = generated.get("jobDetails", {}).get("status")
        if status == "SUCCEEDED":
            break
        if status in {"FAILED", "CANCELED"}:
            raise RuntimeError(f"policy generation {status}")
        time.sleep(10)
    else:
        raise RuntimeError("policy generation timed out")

    policies = generated.get("generatedPolicyResult", {}).get("generatedPolicies", [])
    if not policies:
        return {"statusCode": 200, "result": "no_activity"}
    observed = _actions(json.loads(policies[0]["policy"]))
    unused = _current_actions(role_name) - observed
    if not unused:
        return {"statusCode": 200, "result": "no_drift"}
    _post(_slack_token(), role_name, job_id, unused)
    return {"statusCode": 200, "result": "review_requested", "unused_count": len(unused)}
