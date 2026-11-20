#!/usr/bin/env python3

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get("RIGFORGE_TEST_SCRIPT", ROOT / "rigforge.sh"))
FAKE = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
p = Path(args[args.index("--config") + 1])
c = json.loads(p.read_text())
assert c["http"]["enabled"] is False
assert c["randomx"]["wrmsr"] is False
assert c["randomx"]["rdmsr"] is False
assert c["cpu"]["huge-pages"] is False
assert c["pools"][0]["url"].startswith("127.0.0.1:")
assert c["pools"][0]["user"] == "rigforge-profile"
assert set(c["pools"][0]) == {"url", "user"}
assert c["randomx"]["1gb-pages"] is False
assert not c.get("log-file")
assert os.stat(p).st_mode & 0o777 == 0o600
c["cpu"]["rx"] = list(range(8))
p.write_text(json.dumps(c))
"""


AFFINITY_FAKE = """#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(sys.argv[sys.argv.index("--config") + 1])
c = json.loads(p.read_text())
c["cpu"]["rx"] = list(range(len(os.sched_getaffinity(0))))
p.write_text(json.dumps(c))
"""


def count(profile):
    if isinstance(profile, list):
        return len(profile)
    if isinstance(profile, dict):
        return profile["threads"]
    raise AssertionError("XMRig profile is not an array or object")


class ThreadProfile(unittest.TestCase):
    def generate(self, cap, tuned=None, candidate=False, cthreads=12, shared=False, script=FAKE, service_cpus=None, prop="EffectiveCPUs"):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            build = root / "xmrig/build"
            build.mkdir(parents=True)
            (root / "logrotate").mkdir()
            binary = build / "xmrig"
            binary.write_text(script)
            binary.chmod(0o700)
            if tuned is not None:
                (root / "tune-overrides.json").write_text(json.dumps({"cpu": {"rx": tuned}}))
            if service_cpus is not None:
                stubs = root / "stubs"
                stubs.mkdir()
                stub = stubs / "systemctl"
                stub.write_text('#!/bin/sh\ncase "$*" in *%s*) echo "%s" ;; esac\n' % (prop, service_cpus))
                stub.chmod(0o700)
            env = dict(os.environ, SHARED_HOST="true" if shared else "false", PROFILE_ROOT=d, PROFILE_SCRIPT=str(SCRIPT), PROFILE_CAP=str(cap), PROFILE_CT=str(cthreads))
            if service_cpus is not None:
                env["PATH"] = str(root / "stubs") + os.pathsep + env["PATH"]
            command = """
source "$PROFILE_SCRIPT"
lscpu() { printf 'Model name: Test CPU\\n'; }
hostname() { printf 'test-worker\\n'; }
sudo() { "$@"; }
OS_TYPE=Linux
WORKER_ROOT="$PROFILE_ROOT"
LOGROTATE_DIR="$PROFILE_ROOT/logrotate"
POOLS_JSON='[{"url":"test.invalid:3333","user":"","pass":"x"}]'
ACCESS_TOKEN=""
DONATION=1
THREADS_CAP="$PROFILE_CAP"
cd "$WORKER_ROOT/xmrig/build"
generate_xmrig_config
"""
            if candidate:
                command += """
