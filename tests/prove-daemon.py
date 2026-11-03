#!/usr/bin/env python3

import argparse, hashlib, json, os, signal, shlex, socket
import subprocess, sys, tempfile, threading, time
import http.client
from pathlib import Path
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BLOCK_HASHING_BLOB = (
    "0e0ed286da8006ecdc1aab3033cf1716c52f13f9d8ae0051615a2453643de946"
    "43b550d543becd00000000d130d22cf308b308498bbc16e2e955e7dbd691e6a8f"
    "ab805f98ad82e6faa8bcc06"
)
BLOCK_TEMPLATE_BLOB = (
    "0e0ed286da8006ecdc1aab3033cf1716c52f13f9d8ae0051615a2453643de946"
    "43b550d543becd0000000002abc78b0101ffefc68b0101fcfcf0d4b422025014"
    "bb4a1eade6622fd781cb1063381cad396efa69719b41aa28b4fce8c7ad4b5f01"
    "9ce1dc670456b24a5e03c2d9058a2df10fec779e2579753b1847b74ee644f16b"
    "023c000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000005"
    "1399a1bc46a846474f5b33db24eae173a26393b976054ee14f9feefe99925233"
    "802867097564c9db7a36af5bb5ed33ab46e63092bd8d32cef121608c3258edd5"
    "5562812e21cc7e3ac73045745a72f7d74581d9a0849d6f30e8b2923171253e86"
    "4f4e9ddea3acb5bc755f1c4a878130a70c26297540bc0b7a57affb6b35c1f03d"
    "8dbd54ece8457531f8cba15bb74516779c01193e212050423020e45aa2c15dcb"
)
HEIGHT = 2286447
PREVIOUS_HASH = "ecdc1aab3033cf1716c52f13f9d8ae0051615a2453643de94643b550d543becd"
SEED_HASH = "d432f499205150873b2572b5f033c9c6e4b7c6f3394bd2dd93822cd7085e7307"
BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
BASE58_SIZES = (0, 2, 3, 5, 6, 7, 9, 10, 11)


def keccak(data):
    rotation = (
        (0, 36, 3, 41, 18),
        (1, 44, 10, 45, 2),
        (62, 6, 43, 15, 61),
        (28, 55, 25, 21, 56),
        (27, 20, 39, 8, 14),
    )
    constants = (
        0x0000000000000001, 0x0000000000008082, 0x800000000000808A,
        0x8000000080008000, 0x000000000000808B, 0x0000000080000001,
        0x8000000080008081, 0x8000000000008009, 0x000000000000008A,
        0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
        0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
        0x8000000000008003, 0x8000000000008002, 0x8000000000000080,
        0x000000000000800A, 0x800000008000000A, 0x8000000080008081,
        0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
    )
    rate = 136
    padded = bytearray(data)
    padded.append(1)
    padded.extend(b"\0" * ((rate - len(padded) % rate - 1) % rate))
    padded.append(128)
    state = [0] * 25
    mask = (1 << 64) - 1
    for offset in range(0, len(padded), rate):
        block = padded[offset:offset + rate]
        for index in range(rate // 8):
            state[index] ^= int.from_bytes(block[index * 8:index * 8 + 8], "little")
        for constant in constants:
            column = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] for x in range(5)]
            delta = [column[(x - 1) % 5] ^ ((column[(x + 1) % 5] << 1 | column[(x + 1) % 5] >> 63) & mask) for x in range(5)]
            for x in range(5):
                for y in range(5):
                    state[x + 5 * y] ^= delta[x]
            moved = [0] * 25
            for x in range(5):
                for y in range(5):
                    value = state[x + 5 * y]
                    shift = rotation[x][y]
                    moved[y + 5 * ((2 * x + 3 * y) % 5)] = ((value << shift) | (value >> ((64 - shift) % 64))) & mask
            for x in range(5):
                for y in range(5):
                    state[x + 5 * y] = moved[x + 5 * y] ^ ((~moved[(x + 1) % 5 + 5 * y]) & moved[(x + 2) % 5 + 5 * y])
            state[0] ^= constant
    return b"".join(value.to_bytes(8, "little") for value in state)[:32]

def encode_block(block):
    size = BASE58_SIZES[len(block)]
    value = int.from_bytes(block, "big")
    output = [BASE58[0]] * size
    for index in range(size - 1, -1, -1):
        value, digit = divmod(value, 58)
        output[index] = BASE58[digit]
    return "".join(output)


