#!/usr/bin/env python3
"""Concurrency regression for the shared apply/upgrade spool cap (#478)."""
import io
import runpy
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path


mod = runpy.run_path(sys.argv[1])
stage = mod["stage_change"]
full = mod["SpoolFull"]
uncertain = mod["DurabilityUncertain"]
pending = mod["stage_pending"]
limit = mod["MAX_PENDING"]

with tempfile.TemporaryDirectory() as spool:

    def submit(i):
        try:
            stage(spool, b"{}", "pending" if i % 2 else "upgrade")
            return True
        except full:
            return False

    with ThreadPoolExecutor(max_workers=16) as pool:
        accepted = list(pool.map(submit, range(limit * 2)))
    queued = list(Path(spool).glob("*-*.json"))
    assert sum(accepted) == len(queued) == limit
    assert any(p.name.startswith("pending-") for p in queued)
    assert any(p.name.startswith("upgrade-") for p in queued)
    queued[0].unlink()
    stage(spool, b"{}")
    assert len(list(Path(spool).glob("*-*.json"))) == limit

with tempfile.TemporaryDirectory() as spool:
    real_replace = stage.__globals__["os"].replace
    try:
        stage.__globals__["os"].replace = lambda *_: (_ for _ in ()).throw(OSError("failed rename"))
        try:
            stage(spool, b"{}")
        except OSError:
            pass
    finally:
        stage.__globals__["os"].replace = real_replace
    assert not list(Path(spool).glob(".tmp-*"))

with tempfile.TemporaryDirectory() as spool:
    real_open = open

    class WriteFail:
        def __init__(self, path):
            self.file = real_open(path, "wb")

        def __enter__(self):
            return self

        def write(self, _body):
            raise OSError("failed write")

        def __exit__(self, *_):
            self.file.close()

    try:
        stage.__globals__["open"] = lambda path, mode="r", **kwargs: WriteFail(path) if mode == "wb" else real_open(path, mode, **kwargs)
        stage(spool, b"{}")
        raise AssertionError("write failure was hidden")
    except OSError as e:
        assert str(e) == "failed write"
    finally:
        del stage.__globals__["open"]
    assert not list(Path(spool).glob(".tmp-*")) and not list(Path(spool).glob("*-*.json"))

with tempfile.TemporaryDirectory() as spool:
    real_fsync = stage.__globals__["os"].fsync
    try:
        stage.__globals__["os"].fsync = lambda _fd: (_ for _ in ()).throw(OSError("failed file sync"))
        stage(spool, b"{}")
        raise AssertionError("file sync failure was hidden")
    except OSError as e:
        assert str(e) == "failed file sync"
    finally:
        stage.__globals__["os"].fsync = real_fsync
    assert not list(Path(spool).glob(".tmp-*")) and not list(Path(spool).glob("*-*.json"))

with tempfile.TemporaryDirectory() as spool:
    real_replace = stage.__globals__["os"].replace
    real_unlink = stage.__globals__["os"].unlink
    real_stderr = stage.__globals__["sys"].stderr
    try:
        stage.__globals__["sys"].stderr = io.StringIO()
        stage.__globals__["os"].replace = lambda *_: (_ for _ in ()).throw(OSError("original rename failure"))
        stage.__globals__["os"].unlink = lambda *_: (_ for _ in ()).throw(OSError("cleanup failure"))
        stage(spool, b"{}")
    except OSError as e:
        assert str(e) == "original rename failure"
    finally:
        stage.__globals__["os"].replace = real_replace
        stage.__globals__["os"].unlink = real_unlink
        warning = stage.__globals__["sys"].stderr.getvalue()
        stage.__globals__["sys"].stderr = real_stderr
    assert "temporary cleanup failed" in warning
    assert len(list(Path(spool).glob(".tmp-*"))) == 1
    for _ in range(limit - 1):
        stage(spool, b"{}")
    try:
        stage(spool, b"{}")
        raise AssertionError("orphan temp did not count toward the queue cap")
    except full:
        pass