TUNE_BASE="$PWD/config.json"
TUNE_BIN="$PWD/xmrig"
_tune_config "$PWD/candidate.json" 1 false $PROFILE_CT false 2 false false false
"""
            result = subprocess.run(["bash", "-c", command], env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.output = result.stdout + result.stderr
            p = build / ("candidate.json" if candidate else "config.json")
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            return json.loads(p.read_text())

    @unittest.skipUnless(shutil.which("taskset") and hasattr(os, "sched_getaffinity"), "needs Linux taskset")
    def test_cap_above_service_cpu_set(self):
        allowed = sorted(os.sched_getaffinity(0))
        if len(allowed) < 2:
            self.skipTest("needs at least two CPUs")
        n = len(allowed) // 2
        cpus = ",".join(map(str, allowed[:n]))
        c = self.generate(n + 2, script=AFFINITY_FAKE, service_cpus=cpus)
        self.assertEqual(count(c["cpu"]["rx"]), n)

    @unittest.skipUnless(shutil.which("taskset") and hasattr(os, "sched_getaffinity"), "needs Linux taskset")
    def test_allowed_cpus_fallback_pins_probe(self):
        allowed = sorted(os.sched_getaffinity(0))
        if len(allowed) < 2:
            self.skipTest("needs at least two CPUs")
        c = self.generate(len(allowed) + 2, script=AFFINITY_FAKE, service_cpus=str(allowed[0]), prop="AllowedCPUs")
        self.assertEqual(count(c["cpu"]["rx"]), 1)

    @unittest.skipUnless(shutil.which("taskset") and hasattr(os, "sched_getaffinity"), "needs Linux taskset")
    def test_space_separated_service_cpu_set_pins_probe(self):
        allowed = sorted(os.sched_getaffinity(0))
        if len(allowed) < 4:
            self.skipTest("needs at least four CPUs")
        n = len(allowed) // 2
        cpus = " ".join(map(str, allowed[:n]))
        c = self.generate(n + 2, script=AFFINITY_FAKE, service_cpus=cpus, prop="CPUAffinity")
        self.assertEqual(count(c["cpu"]["rx"]), n)

    def test_cap_below_auto(self):
        self.assertEqual(count(self.generate(1)["cpu"]["rx"]), 1)

    def test_cap_above_auto(self):
        self.assertEqual(count(self.generate(16)["cpu"]["rx"]), 8)

    def test_tuned_cannot_raise_auto(self):
        self.assertEqual(count(self.generate(16, 12)["cpu"]["rx"]), 8)

    def test_tuned_below_auto(self):
        self.assertEqual(count(self.generate(16, 4)["cpu"]["rx"]), 4)

    def test_cap_clamps_tuned(self):
        self.assertEqual(count(self.generate(2, 4)["cpu"]["rx"]), 2)

    def test_uncapped_tuned_cannot_raise_auto(self):
        self.assertEqual(count(self.generate("", 12)["cpu"]["rx"]), 8)

    def test_array_override_cannot_raise_auto(self):
        self.assertEqual(count(self.generate(16, list(range(12)))["cpu"]["rx"]), 8)

    def test_object_override_cannot_raise_auto(self):
        self.assertEqual(count(self.generate(16, {"threads": 12, "intensity": 1, "affinity": -1})["cpu"]["rx"]), 8)

    def test_leading_zero_cap_is_decimal(self):
        self.assertEqual(count(self.generate("02")["cpu"]["rx"]), 2)

    def test_uncapped_bench_candidate_uses_auto_ceiling(self):
        self.assertEqual(count(self.generate("", candidate=True)["cpu"]["rx"]), 8)

    def test_auto_candidate_ignores_inherited_tuned_count(self):
        self.assertEqual(self.generate("", 4, candidate=True, cthreads=-1)["cpu"]["rx"], {})

    def test_auto_candidate_still_honours_cap(self):
        self.assertEqual(count(self.generate(3, 4, candidate=True, cthreads=-1)["cpu"]["rx"]), 3)

    def test_shared_host_keeps_object_override_below_cap(self):
        self.assertEqual(count(self.generate(6, {"threads": 2, "intensity": 1, "affinity": -1}, shared=True)["cpu"]["rx"]), 2)

    def test_probe_failure_warns_and_still_applies_cap(self):
        c = self.generate(3, script="#!/bin/sh\nexit 1\n")
        self.assertEqual(count(c["cpu"]["rx"]), 3)
        self.assertIn("Could not observe XMRig's auto thread profile", self.output)

    def test_bench_candidate_uses_same_ceiling(self):
        self.assertEqual(count(self.generate(16, candidate=True)["cpu"]["rx"]), 8)

    def test_failed_hardware_snapshot_preserves_original(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            original = b'{"cpu":{"rx":12}}\n'
            overrides = root / "tune-overrides.json"
            overrides.write_bytes(original)
            stub = root / "rigforge.sh"
            stub.write_text('parse_config() { WORKER_ROOT="$PROFILE_ROOT"; }\n')
            env = dict(os.environ, PROFILE_ROOT=d, PROFILE_STUB=str(stub), PROFILE_HELPER=str(ROOT / "tests/e2e-thread-profile.sh"))
            command = """
