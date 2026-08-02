#!/usr/bin/env python3
"""port-forward된 Gitea ClusterIP에 로컬 recovery admin web login을 검증한다."""

import argparse
from html.parser import HTMLParser
import http.client
from pathlib import Path
import urllib.parse


class SessionParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = set()

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "a" and values.get("href"):
            self.links.add(values["href"])


def update_cookies(headers, cookies):
    for header in headers.get_all("Set-Cookie", []):
        pair = header.split(";", 1)[0]
        if "=" in pair:
            key, value = pair.split("=", 1)
            cookies[key] = value


def request(port, method, path, cookies, body=None):
    headers = {
        "Host": "git.imcherry5778.xyz",
        "X-Forwarded-Proto": "https",
    }
    if cookies:
        headers["Cookie"] = "; ".join(f"{key}={value}" for key, value in cookies.items())
    if body is not None:
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
    connection.request(method, path, body=body, headers=headers)
    response = connection.getresponse()
    data = response.read()
    update_cookies(response.headers, cookies)
    status = response.status
    location = response.getheader("Location")
    connection.close()
    return status, location, data


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--password-file", required=True, type=Path)
    args = parser.parse_args()
    password = args.password_file.read_text(encoding="utf-8").strip()
    if not password:
        raise RuntimeError("local admin password is empty")

    cookies = {}
    status, _, _ = request(args.port, "GET", "/user/login", cookies)
    if status != 200:
        raise RuntimeError(f"login page status={status}")

    form = urllib.parse.urlencode({"user_name": "scm-recovery", "password": password})
    status, location, _ = request(args.port, "POST", "/user/login", cookies, form)
    if status not in {302, 303} or not location:
        raise RuntimeError(f"local admin login status={status}")

    redirect = urllib.parse.urlsplit(location)
    redirect_path = redirect.path or "/"
    if redirect.query:
        redirect_path = f"{redirect_path}?{redirect.query}"
    status, _, body = request(args.port, "GET", redirect_path, cookies)
    if status != 200:
        raise RuntimeError(f"local admin dashboard status={status}")
    session = SessionParser()
    session.feed(body.decode("utf-8", errors="strict"))
    if "/scm-recovery" not in session.links or "/user/logout" not in session.links:
        raise RuntimeError("local admin dashboard session controls are missing")
    print("local-login: username=scm-recovery, session=true")


if __name__ == "__main__":
    main()
