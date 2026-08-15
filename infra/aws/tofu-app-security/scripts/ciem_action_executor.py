"""CIEM 승인 action executor. Slack HTTP acknowledgement 뒤 비동기로만 실행된다."""

import boto3
from botocore.exceptions import ClientError
import json
import os
import time
import urllib.request


iam = boto3.client("iam")
ddb = boto3.client("dynamodb")
secrets = boto3.client("secretsmanager")
lambda_client = boto3.client("lambda")
sns = boto3.client("sns")


def _respond(response_url, text):
    request = urllib.request.Request(
        response_url,
        data=json.dumps({"replace_original": True, "text": text}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10):
        pass


def _claim(action_key):
    now = int(time.time())
    try:
        ddb.update_item(
            TableName=os.environ["ACTION_TABLE_NAME"],
            Key={"action_key": {"S": action_key}},
            UpdateExpression="SET #state = :processing, expires_at = :expires",
            ConditionExpression="attribute_not_exists(action_key) OR #state = :failed",
            ExpressionAttributeNames={"#state": "state"},
            ExpressionAttributeValues={
                ":processing": {"S": "PROCESSING"},
                ":failed": {"S": "FAILED"},
                ":expires": {"N": str(now + 86400)},
            },
        )
        return True
    except ddb.exceptions.ConditionalCheckFailedException:
        return False


def _set_state(action_key, state):
    ddb.update_item(
        TableName=os.environ["ACTION_TABLE_NAME"],
        Key={"action_key": {"S": action_key}},
        UpdateExpression="SET #state = :state",
        ExpressionAttributeNames={"#state": "state"},
        ExpressionAttributeValues={":state": {"S": state}},
    )


def _keycloak_credentials():
    result = secrets.get_secret_value(SecretId=os.environ["KEYCLOAK_SESSION_SECRET_ARN"])
    value = json.loads(result["SecretString"])
    if not value.get("client_id") or not value.get("client_secret"):
        raise RuntimeError("Keycloak CIEM service client secret is unavailable")
    return {"client_id": value["client_id"], "client_secret": value["client_secret"]}


def _revoke_aws_sessions(username):
    issued_before = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    policy = {
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "CiemRevokeSpecificSession",
            "Effect": "Deny",
            "Action": "*",
            "Resource": "*",
            "Condition": {
                "StringLike": {"aws:userid": f"*:{username}"},
                "DateLessThan": {"aws:TokenIssueTime": issued_before},
            },
        }],
    }
    policy_name = f"ciem-revoke-session-{username}"[:128]
    for role_name in json.loads(os.environ["SAML_ROLE_NAMES_JSON"]):
        iam.put_role_policy(RoleName=role_name, PolicyName=policy_name, PolicyDocument=json.dumps(policy))


def _revoke_keycloak_session(username):
    response = lambda_client.invoke(
        FunctionName=os.environ["KEYCLOAK_SESSION_FUNCTION"],
        InvocationType="RequestResponse",
        Payload=json.dumps({"username": username, "credentials": _keycloak_credentials()}).encode(),
    )
    payload = response["Payload"].read()
    if response.get("FunctionError"):
        raise RuntimeError("Keycloak session Lambda failed")
    try:
        result = json.loads(payload or b"{}")
        if int(result.get("statusCode", 500)) != 200:
            raise RuntimeError("Keycloak session Lambda returned failure")
    except (TypeError, ValueError) as error:
        raise RuntimeError("Keycloak session Lambda returned an invalid response") from error


def _execute(action_id, value, approver):
    if action_id == "keep_access_key":
        iam.tag_user(
            UserName=value["username"],
            Tags=[
                {"Key": "CIEMExceptionReviewedBy", "Value": approver},
                {"Key": "CIEMExceptionReviewedAt", "Value": str(int(time.time()))},
            ],
        )
        return f"Access key exception retained by {approver}."

    if action_id == "revoke_access_key":
        try:
            iam.update_access_key(UserName=value["username"], AccessKeyId=value["key_id"], Status="Inactive")
        except iam.exceptions.NoSuchEntityException:
            pass
        try:
            iam.delete_access_key(UserName=value["username"], AccessKeyId=value["key_id"])
        except iam.exceptions.NoSuchEntityException:
            pass
        return f"Access key disabled and deleted by {approver}."

    if action_id == "acknowledge_permission_drift":
        return f"Permission drift review acknowledged by {approver}; IAM declaration is unchanged."

    if action_id == "approve_exception_risk":
        return f"Permission-boundary exception acknowledged by {approver}; no automatic recovery was performed."

    if action_id == "lock_account_risk":
        role_name = value["role_name"]
        if role_name not in json.loads(os.environ["SAML_ROLE_NAMES_JSON"]):
            raise ValueError("boundary action targets an unmanaged role")
        try:
            iam.detach_role_policy(RoleName=role_name, PolicyArn=value["policy_arn"])
        except iam.exceptions.NoSuchEntityException:
            pass
        _revoke_aws_sessions(value["username"])
        _revoke_keycloak_session(value["username"])
        return f"Managed policy detached and active AWS/Keycloak sessions revoked by {approver}."

    raise ValueError("unsupported action")


def handler(event, context):
    action_key = event["action_key"]
    response_url = event["response_url"]
    if not _claim(action_key):
        _respond(response_url, "This approval is already being processed or has completed.")
        return {"statusCode": 200, "duplicate": True}

    try:
        result = _execute(event["action_id"], event["value"], event["approver_name"])
        sns.publish(TopicArn=os.environ["SNS_TOPIC_ARN"], Subject="CIEM approved action", Message=result)
        _respond(response_url, f"Approved CIEM action completed: {result}")
        _set_state(action_key, "COMPLETED")
        return {"statusCode": 200, "completed": True}
    except Exception:
        _set_state(action_key, "FAILED")
        try:
            _respond(response_url, "CIEM action failed. No success was recorded; check the Lambda Errors alarm.")
        finally:
            # 비동기 Lambda 재시도와 Errors alarm 모두 실패를 볼 수 있어야 한다.
            raise
