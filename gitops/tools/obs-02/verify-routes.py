#!/usr/bin/env python3
"""OBS-02 Pomerium browser session, UI query, silence 경계를 비밀 없이 검증한다."""

import argparse
import base64
import datetime as dt
import importlib.util
import json
from pathlib import Path
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


GRAFANA_URL = "https://grafana.imcherry5778.xyz"
PROMETHEUS_URL = "https://prometheus.imcherry5778.xyz"
ALERTMANAGER_URL = "https://alertmanager.imcherry5778.xyz"
OBS_HOSTS = {
    "grafana.imcherry5778.xyz",
    "prometheus.imcherry5778.xyz",
    "alertmanager.imcherry5778.xyz",
}
CURRENT_STAGE = "initialization"


class VerificationHTTPError(RuntimeError):
    """URL query와 response body를 남기지 않는 HTTP 실패 진단값이다."""


def load_pomerium_browser(repo_root: Path):
    module_path = repo_root / "gitops/tools/pom-01/browser-session.py"
    spec = importlib.util.spec_from_file_location("obs02_pomerium_browser", module_path)
    if not spec or not spec.loader:
        raise RuntimeError("POM-01 browser verifier를 불러올 수 없다")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.EXPECTED_HOSTS = set(module.EXPECTED_HOSTS) | OBS_HOSTS
    return module


def require_secret_file(path: Path):
    metadata = path.lstat()
    if not path.is_file() or path.is_symlink() or metadata.st_mode & 0o077:
        raise RuntimeError(f"secret input is not a mode 0600 regular file: {path.name}")


def basic_header(password_file: Path) -> str:
    require_secret_file(password_file)
    password = password_file.read_text(encoding="utf-8").strip()
    encoded = base64.b64encode(f"admin:{password}".encode("utf-8")).decode("ascii")
    return f"Basic {encoded}"


def request(opener, url: str, *, method="GET", payload=None, headers=None):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request_headers = dict(headers or {})
    if payload is not None:
        request_headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=data, headers=request_headers, method=method)
    try:
        with opener.open(request, timeout=30) as response:
            return response.status, response.geturl(), response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.geturl(), error.read()


def expect_status(opener, url: str, expected: int, label: str, *, headers=None):
    status, final_url, body = request(opener, url, headers=headers)
    if status != expected or final_url != url:
        raise RuntimeError(f"{label} expected HTTP {expected}, got {status}")
    return body


def login(
    browser,
    connect_ip: str,
    url: str,
    username: str,
    password_file: str,
    totp_file: str,
    *,
    expected_status=200,
):
    cookie_jar = browser.http.cookiejar.CookieJar()
    opener = browser.build_opener(cookie_jar, connect_ip)
    try:
        status, final_url, _ = browser.login(
            opener, url, username, password_file, totp_file
        )
    except urllib.error.HTTPError as error:
        parsed = urllib.parse.urlsplit(error.geturl())
        raise VerificationHTTPError(
            f"Pomerium login HTTP {error.code} at {parsed.hostname}{parsed.path}"
        ) from error
    except Exception as error:
        browser_stage = getattr(browser, "CURRENT_STAGE", "unknown")
        raise VerificationHTTPError(
            f"Pomerium login failed at browser stage={browser_stage}, "
            f"type={type(error).__name__}"
        ) from error
    if status != expected_status or final_url != url:
        expected = urllib.parse.urlsplit(url)
        actual = urllib.parse.urlsplit(final_url)
        raise VerificationHTTPError(
            "Pomerium login expected "
            f"HTTP {expected_status} at {expected.hostname}{expected.path}, got "
            f"HTTP {status} at {actual.hostname}{actual.path}"
        )
    return opener


def prometheus_query(opener, query: str):
    encoded = urllib.parse.urlencode({"query": query})
    body = expect_status(
        opener,
        f"{PROMETHEUS_URL}/api/v1/query?{encoded}",
        200,
        "Prometheus query",
    )
    response = json.loads(body)
    if response.get("status") != "success" or not response.get("data", {}).get("result"):
        raise RuntimeError("Prometheus PromQL result is empty")
    return response


