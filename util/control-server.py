#!/usr/bin/env python3
"""RigForge control server (#236): the writable counterpart to the read-only sister API.

This is the UNPRIVILEGED receiver half of the control path. It authenticates a config change,
validates it structurally, and STAGES it to a spool file — it never touches config.json, never
restarts the miner, and holds no privilege. A separate root oneshot (`rigforge.sh control-apply`,
triggered by a systemd.path watching the spool) does the privileged persist + apply. So a request
here can never touch mining performance, and a compromise of this process can at most drop a
staged change that the applier re-validates before it ever lands (see docs/adr/0001).

Posture, deliberately paranoid because this one accepts writes:
  - Bearer auth is MANDATORY. parse_config refuses to enable `control` without ACCESS_TOKEN and
    api_allow_from, but if the token is somehow empty here we fail CLOSED (refuse everything).
  - Only an allowlist of operationally-mutable keys is accepted; anything else is a 400. The
    authoritative semantic validation is the applier's parse_config — this is the structural gate.
  - Body size is capped; the staged file is written atomically (temp + rename + fsync) so the
    path unit never sees a half-written request.

Python3 stdlib only. GET /status returns the last applied change's result; POST /apply stages one.
"""
import hmac
import json
import os
import socket
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

# The keys the control path may change. Operationally-mutable only — identity, trust, filesystem
# paths, and the control path's own auth are NOT here (remote mutation of those is escalation).
# Kept in lockstep with control_apply()'s CONTROL_WRITABLE_KEYS in rigforge.sh (a drift test guards it).
WRITABLE = {"pools", "DONATION", "autotune", "watchdog", "watchdog_interval_min", "max_temp_c"}

# #257: the control path is a TUNING channel, not a safety-removal one. The REMOTE path may not strip
# a rig's thermal protection — disable the watchdog, or unset / out-of-band max_temp_c. A local
# `rigforge.sh apply` on the box keeps full control (the operator is physically present). Mirrored in
# rigforge.sh's _control_commit (a behavioural drift test pins the two together), so a spool-staged
# change is caught applier-side too.
WATCHDOG_OFF = {"disabled", "false", "off", "none", ""}
TEMP_MIN, TEMP_MAX = 40, 110


def unsafe_reasons(change):
    """Safety-critical values the remote control path must refuse (#257). Empty list = OK to stage."""
    out = []
    if "watchdog" in change and str(change["watchdog"]).strip().lower() in WATCHDOG_OFF:
        out.append("the watchdog cannot be disabled")
    if "max_temp_c" in change:
        mt = change["max_temp_c"]
        if mt is None or (isinstance(mt, str) and not mt.strip()):
            out.append("max_temp_c cannot be unset (that removes the thermal cutoff)")
        else:
            # max_temp_c is a WHOLE number of degC (matches parse_config's `^[0-9]+$` gate). Accept an
            # int or an all-digit string in band; reject floats / non-numeric here so the receiver's
            # verdict is identical to the applier + parse_config — no "staged at the receiver, then
            # rejected downstream" divergence (bool is an int subclass, so exclude it explicitly).
            v = None
            if isinstance(mt, bool):
                v = None
            elif isinstance(mt, int):
                v = mt
            elif isinstance(mt, str) and mt.strip().isdigit():
                v = int(mt.strip())
            if v is None or v < TEMP_MIN or v > TEMP_MAX:
                out.append("max_temp_c must be a whole number %d-%d degC" % (TEMP_MIN, TEMP_MAX))
    return out

MAX_BODY = 65536  # a config change is small; cap the body so a large POST can't exhaust memory


def load_token(cfg_path):
    if not os.path.exists(cfg_path):
        return ""
    try:
        with open(cfg_path) as f:
            return (json.load(f).get("ACCESS_TOKEN") or "").strip()
    except Exception:
        sys.exit("control-server: %s is unreadable — refusing to start without a known token posture" % cfg_path)


