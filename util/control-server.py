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

Python3 stdlib only. GET /status returns the last recorded change record — a terminal outcome,
control-upgrade's non-terminal `started` while the oneshot runs (#320), or POST /apply's own
non-terminal `pending` from the instant it's accepted (#344, see stage_pending()). Every record
served carries a derived `age_seconds` next to its own timestamp, so a poller (or a human reading a
stale record days later) can tell fresh from stale without doing its own clock math (#344). POST
/apply stages a config change; POST /upgrade stages a release upgrade (#308, gated by control_upgrade).
"""
import hmac
import json
import os
import re
import socket
import sys
import urllib.parse
from datetime import datetime, timezone
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


def load_upgrade_enabled(cfg_path):
    """#308: is the remote-upgrade endpoint on? A SECOND opt-in (control_upgrade) layered on control.
    Fail CLOSED — any doubt (missing/unreadable/unset) means /upgrade stays 403."""
    try:
        with open(cfg_path) as f:
            v = json.load(f).get("control_upgrade")
    except Exception:
        return False
    return str(v).strip().lower() in ("enabled", "true", "on")


def stage_change(spool, body_bytes, prefix="pending"):
    """Write the accepted change to spool/<prefix>-<id>.json atomically; return the change id.

    The temp name is dot-prefixed so no path-unit glob matches a half-written file; os.replace is
    atomic within the dir, and both file and dir are fsynced so the change survives a crash the
    instant it is acknowledged. #308: config changes stage as pending-*.json (watched by the apply
    path unit); upgrade requests stage as upgrade-*.json (a DISTINCT glob) so the apply unit never
    fires on an upgrade intent and vice-versa.
    """
    cid = os.urandom(8).hex()
    os.makedirs(spool, exist_ok=True)
    tmp = os.path.join(spool, ".tmp-" + cid)
    final = os.path.join(spool, prefix + "-" + cid + ".json")
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


def _utcnow():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


PENDING_KEEP = 20  # matches _control_status's cap on kept per-change records in rigforge.sh


def stage_pending(state_dir, cid):
    """#344 (item 2): record <cid> as pending in its OWN dir the instant /apply accepts it — not
    when control-apply gets around to running it, which can be tens of seconds away (see #344 item
    1, the fast-path-apply issue this deliberately does not fix). This closes the "in progress vs.
    never existed" gap: GET /status?change_id=<cid> now resolves here instead of falling through to
    the unknown-id 404 for the whole window before control-apply's terminal write lands.

    A SEPARATE directory (not state/changes, where the terminal record ends up) is deliberate: this
    process is unprivileged and DynamicUser-owned, while state/changes is created and written by the
    root control-apply oneshot — writing into a dir root created first would hit a permission wall on
    any rig that already has control-path history. state/pending is exclusively this process's own,
    so there's no ownership race; do_GET checks state/changes first and falls back here, and
    control_apply's _control_status deletes the matching state/pending/<cid>.json once it writes the
    real outcome (best-effort — see there).

    If control-apply crashes, or a newer change supersedes this one before control-apply ever reads
    it (only the newest staged spool file survives — see control_apply() in rigforge.sh), no terminal
    record is ever written and this pending one is what's left FOREVER. That is deliberate, not a bug
    to fix later: a dead/lost run must read as honestly "pending", with a growing age_seconds a
    poller can judge for itself, never guessed into a fabricated applied/failed/rolled_back outcome
    it never actually reached.
    """
    pdir = os.path.join(state_dir, "pending")
    os.makedirs(pdir, exist_ok=True)
    body = json.dumps({"status": "pending", "change_id": cid, "accepted_at": _utcnow()}).encode()
    tmp = os.path.join(pdir, ".tmp-" + cid)
    with open(tmp, "wb") as f:
        f.write(body)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, os.path.join(pdir, cid + ".json"))
    # Prune to the newest PENDING_KEEP: normally control-apply clears these as it lands terminal
    # outcomes, but a run of crashes/supersessions (see above) would otherwise grow this dir forever.
    try:
        stale = sorted(
            (e for e in os.scandir(pdir) if e.name.endswith(".json") and not e.name.startswith(".")),
            key=lambda e: e.stat().st_mtime, reverse=True,
        )[PENDING_KEEP:]
        for e in stale:
            os.unlink(e.path)
    except OSError:
        pass


def _with_age(body_bytes):
    """Inject a derived `age_seconds` next to a served record's own timestamp (`applied_at` for a
    terminal/started outcome, `accepted_at` for a pending one — #344 items 2 & 3) so a poller, or a
    human reading a days-old record, can tell fresh from stale without its own clock math. Computed
    at SERVE time, never stored: the file on disk keeps just the one timestamp it was written with.
    Additive only, and best-effort — a body without a recognized timestamp (or a parse hiccup) is
    served unchanged rather than risking turning a good response into a 500.
    """
    try:
        obj = json.loads(body_bytes)
        ts = obj.get("applied_at") or obj.get("accepted_at")
        if isinstance(ts, str):
            when = datetime.strptime(ts, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            obj["age_seconds"] = max(0, int((datetime.now(timezone.utc) - when).total_seconds()))
            return json.dumps(obj).encode()
    except Exception:
        pass
    return body_bytes


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
        parts = self.path.split("?", 1)
        if parts[0] != "/status":
            return self._send(404, "Not Found", {"error": "not found"})
        # #255: ?change_id=<16hex> returns THAT change's recorded outcome (or 404), so a caller whose
        # confirmation got stepped on by a concurrent change can still read its own result. The no-arg
        # form stays most-recent for compatibility. Validate the id as 16 hex before it becomes a path
        # component — never allow traversal.
        cid = urllib.parse.parse_qs(parts[1]).get("change_id", [""])[0] if len(parts) == 2 else ""
        if cid:
            if not re.fullmatch(r"[0-9a-f]{16}", cid):
                return self._send(400, "Bad Request", {"error": "change_id must be 16 lowercase hex chars"})
            # #344 (item 2): a terminal outcome (written by the root control-apply oneshot) always
            # wins if one exists; state/pending/<cid>.json (written by THIS process at accept time,
            # see stage_pending()) is the fallback for a change still in flight — or one that never
            # got a terminal record at all (crashed / superseded run, deliberately left pending).
            try:
                with open(os.path.join(STATE_DIR, "changes", cid + ".json"), "rb") as f:
                    body = f.read()
            except OSError:
                try:
                    with open(os.path.join(STATE_DIR, "pending", cid + ".json"), "rb") as f:
                        body = f.read()
                except OSError:
                    return self._send(404, "Not Found", {"error": "no recorded outcome for that change_id"})
        else:
            try:
                with open(os.path.join(STATE_DIR, "status.json"), "rb") as f:
                    body = f.read()
            except OSError:
                return self._send(503, "Service Unavailable", {"status": "no change applied yet"})
        body = _with_age(body)  # #344 (item 3): a recorded-at stamp alone can read as fresh for days
        self.send_response_only(200, "OK")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def _read_json_body(self):
        """Shared body reader for /apply and /upgrade: enforce content-type, length cap, and JSON.
        Returns the parsed object, or None after having already sent the error response."""
        ctype = (self.headers.get("Content-Type") or "").split(";", 1)[0].strip()
        if ctype != "application/json":
            self._send(415, "Unsupported Media Type", {"error": "send application/json"})
            return None
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            self._send(411, "Length Required", {"error": "Content-Length required"})
            return None
        if length <= 0 or length > MAX_BODY:
            self._send(413, "Payload Too Large", {"error": "body must be 1..%d bytes" % MAX_BODY})
            return None
        try:
            obj = json.loads(self.rfile.read(length))
        except ValueError:
            self._send(400, "Bad Request", {"error": "body is not valid JSON"})
            return None
        return obj

    def do_POST(self):
        if not self._authed():
            return
        path = self.path.split("?", 1)[0]
        if path == "/apply":
            return self._handle_apply()
        if path == "/upgrade":
            return self._handle_upgrade()
        return self._send(404, "Not Found", {"error": "not found"})

    def _handle_upgrade(self):
        # #308 (ADR 0002): the remote code-update surface. Gated by control_upgrade — a SECOND opt-in on
        # top of `control`, so enabling remote tuning does not silently grant remote RCE. The version in
        # the body IS the target (D4): the dashboard re-derives latest host-side, the rig makes no version
        # check of its own — the applier bounds the supplied target, refusing anything that is not a real,
        # reachable release newer than the one installed (D4/D10). We only stage the intent here; the
        # unprivileged receiver never fetches or runs anything.
        if not UPGRADE_ENABLED:
            return self._send(403, "Forbidden", {"error": "remote upgrade is disabled on this rig; set control_upgrade: \"enabled\" locally to allow it"})
        body = self._read_json_body()
        if body is None:
            return
        if (not isinstance(body, dict) or set(body) != {"version"} or not isinstance(body["version"], str)
                or not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", body["version"])):
            return self._send(400, "Bad Request", {"error": 'body must be exactly {"version": "vX.Y.Z"}'})
        staged = json.dumps({"version": body["version"]}).encode()
        try:
            cid = stage_change(os.path.join(STATE_DIR, "spool"), staged, prefix="upgrade")
        except OSError as e:
            return self._send(500, "Internal Server Error", {"error": "could not stage upgrade: %s" % e})
        self._send(202, "Accepted", {"status": "accepted", "change_id": cid,
                                     "note": "queued; the rig refuses anything that isn't a real, reachable release newer than the one installed (posting the installed version ends 'noop'; it does not independently verify the target is the newest). poll GET /status"})

    def _handle_apply(self):
        change = self._read_json_body()
        if change is None:
            return
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
        # #344 (item 2): record it pending now, not when control-apply eventually gets to it (see
        # stage_pending()) — best-effort: the spool file above is the thing control-apply actually
        # reads, so a pending-marker write failure shouldn't fail an otherwise-accepted change, just
        # cost the poller a 404 instead of "pending" until the terminal outcome lands.
        try:
            stage_pending(STATE_DIR, cid)
        except OSError:
            pass
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
    UPGRADE_ENABLED = load_upgrade_enabled(cfg)  # #308: /upgrade stays 403 unless control_upgrade is on
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