with tempfile.TemporaryDirectory() as state:
    real_open = open
    real_fsync = stage.__globals__["os"].fsync
    for failure in ("write", "fsync"):
        class Broken:
            def __init__(self, path): self.file = real_open(path, "wb")
            def __enter__(self): return self
            def write(self, body):
                if failure == "write": raise OSError("pending write failure")
                return self.file.write(body)
            def flush(self): self.file.flush()
            def fileno(self): return self.file.fileno()
            def __exit__(self, *_): self.file.close()
        try:
            pending.__globals__["open"] = lambda path, mode="r", **kwargs: Broken(path) if mode == "wb" else real_open(path, mode, **kwargs)
            if failure == "fsync": pending.__globals__["os"].fsync = lambda _fd: (_ for _ in ()).throw(OSError("pending fsync failure"))
            pending(state, "0123456789abcdef")
            raise AssertionError("pending %s failure was hidden" % failure)
        except OSError:
            pass
        finally:
            pending.__globals__.pop("open", None)
            pending.__globals__["os"].fsync = real_fsync
        assert not list(Path(state, "pending").glob(".tmp-*"))

with tempfile.TemporaryDirectory() as state:
    real_replace = pending.__globals__["os"].replace
    real_unlink = pending.__globals__["os"].unlink
    real_stderr = pending.__globals__["sys"].stderr
    try:
        pending.__globals__["sys"].stderr = io.StringIO()
        pending.__globals__["os"].replace = lambda *_: (_ for _ in ()).throw(OSError("pending rename failure"))
        pending.__globals__["os"].unlink = lambda *_: (_ for _ in ()).throw(OSError("pending cleanup failure"))
        for i in range(limit + 1):
            try: pending(state, "%016x" % i)
            except OSError: pass
    finally:
        pending.__globals__["os"].replace = real_replace
        pending.__globals__["os"].unlink = real_unlink
        warning = pending.__globals__["sys"].stderr.getvalue()
        pending.__globals__["sys"].stderr = real_stderr
    assert "pending-marker temporary cleanup failed" in warning
    assert len(list(Path(state, "pending").glob(".tmp-*"))) == limit

with tempfile.TemporaryDirectory() as spool:
    real_fsync = stage.__globals__["os"].fsync
    calls = 0

    def fail_dir_sync(fd):
        global calls
        calls += 1
        if calls == 2:
            raise OSError("failed directory sync")
        real_fsync(fd)

    try:
        stage.__globals__["os"].fsync = fail_dir_sync
        stage(spool, b"{}")
        raise AssertionError("post-rename sync failure was hidden")
    except uncertain as e:
        assert Path(spool, "pending-" + e.cid + ".json").read_bytes() == b"{}"
    finally:
        stage.__globals__["os"].fsync = real_fsync


class FakeHandler:
    def __init__(self, body):
        self.body = body
        self.sent = None

    def _read_json_body(self):
        return self.body

    def _send(self, code, reason, obj):
        self.sent = code, reason, obj


real_stage = stage.__globals__["stage_change"]
try:
    stage.__globals__["stage_change"] = lambda *_args, **_kwargs: (_ for _ in ()).throw(uncertain("0123456789abcdef", OSError("sync")))
    stage.__globals__["STATE_DIR"] = tempfile.mkdtemp()
    apply = FakeHandler({"DONATION": 2})
    mod["Handler"]._handle_apply(apply)
    assert apply.sent[0] == 202 and apply.sent[2]["change_id"] == "0123456789abcdef"
    assert apply.sent[2]["warning"].startswith("staged but directory sync failed")
    assert "do not retry now" in apply.sent[2]["note"] and "GET /status?change_id=0123456789abcdef" in apply.sent[2]["note"]
    assert "inspect the rig before resubmitting" in apply.sent[2]["note"]
    stage.__globals__["UPGRADE_ENABLED"] = True
    upgrade = FakeHandler({"version": "v1.2.3"})
    mod["Handler"]._handle_upgrade(upgrade)
    assert upgrade.sent[0] == 202 and upgrade.sent[2]["change_id"] == "0123456789abcdef"
    assert upgrade.sent[2]["warning"].startswith("staged but directory sync failed")
    assert "do not retry now" in upgrade.sent[2]["note"] and "GET /status?change_id=0123456789abcdef" in upgrade.sent[2]["note"]
    assert "inspect the rig before resubmitting" in upgrade.sent[2]["note"]
finally:
    stage.__globals__["stage_change"] = real_stage