def synthetic_address():
    identity = hashlib.sha512(b"rigforge daemon proof identity").digest()
    raw = bytes((18,)) + identity
    raw += keccak(raw)[:4]
    return "".join(encode_block(raw[index:index + 8]) for index in range(0, len(raw), 8))


class StubHandler(BaseHTTPRequestHandler):
    requests = 0
    slow = False

    def log_message(self, *_args):
        return

    def send_json(self, value):
        payload = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.send_json({"height": HEIGHT, "hash": PREVIOUS_HASH})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        request = json.loads(self.rfile.read(length))
        method = request.get("method")
        if method == "get_info" and self.slow:
            time.sleep(6)
        if method == "getblocktemplate":
            type(self).requests += 1
            result = {
                "blockhashing_blob": BLOCK_HASHING_BLOB,
                "blocktemplate_blob": BLOCK_TEMPLATE_BLOB,
                "difficulty": 226807339040,
                "height": HEIGHT,
                "prev_hash": PREVIOUS_HASH,
                "reserved_offset": 130,
                "seed_hash": SEED_HASH,
                "status": "OK",
            }
        else:
            result = {
                "height": HEIGHT,
                "target_height": HEIGHT,
                "synchronized": True,
                "top_block_hash": PREVIOUS_HASH,
                "status": "OK",
            }
        self.send_json({"jsonrpc": "2.0", "id": request.get("id", 0), "result": result})


class StubServer(ThreadingHTTPServer):
    def handle_error(self, _request, _client_address):
        return
class SlowStubHandler(StubHandler):
    slow = True


def pipe_json(config):
    descriptor, writer = os.pipe()
    def write():
        with os.fdopen(writer, "w") as stream:
            json.dump(config, stream)
    threading.Thread(target=write, daemon=True).start()
    return descriptor
def run_config(binary, config, *arguments, timeout=30):
    descriptor = pipe_json(config)
    try:
        return subprocess.run(
            [binary, "-c", f"/dev/fd/{descriptor}", *arguments],
            pass_fds=(descriptor,), capture_output=True, text=True, timeout=timeout,
        )
    finally:
        os.close(descriptor)
def reserve_port(host):
    with socket.socket() as listener:
        listener.bind((host, 0))
        return listener.getsockname()[1]
def render_config(host):
    repository = Path(__file__).resolve().parents[1]
    operator = json.dumps({
        "pools": [{"url": f"daemon+http://{host}:{reserve_port(host)}", "user": synthetic_address(), "daemon": True,
                   "daemon-poll-interval": 250, "daemon-job-timeout": 3000}], "DONATION": 0,
    })
    shell = r'''
set -e; source "$1/rigforge.sh"; CONFIG_JSON="$1/VERSION"
jq() { local item; local -a kept=(); for item in "$@"; do
    if [ "$item" = "$CONFIG_JSON" ]; then command jq "${kept[@]}" <<<"$PROOF_OPERATOR_CONFIG"; return; fi
    kept+=("$item")
done; command jq "${kept[@]}"; }
sysctl() { case "$*" in *machdep.cpu.brand_string*) printf '%s\n' 'Proof CPU';; *hw.ncpu*) printf '%s\n' 1;; *) command sysctl "$@";; esac; }
sudo() { "$@"; }; parse_config >/dev/null; WORKER_ROOT="$PROOF_OUTPUT_DIR/worker"; mkdir -p "$WORKER_ROOT"; cd "$PROOF_OUTPUT_DIR"; generate_xmrig_config >/dev/null
'''
    with tempfile.TemporaryDirectory(prefix="rigforge-daemon-render-") as directory:
        fifo = os.path.join(directory, "config.json")
        os.mkfifo(fifo)
        reader = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
        env = {**os.environ, "PROOF_OPERATOR_CONFIG": operator, "PROOF_OUTPUT_DIR": directory,
               "RIGFORGE_APPLIANCE": "1", "WORKER_ROOT": os.path.join(directory, "worker")}
        process = subprocess.Popen(["bash", "-c", shell, "proof", str(repository)], env=env)
        try:
            status = process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.terminate()
            try: process.wait(timeout=3)
            except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=2)
            os.close(reader)
            raise RuntimeError("RigForge renderer timed out")
        with os.fdopen(reader) as rendered:
            config = json.load(rendered)
        if status:
            raise RuntimeError("RigForge failed to render the daemon proof config")
        return config