set -e
source "$PROFILE_HELPER"
RIGFORGE="$PROFILE_STUB"
CFG="$PROFILE_ROOT/config.json"
phase() { :; }
die() { exit 2; }
cp() { return 1; }
trap 'thread_profile_restore' EXIT
phase_thread_profile
"""
            result = subprocess.run(["bash", "-c", command], env=env, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertTrue(overrides.exists())
            self.assertEqual(overrides.read_bytes(), original)

    def test_failed_tuning_restore_does_not_apply_test_override(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            saved = root / "saved.json"
            saved.write_text('{"threads":16}\n')
            config = root / "config.json"
            config.write_text('{"threads":1}\n')
            stub = root / "rigforge"
            marker = root / "apply"
            stub.write_text('#!/usr/bin/env bash\ntouch "$PROFILE_MARKER"\n')
            stub.chmod(0o700)
            harness = (ROOT / "tests/e2e-pithead.sh").read_text()
            cleanup = harness[harness.index("_cleanup() {"):harness.index("\nsnapshot_config()")]
            env = dict(os.environ, PROFILE_ROOT=d, PROFILE_MARKER=str(marker))
            command = cleanup + """
SAVED_CFG="$PROFILE_ROOT/saved.json"
CFG="$PROFILE_ROOT/config.json"
RIGFORGE="$PROFILE_ROOT/rigforge"
HAMMER_PIDS=""
THREAD_PROFILE_SAVED="$PROFILE_ROOT/tuning-snapshot"
refresh_profile_finish() { :; }
thread_profile_restore() { return 1; }
_restore_xmrig() { :; }
_cleanup
"""
            result = subprocess.run(["bash", "-c", command], env=env, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(marker.exists())
            self.assertTrue(saved.exists())
            self.assertEqual(config.read_bytes(), saved.read_bytes())

    def test_restriction_dropin_is_removed_on_restore(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            unit_dir = root / "system" / "xmrig.service.d"
            unit_dir.mkdir(parents=True)
            dropin = unit_dir / "e2e-thread-profile.conf"
            dropin.write_text("[Service]\nAllowedCPUs=0-1\n")
            (root / "rigforge-stub").write_text("#!/bin/sh\nexit 0\n")
            (root / "rigforge-stub").chmod(0o700)
            env = dict(os.environ, PROFILE_ROOT=d, PROFILE_HELPER=str(ROOT / "tests/e2e-thread-profile.sh"))
            command = """
source "$PROFILE_HELPER"
systemctl() { return 0; }
RIGFORGE="$PROFILE_ROOT/rigforge-stub"
THREAD_PROFILE_DROPIN="$PROFILE_ROOT/system/xmrig.service.d/e2e-thread-profile.conf"
thread_profile_restore
"""
            result = subprocess.run(["bash", "-c", command], env=env, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse(dropin.exists())
            self.assertFalse(unit_dir.exists())

    def test_restriction_restore_fails_when_daemon_reload_fails(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            unit_dir = root / "system" / "xmrig.service.d"
            unit_dir.mkdir(parents=True)
            dropin = unit_dir / "e2e-thread-profile.conf"
            dropin.write_text("[Service]\nAllowedCPUs=0-1\n")
            (root / "rigforge-stub").write_text("#!/bin/sh\nexit 0\n")
            (root / "rigforge-stub").chmod(0o700)
            env = dict(os.environ, PROFILE_ROOT=d, PROFILE_HELPER=str(ROOT / "tests/e2e-thread-profile.sh"))
            command = """
source "$PROFILE_HELPER"
systemctl() { return 1; }
RIGFORGE="$PROFILE_ROOT/rigforge-stub"
THREAD_PROFILE_DROPIN="$PROFILE_ROOT/system/xmrig.service.d/e2e-thread-profile.conf"
thread_profile_restore
"""
            result = subprocess.run(["bash", "-c", command], env=env, capture_output=True, timeout=5)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(dropin.exists())

    def test_snapshot_cleanup_failure_does_not_fail_restoration(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            snapshot = root / "snapshot"
            snapshot.mkdir()
            original = b'{"cpu":{"rx":12}}\n'
            (snapshot / "overrides.json").write_bytes(original)
            overrides = root / "tune-overrides.json"
            overrides.write_text('{"cpu":{"rx":1}}\n')
            env = dict(os.environ, PROFILE_ROOT=d, PROFILE_HELPER=str(ROOT / "tests/e2e-thread-profile.sh"))
            command = """
source "$PROFILE_HELPER"
THREAD_PROFILE_SAVED="$PROFILE_ROOT/snapshot"
THREAD_PROFILE_OVERRIDES="$PROFILE_ROOT/tune-overrides.json"
THREAD_PROFILE_EXISTED=1
rm() { return 1; }
thread_profile_restore
"""
            result = subprocess.run(["bash", "-c", command], env=env, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(overrides.read_bytes(), original)
            self.assertTrue(snapshot.exists())


if __name__ == "__main__":
    unittest.main()
