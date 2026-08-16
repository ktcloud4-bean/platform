#!/usr/bin/env python3
"""DEMO-ONPREM-01 전용 합성 portal/내부 API. 입력값은 로그에 남기지 않는다."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
import sqlite3
from urllib.parse import parse_qs, urlsplit


MODE = os.environ.get("DEMO_MODE", "portal")
SYNTHETIC_ROWS = (
    ("SYN-1001", "synthetic.alpha@example.invalid"),
    ("SYN-1002", "synthetic.beta@example.invalid"),
    ("SYN-1003", "synthetic.gamma@example.invalid"),
)


class Handler(BaseHTTPRequestHandler):
    server_version = "demo-onprem-01"

    def log_message(self, _format, *_args):
        # 요청 query/header/body는 원천적으로 기록하지 않는다.
        path = urlsplit(self.path).path
        print(json.dumps({"marker": "DEMO_HTTP", "mode": MODE, "path": path}), flush=True)

    def send_json(self, status, value):
        body = json.dumps(value, separators=(",", ":"), sort_keys=True).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlsplit(self.path)
        if parsed.path == "/healthz":
            self.send_json(200, {"status": "ok"})
            return
        if MODE == "internal" and parsed.path == "/flag":
            self.send_json(200, {
                "marker": "DEMO-LATERAL-FLAG",
                "value": "SYNTHETIC-FLAG-DEMO-ONPREM-01",
            })
            return
        if MODE != "portal":
            self.send_json(404, {"error": "not_found"})
            return
        if parsed.path == "/demo-onprem/account/control":
            self.send_json(200, {"marker": "DEMO-ACCOUNT-CONTROL-200"})
            return
        if parsed.path == "/demo-onprem/account/restricted":
            # 이 응답에 도달하기 전에 Pomerium이 platform-privileged를 판정한다.
            self.send_json(200, {"marker": "DEMO-ACCOUNT-RESTRICTED-UPSTREAM"})
            return
        if parsed.path in {"/demo-onprem/sqli/control", "/demo-onprem/sqli/waf"}:
            term = parse_qs(parsed.query, keep_blank_values=True).get("q", [""])[0]
            request_id = self.headers.get("X-Demo-Request-ID", "missing")
            database = sqlite3.connect(":memory:")
            database.execute("CREATE TABLE customers (customer_id TEXT, email TEXT)")
            database.executemany("INSERT INTO customers VALUES (?, ?)", SYNTHETIC_ROWS)
            # 실제 취약점 시연 경계: 같은 고정 payload를 control/WAF 양쪽에 전달한다.
            rows = database.execute(
                "SELECT customer_id, email FROM customers WHERE email LIKE '%" + term + "%'"
            ).fetchall()
            database.close()
            self.send_json(200, {
                "marker": "DEMO-SQLI-CONTROL-200",
                "request_id": request_id,
                "rows": [{"customer_id": row[0], "email": row[1]} for row in rows],
            })
            return
        self.send_json(404, {"error": "not_found"})


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