def get_summary(host, port, token):
    connection = http.client.HTTPConnection(host, port, timeout=1)
    try:
        connection.request("GET", "/2/summary", headers={"Authorization": f"Bearer {token}"})
        response = connection.getresponse()
        return json.loads(response.read()) if response.status == 200 else None
    except OSError:
        return None
    finally:
        connection.close()


def run_doctor(config, host, api_port, api_token, slow=False):
    api_command = " ".join(map(shlex.quote, (
        "curl", "-fsS", "--header", f"Authorization: Bearer {api_token}",
        f"http://{host}:{api_port}/2/summary",
    )))
    repository = Path(__file__).resolve().parents[1]
    pool = next(pool for pool in config["pools"] if pool.get("enabled", True) and pool.get("daemon"))
    shell = """
systemctl() { return 0; }
source "$1"
OS_TYPE=Linux
CONFIG_JSON="$2"
API_CMD="$3"
MEMINFO=/dev/null
jq() {
    local item; local -a kept=()
    for item in "$@"; do
        if [ "$item" = "$CONFIG_JSON" ]; then command jq "${kept[@]}" <<<"$PROOF_DOCTOR_CONFIG"; return; fi
        kept+=("$item")
    done
    command jq "${kept[@]}"
}
if [ "${PROOF_SLOW:-}" = 1 ]; then
    SECONDS=0
    _doctor_daemon_status "$(_daemon_node_status "$4")" || true
    printf 'PROOF_ELAPSED=%s\n' "$SECONDS"
else
    doctor
fi
"""
    started = time.monotonic()
    result = subprocess.run(
        ["bash", "-c", shell, "proof", str(repository / "rigforge.sh"), str(repository / "VERSION"),
         api_command, json.dumps(pool)], capture_output=True, text=True,
        env={**os.environ, "PROOF_DOCTOR_CONFIG": json.dumps(config), "PROOF_SLOW": "1" if slow else ""},
        timeout=25,
    )
    output = result.stdout + result.stderr
    measured = time.monotonic() - started
    if slow:
        marker = next(line for line in output.splitlines() if line.startswith("PROOF_ELAPSED="))
        measured = float(marker.split("=", 1)[1])
    return output, measured


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runtime", type=int, default=30)
    args = parser.parse_args()
    if not 1 <= args.runtime <= 120:
        parser.error("--runtime must be between 1 and 120 seconds")
    binary = os.environ.get("XMRIG_BIN")
    if not binary or not os.access(binary, os.X_OK):
        parser.error("XMRIG_BIN must name an executable pinned XMRig binary")
    host = socket.getaddrinfo(None, 0, socket.AF_INET, socket.SOCK_STREAM)[0][4][0]
    config = render_config(host)
    source_pool = next(pool for pool in config["pools"] if pool.get("enabled", True) and pool.get("daemon"))
    authority = source_pool["url"].split("://", 1)[-1]
    dry_run_forms = {}
    for name, url in (
        ("daemon+http", f"daemon+http://{authority}"),
        ("daemon+https", f"daemon+https://{authority}"),
        ("bare+daemon", authority),
    ):
        candidate = json.loads(json.dumps(config))
        pool = next(pool for pool in candidate["pools"] if pool.get("enabled", True) and pool.get("daemon"))
        pool.update({"url": url, "daemon": True})
        checked = run_config(binary, candidate, "--dry-run", "--no-color")
        if checked.returncode:
            sys.stderr.write(checked.stdout + checked.stderr)
            raise SystemExit(f"{name} config failed XMRig --dry-run")
        if not any(line.split()[-2:] == ["DONATE", "0%"] for line in checked.stdout.splitlines()):
            raise SystemExit(f"{name} config did not prove zero donation")
        dry_run_forms[name] = "pass"

    StubHandler.requests = 0
    StubHandler.slow = False
    server = StubServer((host, 0), StubHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    runtime = json.loads(json.dumps(config))
    daemon_pool = next(pool for pool in runtime["pools"] if pool.get("enabled", True) and pool.get("daemon"))
    for pool in runtime["pools"]:
        pool["enabled"] = pool is daemon_pool
    expected_pool = f"{host}:{server.server_port}"
    daemon_pool.update({
        "url": f"daemon+http://{expected_pool}",
        "user": synthetic_address(),
        "daemon": True,
        "daemon-poll-interval": 250,
        "daemon-job-timeout": 3000,
    })
    api_port = reserve_port(host)
    api_token = os.urandom(24).hex()
    runtime.update({
        "autosave": False,
        "background": False,
        "colors": False,
        "cpu": {"enabled": True, "huge-pages": False, "rx": [0]},
        "opencl": False,
        "cuda": False,
        "donate-level": 0,
        "log-file": None,
        "http": {"enabled": True, "host": host, "port": api_port, "restricted": True, "access-token": api_token},
    })
    runtime_dir = tempfile.TemporaryDirectory(prefix="rigforge-daemon-runtime-")
    runtime_path = os.path.join(runtime_dir.name, "config.json")
    os.mkfifo(runtime_path)
    def write_runtime():
        with open(runtime_path, "w") as stream:
            json.dump(runtime, stream)
    output = []
    process = slow_server = None
    try:
        writer = threading.Thread(target=write_runtime, daemon=True)
        writer.start()
        process = subprocess.Popen([binary, "-c", runtime_path, "--no-color"],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        writer.join(timeout=10)
        if writer.is_alive():
            raise RuntimeError("XMRig did not open its config FIFO")
        os.unlink(runtime_path)
        threading.Thread(target=lambda: output.extend(process.stdout), daemon=True).start()
        deadline = time.monotonic() + args.runtime
        summary = None
        while time.monotonic() < deadline and process.poll() is None:
            summary = get_summary(host, api_port, api_token)
            if summary and summary.get("donate_level") != 0:
                raise RuntimeError(f"XMRig donate level is not zero: {summary.get('donate_level')!r}")
            if (summary and summary.get("connection", {}).get("uptime", 0) >= 0
                    and StubHandler.requests and "new job" in "".join(output)):
                break
            time.sleep(0.25)
        if process.poll() is not None:
            raise RuntimeError(f"XMRig exited ({process.returncode}) before receiving a daemon job\n" + "".join(output))
        if not summary or summary.get("connection", {}).get("pool") != expected_pool:
            raise RuntimeError(f"XMRig summary did not report a live connection: {summary!r}\n" + "".join(output))
        if summary.get("algo") != "rx/0" or summary["connection"].get("diff", 0) <= 0:
            raise RuntimeError(f"XMRig summary did not accept the canned job: {summary!r}")
        if StubHandler.requests < 1:
            raise RuntimeError("XMRig did not fetch a block template")
        if "new job" not in "".join(output):
            raise RuntimeError("XMRig did not log an accepted daemon job\n" + "".join(output))
        doctor, _ = run_doctor(runtime, host, api_port, api_token)
        if f"node connection live: height {HEIGHT} (synced)" not in doctor:
            raise RuntimeError("RigForge doctor did not report the live node\n" + doctor)
        slow_server = StubServer((host, 0), SlowStubHandler)
        threading.Thread(target=slow_server.serve_forever, daemon=True).start()
        slow_runtime = json.loads(json.dumps(runtime))
        next(pool for pool in slow_runtime["pools"] if pool.get("daemon"))["url"] = (
            f"daemon+http://{host}:{slow_server.server_port}"
        )
        slow_doctor, slow_elapsed = run_doctor(slow_runtime, host, api_port, api_token, slow=True)
        if "node get_info is unavailable, invalid or timed out" not in slow_doctor or not 4.5 <= slow_elapsed < 10:
            raise RuntimeError(f"slow RigForge doctor was not bounded ({slow_elapsed:.2f}s)\n" + slow_doctor)
        print(json.dumps({
            "dry_run_forms": dry_run_forms,
            "configured_mode": "daemon",
            "jobs": StubHandler.requests,
            "height": HEIGHT,
            "synchronized": True,
            "summary_mode_field": summary["connection"].get("mode"),
            "slow_doctor_seconds": round(slow_elapsed, 2),
        }, sort_keys=True))
    finally:
        if process and process.poll() is None:
            process.send_signal(signal.SIGINT)
            try:
                process.wait(timeout=6)
            except subprocess.TimeoutExpired:
                process.terminate()
                try: process.wait(timeout=3)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=2)
        if slow_server:
            slow_server.shutdown()
            slow_server.server_close()
        runtime_dir.cleanup()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
