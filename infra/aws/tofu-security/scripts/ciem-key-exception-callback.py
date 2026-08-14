"""
Slack 인터랙티브 버튼 클릭을 API Gateway 경유로 받는 통합 콜백 Lambda.
Slack App은 Interactivity Request URL을 앱 전체에 하나만 등록할 수 있어서,
서로 다른 CIEM 알림(미사용 Access Key 처리 / 권한 드리프트 처리)이 전부 이
Lambda 하나로 들어옵니다 - action_id로 구분해서 각자 다른 조치를 실행합니다.
Slack 서명(Signing Secret)을 검증한 뒤, 사람이 명시적으로 선택한 조치만
수행합니다(자동 삭제 없음 - 이 콜백 자체가 "사람의 승인" 그 자체임, ADR-005
결정 5).

처리하는 action_id 6종:
  - keep_access_key / revoke_access_key
      (ciem-key-exception-notify.py가 보낸 미사용 Access Key 알림, ADR-017 결정 2)
  - apply_reduced_policy / keep_current_policy
      (ciem-boundary-drift-notify.py가 보낸 권한 드리프트 알림, 36번 tf)
  - lock_account_risk / approve_exception_risk
      (iam-boundary-violation-watch.py가 보낸 Permission Boundary 위반 알림,
      44번 tf) - 잠금 로직을 새로 안 만들고 session-revoke Lambda를 그대로
      호출만 한다(Scene 10과 동일한 실행 경로 재사용). 두 액션 다 처리 후
      같은 event_id로 status=RESOLVED 로그를 남겨서, Grafana의 "미해결
      목록" 패널에서 자동으로 빠지고 "해결 타임라인" 패널에 나타나게 한다
      (iam-boundary-violation-watch.py가 남긴 UNRESOLVED 로그와 event_id로 짝짓기).
"""
import base64
import boto3
import hashlib
import hmac
import json
import os
import time
import urllib.parse
import urllib.request

iam = boto3.client("iam")
access_analyzer = boto3.client("accessanalyzer")
secrets_client = boto3.client("secretsmanager")
lambda_client = boto3.client("lambda")
logs_client = boto3.client("logs")

SLACK_SECRET_ARN = os.environ["SLACK_SECRET_ARN"]
SESSION_REVOKE_FUNCTION_NAME = os.environ["SESSION_REVOKE_FUNCTION_NAME"]
BOUNDARY_VIOLATION_LOG_GROUP = os.environ["BOUNDARY_VIOLATION_LOG_GROUP"]


def _get_signing_secret() -> str:
    secret = secrets_client.get_secret_value(SecretId=SLACK_SECRET_ARN)
    return json.loads(secret["SecretString"])["signing_secret"]


