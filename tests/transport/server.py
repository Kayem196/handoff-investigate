"""Loopback-only fixture for the standalone Graph SDK transport probe."""
import gzip
import json
import sys
import threading
import time
from collections import Counter
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

counts = Counter()
observations = []
fixture_authorization = "Bearer fictional-local-transport-probe"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path != "/stats":
            counts[path] += 1
            observations.append({
                "path": path,
                "hasAuthorization": bool(self.headers.get("Authorization")),
                "hasFixtureAuthorization": self.headers.get("Authorization") == fixture_authorization,
            })
        status, headers, body = 200, {}, b'{"value":[]}'
        if path == "/collector-groups":
            body = json.dumps({
                "value": [{"id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", "displayName": "Same fixture name"},
                          {"id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee", "displayName": "Same fixture name"}],
                "@odata.nextLink": "https://graph.microsoft.com/v1.0/groups?$skiptoken=next",
            }).encode()
        elif path in ("/collector-group", "/collector-group-delayed"):
            if path.endswith("-delayed"):
                time.sleep(0.6)
            body = b'{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}'
        elif path in ("/collector-ca", "/collector-ca-delayed"):
            if path.endswith("-delayed"):
                time.sleep(0.6)
            body = json.dumps({
                "value": [{"id": "cccccccc-cccc-cccc-cccc-cccccccccccc", "state": "disabled",
                           "conditions": {"users": {"includeGroups": ["bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"]}}}],
                "@odata.nextLink": "https://graph.microsoft.com/v1.0/identity/conditionalAccess/policies?$skiptoken=next",
            }).encode()
        elif path == "/exact-limit":
            body = b'{"value":[]}' + b" " * (1024 - len(b'{"value":[]}'))
        elif path == "/malformed":
            body = b'{"value":'
        elif path == "/stats":
            body = json.dumps({"counts": dict(counts), "observations": observations}).encode()
        elif (path == "/retry" and counts[path] < 3) or path == "/always503":
            status, headers, body = 503, {"Retry-After": "0"}, b'{"error":{"code":"synthetic_unavailable"}}'
        elif path == "/always401":
            status, body = 401, b'{"error":{"code":"synthetic_unauthorized"}}'
        elif path in ("/slow-header", "/cancel"):
            time.sleep(2 if path == "/slow-header" else 5)
        elif path.startswith("/redirect-status-"):
            status = int(path.rsplit("-", 1)[1])
            headers["Location"] = "/captured-status"
        elif path.startswith("/redirect-"):
            status = 302
            headers["Location"] = {
                "/redirect-same": "/captured-same",
                "/redirect-host": f"http://localhost:{self.server.server_port}/captured-host",
                "/redirect-port": f"http://127.0.0.1:{other.server_port}/captured-port",
            }[path]
        elif path in ("/large", "/large-chunked", "/gzip-large"):
            body = b'{"value":[{"id":"synthetic","padding":"' + b"x" * (8 * 1024 * 1024) + b'"}]}'
            if path == "/gzip-large":
                body = gzip.compress(body)
                headers["Content-Encoding"] = "gzip"
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Transfer-Encoding" if path == "/large-chunked" else "Content-Length",
                         "chunked" if path == "/large-chunked" else str(len(body)))
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        try:
            if path == "/slow-body":
                self.wfile.write(body[:1])
                self.wfile.flush()
                time.sleep(2)
                self.wfile.write(body[1:])
            elif path == "/large-chunked":
                for offset in range(0, len(body), 65536):
                    chunk = body[offset:offset + 65536]
                    self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                self.wfile.write(b"0\r\n\r\n")
            else:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    other = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=other.serve_forever, daemon=True).start()
    Path(sys.argv[1]).write_text(json.dumps({
        "origin": f"http://127.0.0.1:{server.server_port}",
        "other": f"http://127.0.0.1:{other.server_port}",
    }), encoding="utf-8")
    try:
        server.serve_forever()
    finally:
        server.server_close()
        other.shutdown()
        other.server_close()
