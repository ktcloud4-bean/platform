"""
4개 SAML Role(tofu-identity 소유)은 인라인 정책 하나만 갖도록 설계돼 있어서
관리형 정책이 붙는 경우가 원래 없다 - 즉 AttachRolePolicy가 호출된다는 사실
자체가 이미 "설계된 경계 밖의 권한이 붙었다"는 이상 징후다. 정책 종류별로
위험도를 채점하지 않고, "원래 아무것도 안 붙어야 하는데 뭔가 붙었다" 그
자체를 위반으로 본다(EXPECTED_MANAGED_POLICY_ARNS에 예외를 추가하면 특정
정책만 정상으로 취급 가능 - 기본은 빈 목록).

이 Lambda는 위반 "발생" 시점에 status=UNRESOLVED 로그 한 줄만 남긴다.
"해결" 시점의 status=RESOLVED 로그는 ciem-key-exception-callback.py가(사람이
Slack 버튼을 눌렀을 때) 같은 event_id로 별도로 남긴다.

⚠️ project-c와 달리 "잠금 대상"을 role 이름에서 역산하지 않는다(project-c의
데모 계정은 "test-<role-suffix>" 규칙으로 role마다 정해진 한 명이 있었지만,
이 4개 Role은 실제로 여러 사람이 Keycloak 그룹을 통해 공유해서 assume할 수
있어 "이 role의 원래 주인" 같은 게 없다). 대신 AttachRolePolicy를 호출한
사람(attached_by) 본인을 그대로 잠금 대상으로 삼는다 - 이 Role들 자체가
읽기전용으로 설계돼 있어서, 정상적으로 assume한 세션은 애초에 관리형 정책을
붙일 권한이 없다. 즉 이 호출을 한 사람은 그 세션의 권한 범위를 벗어난
행동을 한 것이므로, 그 사람 본인이 이상 행위자다.

EventBridge가 CloudTrail의 AttachRolePolicy 관리 이벤트를 실시간으로 이
Lambda에 전달하면:
  1. status=UNRESOLVED 로그 한 줄을 CloudWatch Logs에 구조화된 JSON으로 남긴다.
  2. Slack에 "잠금 & 회수" / "예외 승인" 두 버튼과 함께 알린다. 실제 조치는
     여기서 구현하지 않고 session-revoke Lambda를 재사용한다.

⚠️ 이 Lambda 자체는 us-east-1에서 실행된다(44-iam-boundary-violation-watch.tf
참고 - 이 이벤트가 항상 us-east-1 기본 이벤트 버스로만 전달됨). 로그그룹/
Secret은 ap-northeast-2에 있으므로 boto3 클라이언트가 region_name을 명시한다.
"""
import boto3
import json
import os
import time
import urllib.request

logs_client = boto3.client("logs", region_name="ap-northeast-2")
secrets_client = boto3.client("secretsmanager", region_name="ap-northeast-2")

LOG_GROUP_NAME = os.environ["LOG_GROUP_NAME"]
SLACK_SECRET_ARN = os.environ["SLACK_SECRET_ARN"]
SLACK_CHANNEL = os.environ.get("SLACK_CHANNEL", "#cspm-findings")
EXPECTED_MANAGED_POLICY_ARNS = set(filter(None, os.environ.get("EXPECTED_MANAGED_POLICY_ARNS", "").split(",")))


def _get_slack_bot_token() -> str:
    secret = secrets_client.get_secret_value(SecretId=SLACK_SECRET_ARN)
    return json.loads(secret["SecretString"])["bot_token"]


def _extract_username(user_identity: dict) -> str:
    # SAML로 assume한 세션은 arn:aws:sts::ACCOUNT:assumed-role/ROLE/ROLE_SESSION_NAME
    # 형태이고 RoleSessionName이 곧 Keycloak 사용자명이다(session-revoke.py와 동일 규칙).
    arn = user_identity.get("arn", "")
    if "assumed-role" in arn:
        return arn.rsplit("/", 1)[-1]
    return user_identity.get("principalId", "unknown")


