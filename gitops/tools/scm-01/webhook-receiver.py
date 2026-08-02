#!/usr/bin/env python3
"""SCM-01 임시 receiver: X-Gitea-Signature HMAC-SHA256만 판정한다."""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import hmac
from pathlib import Path


SECRET = Path("/receiver-secret/webhook-secret").read_bytes().strip()


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/healthz":
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        expected = hmac.new(SECRET, body, hashlib.sha256).hexdigest()
        supplied = self.headers.get("X-Gitea-Signature", "")
        target = self.headers.get("X-Gitea-Hook-Installation-Target-Type", "")
        valid = hmac.compare_digest(expected, supplied) and target == "repository"
        print(
            f"webhook-signature={'valid' if valid else 'invalid'} target={target}",
            flush=True,
        )
        self.send_response(204 if valid else 403)
        self.end_headers()

    def log_message(self, *_):
        return


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
