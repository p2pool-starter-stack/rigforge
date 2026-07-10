#!/usr/bin/env python3
"""RigForge sister-API server (#99/#164): the xmrig model — one persistent process serving
pre-computed state, so a request costs microseconds and can never touch mining performance.

The bodies are produced OFF the request path by the rigforge-api-refresh.timer (the
node_exporter textfile-collector pattern: background job writes files atomically, this serves
them). Python3 stdlib only — Ubuntu's apt stack guarantees python3 on every supported rig.

Wire contract (locked by tests/run.sh): GET-only, fixed routes, application/json, exactly
Content-Type/Content-Length/Connection headers (no server banner), Bearer auth iff ACCESS_TOKEN
is set in config.json (read once at startup; `apply` restarts this unit on rotation). A config
that exists but cannot be parsed is fatal at startup — silently dropping a token would turn a
config typo into an open API.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ROUTES = {
    "/1/summary": "summary.json",
    "/2/summary": "summary.json",
    "/health": "health.json",
    "/tune": "tune.json",
}


def load_token(cfg_path):
    if not os.path.exists(cfg_path):
        return ""
    try:
        with open(cfg_path) as f:
            return (json.load(f).get("ACCESS_TOKEN") or "").strip()
    except Exception:
        sys.exit("api-server: %s is unreadable — refusing to start without a known token posture" % cfg_path)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):  # never log requests: quiet by design, and headers stay out of the journal
        pass

    def _send(self, code, reason, body):
        # send_response_only: the stock send_response adds Server/Date banners the wire contract forbids.
        self.send_response_only(code, reason)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_GET(self):
        if TOKEN:
            auth = (self.headers.get("Authorization") or "").strip()
            if auth != "Bearer " + TOKEN:
                return self._send(401, "Unauthorized", b'{"error":"unauthorized"}')
        name = ROUTES.get(self.path.split("?", 1)[0])
        if name is None:
            return self._send(404, "Not Found", b'{"error":"not found"}')
        try:
            with open(os.path.join(DATA_DIR, name), "rb") as f:
                body = f.read()
        except OSError:
            return self._send(503, "Service Unavailable", b'{"error":"warming up - first refresh pending"}')
        self._send(200, "OK", body)

    def _read_only(self):
        self._send(405, "Method Not Allowed", b'{"error":"read-only API"}')

    do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _read_only


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit("usage: api-server.py <bind> <port> <data-dir> <config.json>")
    bind, port, DATA_DIR, cfg = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    TOKEN = load_token(cfg)
    # Single-threaded on purpose: requests serialize naturally, and serving pre-built bytes takes
    # microseconds — concurrency would only add ways to compete with the miner.
    HTTPServer((bind, port), Handler).serve_forever()