def stage_change(spool, body_bytes):
    """Write the accepted change to spool/pending-<id>.json atomically; return the change id.

    The temp name is dot-prefixed so the path unit's pending-*.json glob never matches a
    half-written file; os.replace is atomic within the dir, and both file and dir are fsynced so
    the change survives a crash the instant it is acknowledged.
    """
    cid = os.urandom(8).hex()
    os.makedirs(spool, exist_ok=True)
    tmp = os.path.join(spool, ".tmp-" + cid)
    final = os.path.join(spool, "pending-" + cid + ".json")
    with open(tmp, "wb") as f:
        f.write(body_bytes)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, final)
    dfd = os.open(spool, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
    return cid


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_):  # quiet by design — a config write must not spill headers to the journal
        pass

    def _send(self, code, reason, obj):
        body = json.dumps(obj).encode()
        self.send_response_only(code, reason)  # no Server/Date banner, same wire discipline as the read API
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _authed(self):
        # Fail closed: no token configured means the writable path refuses everyone, never opens.
        if not TOKEN:
            self._send(403, "Forbidden", {"error": "control requires ACCESS_TOKEN"})
            return False
        auth = (self.headers.get("Authorization") or "").strip()
        if not hmac.compare_digest(auth.encode(), ("Bearer " + TOKEN).encode()):
            self._send(401, "Unauthorized", {"error": "unauthorized"})
            return False
        return True

    def do_GET(self):
        if not self._authed():
            return
        if self.path.split("?", 1)[0] != "/status":
            return self._send(404, "Not Found", {"error": "not found"})
        try:
            with open(os.path.join(STATE_DIR, "status.json"), "rb") as f:
                body = f.read()
        except OSError:
            return self._send(503, "Service Unavailable", {"status": "no change applied yet"})
        self.send_response_only(200, "OK")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def do_POST(self):
        if not self._authed():
            return
        if self.path.split("?", 1)[0] != "/apply":
            return self._send(404, "Not Found", {"error": "not found"})
        ctype = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip()
        if ctype != "application/json":
            return self._send(415, "Unsupported Media Type", {"error": "send application/json"})
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return self._send(411, "Length Required", {"error": "Content-Length required"})
        if length <= 0 or length > MAX_BODY:
            return self._send(413, "Payload Too Large", {"error": "body must be 1..%d bytes" % MAX_BODY})
        raw = self.rfile.read(length)
        try:
            change = json.loads(raw)
        except ValueError:
            return self._send(400, "Bad Request", {"error": "body is not valid JSON"})
        if not isinstance(change, dict) or not change:
            return self._send(400, "Bad Request", {"error": "body must be a non-empty JSON object of config keys"})
        bad = sorted(k for k in change if k not in WRITABLE)
        if bad:
            return self._send(400, "Bad Request", {"error": "keys not writable via the control path: %s" % ", ".join(bad),
                                                    "writable": sorted(WRITABLE)})
        # #257: refuse a change that would strip thermal protection via the remote path, before it is
        # ever staged. Local `rigforge.sh apply` is unaffected — it never reaches this receiver.
        unsafe = unsafe_reasons(change)
        if unsafe:
            return self._send(400, "Bad Request", {"error": "safety-critical change refused via the remote control path: %s; change it locally on the rig with rigforge.sh if intended" % "; ".join(unsafe)})
        # Re-serialize exactly the accepted keys (defence-in-depth: never stage a raw body) and hand off.
        staged = json.dumps({k: change[k] for k in change}).encode()
        try:
            cid = stage_change(os.path.join(STATE_DIR, "spool"), staged)
        except OSError as e:
            return self._send(500, "Internal Server Error", {"error": "could not stage change: %s" % e})
        self._send(202, "Accepted", {"status": "accepted", "change_id": cid,
                                     "note": "queued for apply; poll GET /status and GET :%s/2/summary for the effective config" % os.environ.get("RIGFORGE_API_PORT", "8081")})

    def _read_only(self):
        self._send(405, "Method Not Allowed", {"error": "method not allowed"})

    do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _read_only


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit("usage: control-server.py <bind> <port> <state-dir> <config.json>")
    bind, port, STATE_DIR, cfg = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    TOKEN = load_token(cfg)
    os.makedirs(os.path.join(STATE_DIR, "spool"), exist_ok=True)
    # Single-threaded like the read server: staging is microseconds, concurrency would only add ways
    # to race the spool. Cap request-arrival time so one held-open connection can't wedge it.
    Handler.timeout = 10
    if ":" in bind:  # IPv6 bind (bind = :: or a v6 addr, #243); dual-stack so IPv4 clients still reach it
        class _V6(HTTPServer):
            address_family = socket.AF_INET6

            def server_bind(self):
                try:
                    self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
                except OSError:
                    pass
                HTTPServer.server_bind(self)

        _V6((bind, port), Handler).serve_forever()
    else:
        HTTPServer((bind, port), Handler).serve_forever()
