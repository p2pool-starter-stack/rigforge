#!/usr/bin/env python3
import os
import socket
import subprocess
import sys
import tempfile
from pathlib import Path


root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
unit = (root / "systemd/rigforge-control.service.template").read_text()
assert "Type=notify\n" in unit, "receiver start must wait for its main process to signal readiness"
assert "NotifyAccess=main\n" in unit
assert "TimeoutStartSec=15\n" in unit

with tempfile.TemporaryDirectory() as work:
    work = Path(work)
    config = work / "config.json"
    config.write_text('{"ACCESS_TOKEN":"master-fixture"}')
    with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as notify:
        notify.bind(str(work / "notify"))
        notify.settimeout(15)
        env = dict(os.environ, NOTIFY_SOCKET=str(work / "notify"))
        bind = socket.inet_ntoa(bytes((127, 0, 0, 1)))
        with socket.socket() as reserve:
            reserve.bind((bind, 0))
            port = reserve.getsockname()[1]
        args = [sys.executable, str(root / "util/control-server.py"), bind, str(port), str(work / "state"), str(config)]
        proc = subprocess.Popen(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        try:
            assert notify.recv(128) == b"READY=1"
            with socket.create_connection((bind, port), timeout=3) as client:
                client.sendall(b"GET /status HTTP/1.1\r\nConnection: close\r\n\r\n")
                assert client.recv(1024).startswith(b"HTTP/1.1 401")
            print("PASS: the replacement process binds and loads auth before readiness")
        finally:
            proc.terminate()
            proc.communicate(timeout=5)

        with socket.socket() as occupied:
            occupied.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            occupied.bind((bind, port))
            occupied.listen()
            failed = subprocess.run(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=15)
            assert failed.returncode != 0
        config.write_text("invalid-json")
        failed = subprocess.run(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=15)
        assert failed.returncode != 0
        notify.settimeout(0.1)
        try:
            notify.recv(128)
            raise AssertionError("a failed replacement signaled readiness")
        except socket.timeout:
            pass
        print("PASS: bind and credential failures never signal readiness")

import importlib.util
import json

spec = importlib.util.spec_from_file_location("control_server_donation", root / "util/control-server.py")
cs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cs)


def receiver_verdict(change, cfg_path):
    cs.CFG_PATH = str(cfg_path)
    return "reject" if cs.donation_tor_reasons(change) else "allow"


with tempfile.TemporaryDirectory() as work2:
    cfg_tor = Path(work2) / "tor.json"
    cfg_tor.write_text('{"pools":[{"url":"h:3333"}],"tor_socks5":"127.0.0.1:9050"}')
    cfg_plain = Path(work2) / "plain.json"
    cfg_plain.write_text('{"pools":[{"url":"h:3333"}]}')
    cfg_null = Path(work2) / "null.json"
    cfg_null.write_text('{"pools":[{"url":"h:3333"}],"tor_socks5":null}')
    parity = [
        (cfg_tor, '{"DONATION":5}', "reject"),
        (cfg_tor, '{"DONATION":0}', "allow"),
        (cfg_tor, '{"DONATION":"5"}', "reject"),
        (cfg_tor, '{"DONATION":"x"}', "reject"),
        (cfg_tor, '{"DONATION":null}', "allow"),
        (cfg_tor, '{"DONATION":false}', "reject"),
        (cfg_tor, '{"autotune":"performance"}', "allow"),
        (cfg_plain, '{"DONATION":5}', "allow"),
        (cfg_null, '{"DONATION":5}', "allow"),
    ]
    for cfg, change, want in parity:
        got = receiver_verdict(json.loads(change), cfg)
        assert got == want, f"receiver {change} on {cfg.name}: want {want}, got {got}"
    unreadable = Path(work2) / "broken.json"
    unreadable.write_text("invalid")
    assert receiver_verdict({"DONATION": 5}, unreadable) == "reject", "DONATION must fail closed on an unreadable config"
    refused = cs.donation_tor_reasons({"DONATION": 5})
    assert any("tor_socks5" in r for r in refused), f"refusal must name the setting: {refused}"
print("PASS: the control receiver refuses DONATION above 0 while tor_socks5 is set")
