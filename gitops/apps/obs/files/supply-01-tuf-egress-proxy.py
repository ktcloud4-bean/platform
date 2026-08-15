#!/usr/bin/env python3
"""SUPPLY-01-FIX-01: EKS Kyverno TUF metadata 전용 CONNECT proxy."""

import ipaddress
import selectors
import socket
import socketserver

EXPECTED_HOST = "tuf-repo-cdn.sigstore.dev"
EXPECTED_PORT = 443
LISTEN_ADDRESS = "10.10.20.12"
LISTEN_PORT = 8445
EGRESS_ADDRESS = "10.10.20.12"
ALLOWED_CLIENTS = tuple(
    ipaddress.ip_network(cidr)
    for cidr in ("10.20.10.0/24", "10.20.20.0/24")
)
MAX_HEADER = 16384


def allowed_client(address):
    source = ipaddress.ip_address(address)
    return any(source in network for network in ALLOWED_CLIENTS)


def read_request(sock):
    data = bytearray()
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(4096)
        if not chunk:
            return None
        data.extend(chunk)
        if len(data) > MAX_HEADER:
            return None
    return bytes(data)


def is_expected_connect(request):
    try:
        line = request.split(b"\r\n", 1)[0].decode("ascii")
        method, authority, version = line.split(" ", 2)
        host, port = authority.rsplit(":", 1)
    except (UnicodeDecodeError, ValueError):
        return False
    return (
        method == "CONNECT"
        and version.startswith("HTTP/")
        and host.lower() == EXPECTED_HOST
        and port == str(EXPECTED_PORT)
    )


def connect_tuf():
    addresses = {
        item[4][0]
        for item in socket.getaddrinfo(
            EXPECTED_HOST, EXPECTED_PORT, family=socket.AF_INET, type=socket.SOCK_STREAM
        )
    }
    last_error = None
    for address in sorted(addresses):
        upstream = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            upstream.settimeout(10)
            upstream.bind((EGRESS_ADDRESS, 0))
            upstream.connect((address, EXPECTED_PORT))
            upstream.settimeout(None)
            return upstream
        except OSError as error:
            last_error = error
            upstream.close()
    raise OSError("TUF upstream connection failed") from last_error


def relay(client, upstream):
    selector = selectors.DefaultSelector()
    selector.register(client, selectors.EVENT_READ, upstream)
    selector.register(upstream, selectors.EVENT_READ, client)
    try:
        while True:
            for key, _ in selector.select():
                data = key.fileobj.recv(65536)
                if not data:
                    return
                key.data.sendall(data)
    finally:
        selector.close()


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        if not allowed_client(self.client_address[0]):
            return
        try:
            request = read_request(self.request)
            if not request:
                return
            if not is_expected_connect(request):
                self.request.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                return
            with connect_tuf() as upstream:
                self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
                relay(self.request, upstream)
        except (OSError, ValueError):
            return


class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with Server((LISTEN_ADDRESS, LISTEN_PORT), Handler) as server:
        server.serve_forever()
