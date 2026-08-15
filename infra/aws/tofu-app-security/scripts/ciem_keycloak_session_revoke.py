"""VPC/VGW 전용 Keycloak session revoker. AWS SDK와 인터넷 egress를 사용하지 않는다."""

import http.client
import json
import os
import socket
import ssl
import urllib.parse


HOSTNAME = os.environ["KEYCLOAK_HOSTNAME"]
CONNECT_IP = os.environ["KEYCLOAK_CONNECT_IP"]
REALM = os.environ["KEYCLOAK_REALM"]


class _KeycloakConnection(http.client.HTTPSConnection):
    """사설 IP로 연결하면서 canonical hostname의 TLS SNI/검증을 유지한다."""

    def connect(self):
        raw = socket.create_connection((CONNECT_IP, 443), self.timeout, self.source_address)
        self.sock = self._context.wrap_socket(raw, server_hostname=HOSTNAME)


def _request(method, path, body=None, headers=None, accepted=(200,)):
    connection = _KeycloakConnection(CONNECT_IP, timeout=10, context=ssl.create_default_context())
    request_headers = {"Host": HOSTNAME}
    request_headers.update(headers or {})
    try:
        connection.request(method, path, body=body, headers=request_headers)
        response = connection.getresponse()
        data = response.read()
        if response.status not in accepted:
            raise RuntimeError(f"Keycloak API returned HTTP {response.status}")
        return data
    finally:
        connection.close()


def _admin_token(credentials):
    body = urllib.parse.urlencode(
        {
            "grant_type": "client_credentials",
            "client_id": credentials["client_id"],
            "client_secret": credentials["client_secret"],
        }
    ).encode()
    payload = _request(
        "POST",
        f"/realms/{REALM}/protocol/openid-connect/token",
        body=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    token = json.loads(payload).get("access_token")
    if not token:
        raise RuntimeError("Keycloak service client did not return an access token")
    return token


def _user_id(username, token):
    encoded_username = urllib.parse.quote(username, safe="")
    payload = _request(
        "GET",
        f"/admin/realms/{REALM}/users?username={encoded_username}&exact=true",
        headers={"Authorization": f"Bearer {token}"},
    )
    users = json.loads(payload)
    return users[0]["id"] if users else None


def handler(event, context):
    username = event["username"]
    credentials = event["credentials"]
    if not credentials.get("client_id") or not credentials.get("client_secret"):
        raise ValueError("missing Keycloak service client credentials")

    token = _admin_token(credentials)
    user_id = _user_id(username, token)
    if user_id is None:
        return {"statusCode": 200, "result": "user_not_found"}
    _request(
        "POST",
        f"/admin/realms/{REALM}/users/{urllib.parse.quote(user_id, safe='')}/logout",
        headers={"Authorization": f"Bearer {token}"},
        accepted=(204,),
    )
    return {"statusCode": 200, "result": "sessions_revoked"}
