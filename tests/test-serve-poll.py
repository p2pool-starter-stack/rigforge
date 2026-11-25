#!/usr/bin/env python3
import ast
import os
import signal
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
SITES = {"util/api-server.py": 2, "util/control-server.py": 1}


def serve_calls(path):
    tree = ast.parse((root / path).read_text())
    return [
        n
        for n in ast.walk(tree)
        if isinstance(n, ast.Call)
        and isinstance(n.func, ast.Attribute)
        and n.func.attr == "serve_forever"
    ]


for path, expected in SITES.items():
    calls = serve_calls(path)
    found = "%s: expected %d serve_forever calls, found %d" % (path, expected, len(calls))
    assert len(calls) == expected, found
    for call in calls:
        kw = {k.arg: k.value for k in call.keywords}
        value = kw.get("poll_interval")
        where = "%s:%d serve_forever needs poll_interval >= 5" % (path, call.lineno)
        assert isinstance(value, ast.Constant) and value.value >= 5, where
print("PASS: every serve_forever call passes poll_interval of at least 5")


def free_port(bind):
    with socket.socket() as reserve:
        reserve.bind((bind, 0))
        return reserve.getsockname()[1]


bind = socket.inet_ntoa(bytes((127, 0, 0, 1)))
with tempfile.TemporaryDirectory() as work:
    work = Path(work)
    config = work / "config.json"
    config.write_text('{"ACCESS_TOKEN":"master-fixture"}')
    (work / "data").mkdir()
    cases = (
        ("util/api-server.py", "/health", b"HTTP/1."),
        ("util/control-server.py", "/status", b"HTTP/1.1 401"),
    )
    for script, route, expect in cases:
        port = free_port(bind)
        state = work / ("state-" + Path(script).stem)
        data = state if "control" in script else work / "data"
        args = [sys.executable, str(root / script), bind, str(port), str(data), str(config)]
        env = {k: v for k, v in os.environ.items() if k != "NOTIFY_SOCKET"}
        proc = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 15
            while True:
                try:
                    client = socket.create_connection((bind, port), timeout=3)
                    break
                except OSError:
                    assert proc.poll() is None and time.monotonic() < deadline, script + " did not start"
                    time.sleep(0.05)
            with client:
                time.sleep(0.5)
                start = time.monotonic()
                client.sendall(("GET %s HTTP/1.1\r\nConnection: close\r\n\r\n" % route).encode())
                client.settimeout(3)
                assert client.recv(1024).startswith(expect), script + " gave an unexpected answer"
                assert time.monotonic() - start < 3, script + " answered late"
            start = time.monotonic()
            proc.send_signal(signal.SIGTERM)
            proc.wait(timeout=3)
            assert time.monotonic() - start < 3, script + " stopped late"
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
        print("PASS: %s answers a request and ends on SIGTERM promptly" % script)