def _log_unresolved(event_id: str, target_role: str, violation_policy: str, attached_by: str):
    now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    summary = (
        f"UNRESOLVED | Role: {target_role} | Policy: {violation_policy.rsplit('/', 1)[-1]} "
        f"| AttachedBy: {attached_by} | At: {now_iso}"
    )
    log_stream = time.strftime("%Y-%m-%d", time.gmtime())
    try:
        logs_client.create_log_stream(logGroupName=LOG_GROUP_NAME, logStreamName=log_stream)
    except logs_client.exceptions.ResourceAlreadyExistsException:
        pass
    logs_client.put_log_events(
        logGroupName=LOG_GROUP_NAME,
        logStreamName=log_stream,
        logEvents=[{
            "timestamp": int(time.time() * 1000),
            "message": json.dumps({"event_id": event_id, "summary": summary}),
        }],
    )


def _post_slack_alert(token: str, event_id: str, role_name: str, policy_arn: str, attached_by: str):
    policy_name = policy_arn.rsplit("/", 1)[-1]
    button_value = json.dumps({
        "event_id": event_id,
        "username": attached_by,
        "role_name": role_name,
        "policy_arn": policy_arn,
    })
    payload = {
        "channel": SLACK_CHANNEL,
        "text": f"[SECURITY ALERT] Unauthorized IAM Policy Attached - {role_name}",
        "blocks": [
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": (
                        f"*[SECURITY ALERT] Unauthorized IAM Policy Attached*\n\n"
                        f"• 대상 Role: `{role_name}`\n"
                        f"• 위반 Policy: `{policy_name}`\n"
                        f"• 정책을 붙인 계정(잠금 대상): `{attached_by}`\n"
                        f"• 상태: 미해결 (Unresolved)\n\n"
                        f"이 Role은 읽기전용 인라인 정책 하나만 쓰도록 설계돼 있어서, "
                        f"관리형 정책이 붙는 것 자체가 정상 범위를 벗어난 상태입니다.\n"
                        f"아래 조치 버튼 중 하나를 선택하세요:"
                    ),
                },
            },
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "세션 잠금 & 권한 회수 (Lock & Revoke)"},
                        "style": "danger",
                        "action_id": "lock_account_risk",
                        "value": button_value,
                        "confirm": {
                            "title": {"type": "plain_text", "text": "정말 잠글까요?"},
                            "text": {"type": "plain_text", "text": f"{attached_by}의 AWS 세션 전체와 Keycloak SSO 세션을 즉시 강제 종료합니다."},
                            "confirm": {"type": "plain_text", "text": "잠금"},
                            "deny": {"type": "plain_text", "text": "취소"},
                        },
                    },
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "예외 승인 (Approve)"},
                        "action_id": "approve_exception_risk",
                        "value": button_value,
                    },
                ],
            },
        ],
    }
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )
    with urllib.request.urlopen(req) as resp:
        result = json.loads(resp.read())
        if not result.get("ok"):
            raise RuntimeError(f"Slack API 실패: {result}")


def handler(event, context):
    detail = event["detail"]
    event_id = detail["eventID"]
    request_params = detail["requestParameters"]
    role_name = request_params["roleName"]
    policy_arn = request_params["policyArn"]
    attached_by = _extract_username(detail.get("userIdentity", {}))

    if policy_arn in EXPECTED_MANAGED_POLICY_ARNS:
        return {"statusCode": 200, "result": "in_boundary", "role": role_name}

    _log_unresolved(event_id, role_name, policy_arn, attached_by)
    token = _get_slack_bot_token()
    _post_slack_alert(token, event_id, role_name, policy_arn, attached_by)
    return {
        "statusCode": 200, "result": "violation_alerted", "event_id": event_id,
        "role": role_name, "attached_by": attached_by,
    }