def _verify_slack_signature(headers: dict, body: str) -> bool:
    timestamp = headers.get("x-slack-request-timestamp", "")
    slack_signature = headers.get("x-slack-signature", "")

    # 리플레이 공격 방지: 5분 넘은 요청은 거부
    if abs(time.time() - int(timestamp)) > 60 * 5:
        return False

    signing_secret = _get_signing_secret()
    sig_basestring = f"v0:{timestamp}:{body}"
    computed = "v0=" + hmac.new(
        signing_secret.encode(), sig_basestring.encode(), hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(computed, slack_signature)


def _respond_to_slack(response_url: str, text: str):
    payload = {"replace_original": "true", "text": text}
    req = urllib.request.Request(
        response_url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    urllib.request.urlopen(req)


def _handle_keep_access_key(value: dict, approver: str, response_url: str):
    username, key_id = value["username"], value["key_id"]
    iam.tag_user(
        UserName=username,
        Tags=[{"Key": "CIEMExceptionReviewedBy", "Value": approver},
              {"Key": "CIEMExceptionReviewedAt", "Value": str(int(time.time()))}],
    )
    _respond_to_slack(response_url, f"✅ {username}/{key_id} — {approver}님이 예외로 확인, 유지합니다.")


def _handle_revoke_access_key(value: dict, approver: str, response_url: str):
    username, key_id = value["username"], value["key_id"]
    iam.update_access_key(UserName=username, AccessKeyId=key_id, Status="Inactive")
    iam.delete_access_key(UserName=username, AccessKeyId=key_id)
    _respond_to_slack(response_url, f"🗑 {username}/{key_id} — {approver}님의 승인으로 삭제 완료.")


def _handle_apply_reduced_policy(value: dict, approver: str, response_url: str):
    role_name = value["role_name"]
    job_id = value["job_id"]

    generated = access_analyzer.get_generated_policy(jobId=job_id)
    policies = generated.get("generatedPolicyResult", {}).get("generatedPolicies", [])
    if not policies:
        _respond_to_slack(
            response_url,
            f"❌ {role_name} - 생성된 정책을 다시 못 찾았습니다(시간이 지나 만료됐을 수 있음). "
            f"분석을 다시 실행해주세요.",
        )
        return

    reduced_policy = policies[0]["policy"]

    # 이 프로젝트 구조상(12-iam-saml-roles.tf) Role마다 인라인 정책이 정확히
    # 하나뿐이라, 그 이름을 그대로 조회해서 재사용한다.
    existing_policy_names = iam.list_role_policies(RoleName=role_name).get("PolicyNames", [])
    if not existing_policy_names:
        _respond_to_slack(response_url, f"❌ {role_name} - 기존 인라인 정책을 찾을 수 없습니다.")
        return

    target_policy_name = existing_policy_names[0]

    iam.put_role_policy(RoleName=role_name, PolicyName=target_policy_name, PolicyDocument=reduced_policy)
    iam.tag_role(
        RoleName=role_name,
        Tags=[{"Key": "BoundaryDriftReviewedBy", "Value": approver},
              {"Key": "BoundaryDriftReviewedAt", "Value": str(int(time.time()))}],
    )
    _respond_to_slack(
        response_url,
        f"✅ {role_name} — {approver}님 승인으로 최소권한 정책 적용 완료.\n"
        f"⚠️ 참고: Console/CLI로 직접 바꾼 상태라, 다음 `terraform apply` 때 "
        f"policies/*.json.tpl 파일과 실제 상태가 다르면 되돌아갈 수 있습니다 - "
        f"계속 유지하려면 이 결과를 해당 정책 파일에도 반영해주세요.",
    )


def _handle_keep_current_policy(value: dict, approver: str, response_url: str):
    role_name = value["role_name"]
    _respond_to_slack(
        response_url,
        f"🔒 {role_name} — {approver}님이 현재 정책 유지로 확인함(저빈도 정당 업무로 판단, 자동 회수 안 함).",
    )


def _log_resolved(event_id: str, target_role: str, resolved_by: str, button_clicked: str, action_taken: str):
    # iam-boundary-violation-watch.py와 동일한 이유로(CWLI가 "stats latest(a),
    # latest(b) by k"에서 마지막 latest()만 남기는 동작) 필드 하나(summary)에
    # 다 합쳐서 로그를 남긴다 - 같은 event_id로 이 RESOLVED summary가 찍히면
    # Grafana의 "미해결" 패널 쿼리(latest(summary) by event_id)가 최신값을
    # 이걸로 갱신해서 UNRESOLVED 필터에서 자동으로 빠진다.
    now_iso = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    summary = (
        f"RESOLVED | Role: {target_role} | By: {resolved_by} | Action: {button_clicked} "
        f"→ {action_taken} | At: {now_iso}"
    )
    log_stream = time.strftime("%Y-%m-%d", time.gmtime())
    try:
        logs_client.create_log_stream(logGroupName=BOUNDARY_VIOLATION_LOG_GROUP, logStreamName=log_stream)
    except logs_client.exceptions.ResourceAlreadyExistsException:
        pass
    logs_client.put_log_events(
        logGroupName=BOUNDARY_VIOLATION_LOG_GROUP,
        logStreamName=log_stream,
        logEvents=[{
            "timestamp": int(time.time() * 1000),
            "message": json.dumps({"event_id": event_id, "summary": summary}),
        }],
    )


def _handle_lock_account_risk(value: dict, approver: str, response_url: str):
    username = value["username"]
    role_name = value.get("role_name", "?")
    policy_arn = value.get("policy_arn")
    policy_name = policy_arn.rsplit("/", 1)[-1] if policy_arn else "?"

    # session-revoke는 세션만 차단할 뿐 위반 정책 자체는 안 건드리므로,
    # "Detached & Session Revoked"가 실제로 맞으려면 여기서 정책을 직접 뗀다.
    if policy_arn:
        try:
            iam.detach_role_policy(RoleName=role_name, PolicyArn=policy_arn)
        except iam.exceptions.NoSuchEntityException:
            pass  # 이미 누군가 떼어냈을 수 있음 - 여전히 세션 차단은 진행

    # 잠금 로직을 여기서 새로 구현하지 않고, Scene 10에서 이미 검증된
    # session-revoke Lambda를 그대로 호출한다(4개 Role 전체 Deny 부착 +
    # Keycloak SSO 강제 로그아웃).
    lambda_client.invoke(
        FunctionName=SESSION_REVOKE_FUNCTION_NAME,
        InvocationType="Event",
        Payload=json.dumps({"username": username}).encode("utf-8"),
    )
    if "event_id" in value:
        _log_resolved(
            value["event_id"], role_name, f"@{approver}", "Lock & Revoke",
            f"{policy_name} Detached & Session Revoked",
        )
    _respond_to_slack(
        response_url,
        f"✅ @{approver} 님이 [Lock & Revoke] 버튼을 눌러 조치를 완료했습니다.\n"
        f"🔒 {username} — AWS 세션 전체 차단 + Keycloak SSO 로그아웃. "
        f"원인: {role_name}에 Permission Boundary 밖의 정책({policy_name})이 부착됨.",
    )


def _handle_approve_exception_risk(value: dict, approver: str, response_url: str):
    role_name = value.get("role_name", "?")
    policy_name = value.get("policy_arn", "?").rsplit("/", 1)[-1]
    if "event_id" in value:
        _log_resolved(
            value["event_id"], role_name, f"@{approver}", "Approve",
            f"{policy_name} 예외 승인(정책 유지, 회수 안 함)",
        )
    _respond_to_slack(
        response_url,
        f"⚠️ @{approver} 님이 [Approve] 버튼을 눌러 예외로 승인했습니다.\n"
        f"{role_name}의 {policy_name}는 그대로 유지됩니다(자동 회수 없음).",
    )


ACTION_HANDLERS = {
    "keep_access_key": _handle_keep_access_key,
    "revoke_access_key": _handle_revoke_access_key,
    "apply_reduced_policy": _handle_apply_reduced_policy,
    "keep_current_policy": _handle_keep_current_policy,
    "lock_account_risk": _handle_lock_account_risk,
    "approve_exception_risk": _handle_approve_exception_risk,
}


def handler(event, context):
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    body = event.get("body", "")
    # API Gateway HTTP API(payload_format_version=2.0)는
    # application/x-www-form-urlencoded 바디를 base64로 인코딩해서 넘긴다
    # (event["isBase64Encoded"]=true) - 디코딩 전 바디로 서명 검증하면
    # Slack이 원본에 대해 서명한 값과 맞지 않아 항상 실패한다.
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8")

    if not _verify_slack_signature(headers, body):
        return {"statusCode": 401, "body": "invalid signature"}

    form = urllib.parse.parse_qs(body)
    payload = json.loads(form["payload"][0])

    action = payload["actions"][0]
    action_id = action["action_id"]
    value = json.loads(action["value"])
    approver = payload["user"]["username"]  # Slack 상에서 버튼을 누른 사람
    response_url = payload["response_url"]

    handler_fn = ACTION_HANDLERS.get(action_id)
    if handler_fn is None:
        return {"statusCode": 400, "body": "unknown action"}

    handler_fn(value, approver, response_url)
    return {"statusCode": 200, "body": ""}
