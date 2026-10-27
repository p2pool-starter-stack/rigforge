#!/usr/bin/env python3

import json
import os
from pathlib import Path
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
assert not c.get("log-file")
assert os.stat(p).st_mode & 0o777 == 0o600
c["cpu"]["rx"] = list(range(8))
p.write_text(json.dumps(c))
"""


def count(profile):
    if isinstance(profile, list):
        return len(profile)
    if isinstance(profile, dict):
        return profile["threads"]
    raise AssertionError("XMRig profile is not an array or object")


class ThreadProfile(unittest.TestCase):
    def generate(self, cap, tuned=None, candidate=False):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            build = root / "xmrig/build"
            build.mkdir(parents=True)
            (root / "logrotate").mkdir()
            binary = build / "xmrig"
            binary.write_text(FAKE)
            binary.chmod(0o700)
            if tuned is not None:
                (root / "tune-overrides.json").write_text(json.dumps({"cpu": {"rx": tuned}}))
            env = dict(os.environ, PROFILE_ROOT=d, PROFILE_SCRIPT=str(SCRIPT), PROFILE_CAP=str(cap))
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
_tune_config "$PWD/candidate.json" 1 false 12 false 2 false false false
"""
            result = subprocess.run(["bash", "-c", command], env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            p = build / ("candidate.json" if candidate else "config.json")
            self.assertEqual(p.stat().st_mode & 0o777, 0o600)
            return json.loads(p.read_text())

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

    def test_bench_candidate_uses_same_ceiling(self):
        self.assertEqual(count(self.generate(16, candidate=True)["cpu"]["rx"]), 8)


if __name__ == "__main__":
    unittest.main()