def grafana_resource_query(opener, uid: str, path: str, query: dict, auth: str):
    encoded = urllib.parse.urlencode(query)
    url = f"{GRAFANA_URL}/api/datasources/uid/{uid}/resources/{path}?{encoded}"
    body = expect_status(
        opener, url, 200, f"Grafana {uid} datasource", headers={"Authorization": auth}
    )
    response = json.loads(body)
    if response.get("status") != "success":
        raise RuntimeError(f"Grafana {uid} datasource response is not successful")
    return response


def grafana_proxy_query(opener, uid: str, path: str, query: dict, auth: str):
    encoded = urllib.parse.urlencode(query)
    url = f"{GRAFANA_URL}/api/datasources/proxy/uid/{uid}/{path}?{encoded}"
    body = expect_status(
        opener, url, 200, f"Grafana {uid} datasource proxy", headers={"Authorization": auth}
    )
    response = json.loads(body)
    if response.get("status") != "success":
        raise RuntimeError(f"Grafana {uid} datasource proxy response is not successful")
    return response


def verify_grafana(opener, auth: str):
    dashboard_body = expect_status(
        opener,
        f"{GRAFANA_URL}/api/dashboards/uid/obs-02-overview",
        200,
        "Grafana dashboard",
        headers={"Authorization": auth},
    )
    dashboard = json.loads(dashboard_body)
    titles = {panel.get("title") for panel in dashboard.get("dashboard", {}).get("panels", [])}
    expected_titles = {
        "Node exporter",
        "PersistentVolumeClaims",
        "Loki logs in the last 5 minutes",
    }
    if not expected_titles.issubset(titles):
        raise RuntimeError("Grafana OBS-02 node/PVC/Loki dashboard panels are missing")
    headers = {"Authorization": auth}
    prom = grafana_resource_query(
        opener,
        "prometheus",
        "api/v1/query",
        {"query": 'count(node_uname_info{service="obs-prometheus-node-exporter"})'},
        headers["Authorization"],
    )
    if not prom["data"].get("result"):
        raise RuntimeError("Grafana node panel query is empty")
    pvc = grafana_resource_query(
        opener,
        "prometheus",
        "api/v1/query",
        {"query": 'count(kube_persistentvolumeclaim_info{service="obs-kube-state-metrics"})'},
        headers["Authorization"],
    )
    if not pvc["data"].get("result"):
        raise RuntimeError("Grafana PVC panel query is empty")
    end_ns = int(time.time() * 1_000_000_000)
    loki = grafana_proxy_query(
        opener,
        "loki",
        "loki/api/v1/query_range",
        {
            "query": 'sum(count_over_time({namespace=~".+"}[5m]))',
            "start": str(end_ns - 300_000_000_000),
            "end": str(end_ns),
            "step": "60",
        },
        headers["Authorization"],
    )
    if not loki["data"].get("result"):
        raise RuntimeError("Grafana Loki panel query is empty")


def expire_silence(opener):
    global CURRENT_STAGE
    now = dt.datetime.now(dt.timezone.utc)
    starts_at = (now - dt.timedelta(seconds=5)).isoformat().replace("+00:00", "Z")
    ends_at = (now + dt.timedelta(minutes=2)).isoformat().replace("+00:00", "Z")
    payload = {
        "matchers": [{"name": "alertname", "value": "OBS02SilenceProbe", "isRegex": False}],
        "startsAt": starts_at,
        "endsAt": ends_at,
        "createdBy": "obs-02-verifier",
        "comment": "temporary OBS-02 Pomerium verification",
    }
    CURRENT_STAGE = "alertmanager-silence-create"
    status, _, body = request(
        opener,
        f"{ALERTMANAGER_URL}/api/v2/silences",
        method="POST",
        payload=payload,
    )
    if status != 200:
        raise RuntimeError(f"Alertmanager silence create status={status}")
    silence_id = json.loads(body).get("silenceID")
    if not isinstance(silence_id, str) or not silence_id:
        raise RuntimeError("Alertmanager silence create did not return an ID")
    try:
        CURRENT_STAGE = "alertmanager-silence-read"
        silence_body = expect_status(
            opener,
            f"{ALERTMANAGER_URL}/api/v2/silence/{silence_id}",
            200,
            "Alertmanager silence read",
        )
        if json.loads(silence_body).get("id") != silence_id:
            raise RuntimeError("Alertmanager silence read returned a different ID")
        CURRENT_STAGE = "alertmanager-silence-expire"
        status, _, _ = request(
            opener,
            f"{ALERTMANAGER_URL}/api/v2/silence/{silence_id}",
            method="DELETE",
        )
        if status != 200:
            raise RuntimeError(f"Alertmanager silence expire status={status}")
        expired_body = expect_status(
            opener,
            f"{ALERTMANAGER_URL}/api/v2/silence/{silence_id}",
            200,
            "Alertmanager expired silence read",
        )
        if json.loads(expired_body).get("status", {}).get("state") != "expired":
            raise RuntimeError("Alertmanager silence is not expired after DELETE")
    except Exception:
        request(
            opener,
            f"{ALERTMANAGER_URL}/api/v2/silence/{silence_id}",
            method="DELETE",
        )
        raise


