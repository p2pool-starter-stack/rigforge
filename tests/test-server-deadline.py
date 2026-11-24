#!/usr/bin/env python3
import os
import socket
import sys
import tempfile
import threading
import time
import types
from http.server import HTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEADLINE = 1
failures = []


def check(name, ok, detail=""):
    print(("  ok    " if ok else "  FAIL  ") + name + ("" if ok or not detail else ": " + detail))
    if not ok:
        failures.append(name)


def load(script, **settings):
    with open(os.path.join(ROOT, "util", script)) as f:
        source = f.read().split("if __name__")[0]
    module = types.ModuleType(script)
    exec(compile(source, script, "exec"), module.__dict__)
    module.__dict__.update(settings)
    module.Handler.timeout = DEADLINE
    return module


def answered(port, wait):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=wait) as client:
            client.sendall(b"GET /health HTTP/1.1\r\nHost: rig\r\n\r\n")
            return client.recv(16).startswith(b"HTTP/1.1 ")
    except OSError:
        return False


def seconds_until_dropped(client, limit, opening=b""):
    start = time.monotonic()
    client.settimeout(0.2)
    client.sendall(opening)
    while time.monotonic() - start < limit:
        try:
            client.sendall(b"X")
            if client.recv(1) == b"":
                return time.monotonic() - start
        except socket.timeout:
            continue
        except OSError:
            return time.monotonic() - start
    return None


APPLY = b"POST /apply HTTP/1.1\r\nHost: rig\r\nAuthorization: Bearer t\r\nContent-Type: application/json\r\nContent-Length: 4096\r\n\r\n"


def drip(label, module, opening=b""):
    server = HTTPServer(("127.0.0.1", 0), module.Handler)
    port = server.server_address[1]
    noisy = []
    server.handle_error = lambda *request: noisy.append(request)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    check(label + ": answers a normal request", answered(port, 5))
    slow = socket.create_connection(("127.0.0.1", port), timeout=5)
    dropped = seconds_until_dropped(slow, DEADLINE * 8, opening)
    slow.close()
    check(label + ": a dripping client is dropped at the deadline", dropped is not None, "still connected after %d s" % (DEADLINE * 8))
    check(label + ": answers again afterwards", answered(port, 5))
    check(label + ": the drop writes no traceback", not noisy)
    server.shutdown()
    server.server_close()


def slow_staging(module):
    stage = module.stage_change

    def slow_stage(*args, **kwargs):
        time.sleep(DEADLINE * 1.5)
        return stage(*args, **kwargs)

    module.stage_change = slow_stage
    server = HTTPServer(("127.0.0.1", 0), module.Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    body = b'{"watchdog_interval_min": 5}'
    request = APPLY.replace(b"Content-Length: 4096", b"Content-Length: %d" % len(body)) + body
    with socket.create_connection(("127.0.0.1", server.server_address[1]), timeout=DEADLINE * 8) as client:
        client.sendall(request)
        reply = client.recv(32)
    check("control server: a change still being staged at the deadline is answered", reply.startswith(b"HTTP/1.1 202"), repr(reply))
    server.shutdown()
    server.server_close()


with tempfile.TemporaryDirectory() as state:
    drip("status server", load("api-server.py", TOKENS=set(), READ_TOKENS=set(), DATA_DIR=state))
    drip("control server", load("control-server.py", TOKENS=set(), STATE_DIR=state, UPGRADE_ENABLED=False))
    drip("control server, dripped body", load("control-server.py", TOKENS={"t"}, STATE_DIR=state, UPGRADE_ENABLED=False), APPLY)
    slow_staging(load("control-server.py", TOKENS={"t"}, STATE_DIR=state, UPGRADE_ENABLED=False))

print("server deadline: %d failed" % len(failures))
sys.exit(1 if failures else 0)
