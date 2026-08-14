"""
특정 인물의 진행 중 세션을 강제 종료한다. Security Hub Custom Action으로
사람이 트리거한다(파괴적 조치라 자동 실행 안 함).

세 가지를 동시에 한다:
  1. AWS: 지정된 사람(RoleSessionName)이 assume한 세션만 정밀 차단하는 Deny
     정책을 4개 SAML Role 전부에 붙임(aws:userid 조건으로 그 사람만 타겟팅).
     DateLessThan(aws:TokenIssueTime) 조건의 한계로 "이미 발급된 세션"만
     막히고 재로그인하면 새 토큰엔 안 걸린다 - 그래서 2/3번이 필요하다.
  2. Keycloak: 활성 세션 강제 로그아웃.
  3. Keycloak: 계정 자체를 비활성화(enabled=false) - 관리자가 다시
     enabled=true로 되돌리기 전까지 재로그인 자체가 거부된다.

⚠️ 이 4개 Role은 tofu-identity가 소유·prevent_destroy로 보호하는 실제 운영
Role이다(observer/observability-reader/security-reader/identity-reader).
정책 반영엔 AWS 공식 문서 기준 최대 몇 분이 걸릴 수 있다.
"""
import boto3
import json
import os
import ssl
import time
import urllib.parse
import urllib.request

# Keycloak이 자체서명 인증서를 쓰면 아래로 검증을 끈다. 정식 인증서면 이 블록과
# context=_INSECURE_SSL_CONTEXT 인자를 전부 제거할 것.
_INSECURE_SSL_CONTEXT = ssl.create_default_context()
_INSECURE_SSL_CONTEXT.check_hostname = False
_INSECURE_SSL_CONTEXT.verify_mode = ssl.CERT_NONE

iam = boto3.client("iam")
secrets_client = boto3.client("secretsmanager")
sns = boto3.client("sns")

NAME_PREFIX = os.environ["NAME_PREFIX"]
KEYCLOAK_HOST = os.environ["KEYCLOAK_HOST"]
REALM_NAME = os.environ["REALM_NAME"]
KEYCLOAK_ADMIN_SECRET_ARN = os.environ["KEYCLOAK_ADMIN_SECRET_ARN"]
SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]
ROLE_NAMES = json.loads(os.environ["ROLE_NAMES_JSON"])


def _revoke_aws_sessions(username: str):
    policy_document = json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Sid": "RevokeSpecificUserSession",
            "Effect": "Deny",
            "Action": "*",
            "Resource": "*",
            "Condition": {
                "StringLike": {"aws:userid": f"*:{username}"},
                "DateLessThan": {"aws:TokenIssueTime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
            },
        }],
    })

    revoked_roles = []
    for role_name in ROLE_NAMES:
        try:
            iam.put_role_policy(
                RoleName=role_name,
                PolicyName=f"revoke-session-{username}",
                PolicyDocument=policy_document,
            )
            revoked_roles.append(role_name)
        except iam.exceptions.NoSuchEntityException:
            continue
    return revoked_roles


def _get_keycloak_admin_credentials() -> tuple[str, str]:
    secret = secrets_client.get_secret_value(SecretId=KEYCLOAK_ADMIN_SECRET_ARN)
    creds = json.loads(secret["SecretString"])
    return creds["username"], creds["password"]


def _get_keycloak_admin_token() -> str:
    admin_user, admin_password = _get_keycloak_admin_credentials()
    data = urllib.parse.urlencode({
        "client_id": "admin-cli",
        "grant_type": "password",
        "username": admin_user,
        "password": admin_password,
    }).encode()
    req = urllib.request.Request(
        f"https://{KEYCLOAK_HOST}/realms/master/protocol/openid-connect/token",
        data=data, method="POST",
    )
    with urllib.request.urlopen(req, context=_INSECURE_SSL_CONTEXT) as resp:
        return json.loads(resp.read())["access_token"]


def _get_keycloak_user_id(username: str, admin_token: str) -> str | None:
    headers = {"Authorization": f"Bearer {admin_token}"}
    req = urllib.request.Request(
        f"https://{KEYCLOAK_HOST}/admin/realms/{REALM_NAME}/users?username={username}&exact=true",
        headers=headers,
    )
    with urllib.request.urlopen(req, context=_INSECURE_SSL_CONTEXT) as resp:
        users = json.loads(resp.read())
    return users[0]["id"] if users else None


def _logout_keycloak_user(user_id: str, admin_token: str):
    headers = {"Authorization": f"Bearer {admin_token}"}
    req = urllib.request.Request(
        f"https://{KEYCLOAK_HOST}/admin/realms/{REALM_NAME}/users/{user_id}/logout",
        headers=headers, method="POST",
    )
    urllib.request.urlopen(req, context=_INSECURE_SSL_CONTEXT)


def _disable_keycloak_user(user_id: str, admin_token: str):
    headers = {"Authorization": f"Bearer {admin_token}", "Content-Type": "application/json"}
    req = urllib.request.Request(
        f"https://{KEYCLOAK_HOST}/admin/realms/{REALM_NAME}/users/{user_id}",
        data=json.dumps({"enabled": False}).encode("utf-8"),
        headers=headers, method="PUT",
    )
    urllib.request.urlopen(req, context=_INSECURE_SSL_CONTEXT)


def _extract_username(event: dict) -> str:
    if "username" in event:
        return event["username"]
    try:
        finding = event["detail"]["findings"][0]
        return finding["Resources"][0]["Details"]["AwsIamRole"]["RoleSessionName"]
    except (KeyError, IndexError):
        raise ValueError("username을 이벤트에서 추출하지 못했습니다. {'username': '...'} 형태로 수동 재호출하세요.")


def handler(event, context):
    username = _extract_username(event)

    revoked_roles = _revoke_aws_sessions(username)

    keycloak_logged_out = False
    keycloak_disabled = False
    try:
        admin_token = _get_keycloak_admin_token()
        user_id = _get_keycloak_user_id(username, admin_token)
        if user_id:
            _logout_keycloak_user(user_id, admin_token)
            keycloak_logged_out = True
            _disable_keycloak_user(user_id, admin_token)
            keycloak_disabled = True
    except Exception as e:
        keycloak_logged_out = f"실패: {e}"

    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"세션 강제 종료: {username}",
        Message=(
            f"대상: {username}\n"
            f"AWS 세션 차단 Role: {', '.join(revoked_roles) if revoked_roles else '없음'}\n"
            f"Keycloak 로그아웃: {keycloak_logged_out}\n"
            f"Keycloak 계정 비활성화: {keycloak_disabled}\n"
            f"참고: 정책 반영까지 최대 몇 분 소요될 수 있음(AWS 공식 안내)."
        ),
    )

    return {
        "statusCode": 200,
        "username": username,
        "revoked_roles": revoked_roles,
        "keycloak_logged_out": keycloak_logged_out,
        "keycloak_disabled": keycloak_disabled,
    }