def main():
    global CURRENT_STAGE
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--connect-ip", required=True)
    parser.add_argument("--user-username", required=True)
    parser.add_argument("--user-password-file", required=True)
    parser.add_argument("--user-totp-file", required=True)
    parser.add_argument("--deny-username", required=True)
    parser.add_argument("--deny-password-file", required=True)
    parser.add_argument("--deny-totp-file", required=True)
    parser.add_argument("--privileged-username", required=True)
    parser.add_argument("--privileged-password-file", required=True)
    parser.add_argument("--privileged-totp-file", required=True)
    parser.add_argument("--grafana-password-file", required=True, type=Path)
    args = parser.parse_args()
    browser = load_pomerium_browser(args.repo_root)
    for secret_file in (
        args.user_password_file,
        args.user_totp_file,
        args.deny_password_file,
        args.deny_totp_file,
        args.privileged_password_file,
        args.privileged_totp_file,
    ):
        require_secret_file(Path(secret_file))
    grafana_auth = basic_header(args.grafana_password_file)

    CURRENT_STAGE = "platform-users-route-session"
    user_opener = login(
        browser,
        args.connect_ip,
        f"{GRAFANA_URL}/api/health",
        args.user_username,
        args.user_password_file,
        args.user_totp_file,
    )
    verify_grafana(user_opener, grafana_auth)
    target_result = prometheus_query(
        user_opener, 'up{service="obs-prometheus-node-exporter"}'
    )
    if any(item["value"][1] != "1" for item in target_result["data"]["result"]):
        raise RuntimeError("Prometheus target up is not 1")
    prometheus_query(
        user_opener, 'count(kube_persistentvolumeclaim_info{service="obs-kube-state-metrics"})'
    )
    alert_status = expect_status(
        user_opener,
        f"{ALERTMANAGER_URL}/api/v2/status",
        200,
        "Alertmanager platform-users read",
    )
    if not json.loads(alert_status).get("versionInfo", {}).get("version"):
        raise RuntimeError("Alertmanager status version is missing")

    CURRENT_STAGE = "unaffiliated-route-session"
    deny_opener = login(
        browser,
        args.connect_ip,
        f"{GRAFANA_URL}/api/health",
        args.deny_username,
        args.deny_password_file,
        args.deny_totp_file,
        expected_status=403,
    )
    for label, url in (
        ("Grafana unaffiliated", f"{GRAFANA_URL}/"),
        ("Prometheus unaffiliated", f"{PROMETHEUS_URL}/-/ready"),
        ("Alertmanager unaffiliated", f"{ALERTMANAGER_URL}/api/v2/status"),
    ):
        expect_status(deny_opener, url, 403, label)

    CURRENT_STAGE = "platform-privileged-silence-session"
    privileged_opener = login(
        browser,
        args.connect_ip,
        f"{ALERTMANAGER_URL}/api/v2/status",
        args.privileged_username,
        args.privileged_password_file,
        args.privileged_totp_file,
    )
    expire_silence(privileged_opener)
    CURRENT_STAGE = "complete"
    print(
        "OBS-02 browser: Grafana dashboard=node/PVC/Loki, Prometheus=up+PromQL, "
        "Alertmanager=read+privileged-silence-expire, groups=allow-deny"
    )


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        status = getattr(error, "code", "n/a")
        detail = (
            str(error)
            if isinstance(error, (VerificationHTTPError, RuntimeError))
            else ""
        )
        print(
            f"OBS-02 browser failed: stage={CURRENT_STAGE}, "
            f"type={type(error).__name__}, status={status} {detail}",
            file=sys.stderr,
        )
        raise SystemExit(1)
