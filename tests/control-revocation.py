#!/usr/bin/env python3
import json
import os
import runpy
import signal
import socket
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

ROOT = Path(sys.argv[1])
SERVER = ROOT / "util" / "control-server.py"
MASTER = "master-fixture-token"
NAMED = "named-fixture-token"


def request(sock, method, path, token, body=None):
    payload = b"" if body is None else json.dumps(body).encode()
    lines = [f"{method} {path} HTTP/1.1", f"Authorization: Bearer {token}"]
    if body is not None:
        lines += ["Content-Type: application/json", f"Content-Length: {len(payload)}"]
    sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode() + payload)
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            break
        data += chunk
    if not data:
        return None
    head, _, rest = data.partition(b"\r\n\r\n")
    length = 0
    for line in head.split(b"\r\n")[1:]:
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":", 1)[1])
    while len(rest) < length:
        rest += sock.recv(65536)
    return int(head.split()[1]), rest[:length]


def receiver(sock, state, tokens):
    mod = runpy.run_path(str(SERVER))
    mod["Handler"].server_version = ""
    mod["Handler"]._authed.__globals__["TOKENS"] = set(tokens)
    mod["Handler"]._handle_apply.__globals__["STATE_DIR"] = state
    mod["Handler"]._handle_upgrade.__globals__["UPGRADE_ENABLED"] = False
    while True:
        mod["Handler"](sock, (None, None), object())


def start_receiver(state, tokens):
    parent, child = socket.socketpair()
    pid = os.fork()
    if pid == 0:
        parent.close()
        try:
            receiver(child, state, tokens)
        except BaseException:
            traceback.print_exc()
        finally:
            os._exit(0)
    child.close()
    parent.settimeout(15)
    return pid, parent


def stop(pid):
    try:
        os.kill(pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass


def consume(state, config):
    processing = state / "processing"
    processing.mkdir(mode=0o700, exist_ok=True)
    script = r'''
source "$1"
OS_TYPE=Linux
RIGFORGE_APPLIANCE=0
SCRIPT_DIR="$2"
CONFIG_JSON="$3"
RIGFORGE_CONTROL_STATE="$4"
RIGFORGE_CONTROL_PROCESSING="$5"
parse_config() { :; }
_fsync_paths() { :; }
stat() { printf '0:0:700\n'; }
_control_fast_path_eligible() { return 1; }
_control_do_apply() { return 0; }
_sweep_config_backups() { :; }
control_apply >/dev/null
'''
    subprocess.run(
        ["bash", "-c", script, "_", str(ROOT / "rigforge.sh"), str(state), str(config), str(state), str(processing)],
        check=True,
    )


def reject_replacement(base, receiver_pid):
    bindir = base / "bin"
    units = base / "units"
    bindir.mkdir()
    units.mkdir()
    (bindir / "sudo").write_text("#!/usr/bin/env bash\nexec \"$@\"\n")
    (bindir / "envsubst").write_text("#!/usr/bin/env bash\ncat\n")
    (bindir / "systemctl").write_text(
        "#!/usr/bin/env bash\n"
        "case \"$1\" in\n"
        "restart) exit 1 ;;\n"
        "stop) kill -TERM \"$RECEIVER_PID\" ;;\n"
        "esac\n"
    )
    for tool in bindir.iterdir():
        tool.chmod(0o755)
    script = r'''
source "$1"
OS_TYPE=Linux
CONTROL_MODE=enabled
CONTROL_UPGRADE=disabled
SYSTEMD_DIR="$2"
SCRIPT_DIR="$3"
REAL_USER=tester
CONTROL_BIND=local
CONTROL_PORT=dynamic
API_ALLOW_FROM=local
RIGFORGE_APPLIANCE=0
install_control >/dev/null 2>&1
'''
    env = dict(os.environ, RECEIVER_PID=str(receiver_pid), PATH=f"{bindir}{os.pathsep}{os.environ['PATH']}")
    return subprocess.run(
        ["bash", "-c", script, "_", str(ROOT / "rigforge.sh"), str(units), str(ROOT)], env=env
    ).returncode


def main():
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        state = base / "state"
        (state / "spool").mkdir(parents=True)
        config = base / "config.json"
        config.write_text(json.dumps({"pools": [{"url": "fixture", "user": "initial"}], "ACCESS_TOKEN": MASTER, "ACCESS_TOKENS": {"bench": NAMED}}))
        (state / "status.json").write_text('{"status":"applied"}')
        pid, client = start_receiver(str(state), {MASTER, NAMED})
        try:
            assert request(client, "GET", "/status", NAMED)[0] == 200
            assert request(client, "POST", "/apply", NAMED, {"pools": [{"url": "fixture", "user": "before-revoke"}]})[0] == 202
            consume(state, config)
            assert json.loads(config.read_text())["pools"][0]["user"] == "before-revoke"
            config.write_text(json.dumps({"pools": [{"url": "fixture", "user": "before-revoke"}], "ACCESS_TOKEN": MASTER}))
            install_rc = reject_replacement(base, pid)
            try:
                stale = request(client, "POST", "/apply", NAMED, {"pools": [{"url": "fixture", "user": "after-revoke"}]})
            except OSError:
                stale = None
            if stale is not None and stale[0] == 202:
                consume(state, config)
            stop(pid)
            pid = 0
            assert stale is None
            assert json.loads(config.read_text())["pools"][0]["user"] == "before-revoke"
            assert install_rc != 0
        finally:
            client.close()
            if pid:
                stop(pid)

        replacement_pid, replacement = start_receiver(str(state), {MASTER})
        try:
            assert request(replacement, "POST", "/apply", NAMED, {"pools": [{"url": "fixture", "user": "revoked"}]})[0] == 401
            assert request(replacement, "POST", "/apply", MASTER, {"pools": [{"url": "fixture", "user": "master"}]})[0] == 202
        finally:
            replacement.close()
            stop(replacement_pid)
        consume(state, config)
        assert json.loads(config.read_text())["pools"][0]["user"] == "master"


if __name__ == "__main__":
    main()
