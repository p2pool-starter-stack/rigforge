#!/usr/bin/env python3
import argparse
import json
import os
import ssl
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import unquote, urlsplit

RELEASE = {
    "tag_name": "v99.0.0",
    "html_url": "https://github.com/p2pool-starter-stack/rigforge/releases/tag/v99.0.0",
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", required=True)
    ap.add_argument("--root", required=True)
    ap.add_argument("--cert", required=True)
    ap.add_argument("--key", required=True)
    args = ap.parse_args()

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def reply(self, status, headers, body):
            self.send_response(status)
            for key, value in headers:
                self.send_header(key, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def handle_any(self):
            length = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(length) if length else b""
            host = (self.headers.get("Host") or "").split(":")[0]
            parts = urlsplit(self.path)
            if host == "api.github.com":
                if parts.path == "/repos/p2pool-starter-stack/rigforge/releases/latest":
                    self.reply(200, [("Content-Type", "application/json")], json.dumps(RELEASE).encode())
                else:
                    self.reply(404, [], b"")
                return
            if host != "github.com":
                self.reply(404, [], b"")
                return
            env = {
                "PATH": os.environ.get("PATH", ""),
                "GIT_PROJECT_ROOT": args.root,
                "GIT_HTTP_EXPORT_ALL": "1",
                "REQUEST_METHOD": self.command,
                "PATH_INFO": unquote(parts.path),
                "QUERY_STRING": parts.query,
                "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                "CONTENT_LENGTH": str(len(body)),
                "REMOTE_ADDR": self.client_address[0],
                "REMOTE_USER": "isolation",
                "HTTP_CONTENT_ENCODING": self.headers.get("Content-Encoding", ""),
                "GIT_PROTOCOL": self.headers.get("Git-Protocol", ""),
            }
            proc = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True)
            head, _, out = proc.stdout.partition(b"\r\n\r\n")
            status, headers = 200, []
            for line in head.decode("latin-1").split("\r\n"):
                key, _, value = line.partition(":")
                if key.lower() == "status":
                    status = int(value.split()[0])
                elif key:
                    headers.append((key, value.strip()))
            self.reply(status, headers, out)

        do_GET = do_POST = do_HEAD = handle_any

        def log_message(self, fmt, *rest):
            sys.stderr.write("%s %s\n" % (self.headers.get("Host"), fmt % rest))

    host, port = args.listen.rsplit(":", 1)
    server = ThreadingHTTPServer((host, int(port)), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(args.cert, args.key)
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
