#!/usr/bin/env python3
import copy
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
PROGRAM = Path(os.environ.get("WORKER_PROOF_IMPLEMENTATION", HERE / "worker-proof.py"))
ALL_PHASES = [
    "connect",
    "worker-api",
    "api-impact",
    "network",
    "stratum-auth",
    "dashboard",
    "dev-fee",
    "control",
    "access-tokens",
]
FUNCTION = re.compile(r"([a-z_][a-z0-9_]*)\(\) *[{(](.*)$")
OK_CALL = re.compile(r"(?:^|[;&|(){]|\bthen|\belse|\bdo)\s*ok\s", re.M)
SOURCE = re.compile(r"(?:\bsource|(?:^|[;&|])\s*\.)\s[^\n]*?\b(e2e-[a-z-]+\.sh)\b", re.M)
WORD = re.compile(r"[a-z_][a-z0-9_]*")


def harness_functions(directory=HERE):
    sources = ["e2e-pithead.sh"]
    functions = {}
    for source in sources:
        text = (directory / source).read_text(encoding="utf-8")
        sources.extend(name for name in SOURCE.findall(text) if name not in sources)
        name = None
        for line in text.splitlines():
            match = FUNCTION.match(line)
            if name is None and match:
                name, rest = match.groups()
                if re.sub(r"\s+#.*$", "", rest).endswith(("}", ")")):
                    functions[name], name = rest, None
                else:
                    functions[name] = ""
            elif name is not None and line in ("}", ")"):
                name = None
            elif name is not None and not line.lstrip().startswith("#"):
                functions[name] += line + "\n"
    return functions


def harness_passes(functions, name, seen=()):
    body = functions[name]
    called = {word for word in WORD.findall(body) if word in functions and word not in seen and word != name}
    return len(OK_CALL.findall(body)) + sum(harness_passes(functions, call, seen + (name,)) for call in called)


def harness_counts(directory=HERE):
    functions = harness_functions(directory)
    return {
        group: harness_passes(functions, "phase_" + group.replace("-", "_"))
        for group in ALL_PHASES + ["control-replay-thermal", "control-replay-pools"]
    }


PASS_COUNTS = harness_counts()


def context(group="network-sequence", row="primary", platform="linux-x86_64", skips=None):
    return {
        "schema": 1,
        "head": "a" * 40,
        "ref": "refs/heads/develop",
        "input": "b" * 64,
        "run": "c" * 32,
        "group": group,
        "row": row,
        "platform": platform,
        "allowed_skips": skips or {},
    }


def events(phases, skip=None, failure=None):
    rows = []
    for phase in phases:
        rows.append({"event": "phase", "id": phase})
        if phase == skip:
            reason = "stratum-fixture-absent" if skip == "stratum-auth" else skip + "-fixture-absent"
            rows.append({"event": "skip", "reason": reason})
        elif phase == failure:
            rows.append({"event": "fail"})
        else:
            rows.extend({"event": "pass"} for _ in range(PASS_COUNTS[phase]))
    return rows


class WorkerProofTest(unittest.TestCase):
    def invoke(self, *args, stdin=None):
        return subprocess.run(
            [sys.executable, str(PROGRAM), *map(str, args)],
            input=stdin,
            text=True,
            capture_output=True,
            check=False,
        )

    def files(self, values):
        directory = tempfile.TemporaryDirectory()
        paths = []
        for index, value in enumerate(values):
            path = Path(directory.name) / f"input-{index}.json"
            if isinstance(value, str):
                path.write_text(value, encoding="utf-8")
            else:
                path.write_text(json.dumps(value), encoding="utf-8")
            paths.append(path)
        self.addCleanup(directory.cleanup)
        return paths

    def make_receipt(self, ctx, rows=None, cleanup="pass", exit_code=0):
        phase_ids = ALL_PHASES if ctx["group"] == "all" else (
            ALL_PHASES[:4] if ctx["group"] == "network-sequence" else [ctx["group"]]
        )
        paths = self.files([ctx, "\n".join(json.dumps(row) for row in (rows or events(phase_ids)))])
        result = self.invoke("receipt", paths[0], paths[1], cleanup, exit_code)
        return result, json.loads(result.stdout) if result.stdout else None

    def check(self, plan, receipts):
        paths = self.files([plan, *receipts])
        return self.invoke("check", *paths)

    def assert_invalid(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "worker-proof: invalid input\n")

    def assert_failed_evidence(self, result):
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt["phases"], [])
        self.assertNotEqual(receipt["exit_code"], 0)

    def test_context_prints_canonical_json(self):
        ctx = context()
        result = self.invoke("context", "network-sequence", stdin=json.dumps(ctx))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, json.dumps(ctx, sort_keys=True, separators=(",", ":")) + "\n")

    def test_context_rejects_schema_and_group_mismatch(self):
        ctx = context()
        ctx["schema"] = True
        self.assert_invalid(self.invoke("context", "network-sequence", stdin=json.dumps(ctx)))
        self.assert_invalid(self.invoke("context", "all", stdin=json.dumps(context())))

    def test_context_rejects_extra_missing_and_duplicate_fields(self):
        extra = context()
        extra["extra"] = 1
        self.assert_invalid(self.invoke("context", "network-sequence", stdin=json.dumps(extra)))
        missing = context()
        del missing["row"]
        self.assert_invalid(self.invoke("context", "network-sequence", stdin=json.dumps(missing)))
        duplicate = json.dumps(context()).replace('"schema": 1', '"schema": 1, "schema": 1')
        self.assert_invalid(self.invoke("context", "network-sequence", stdin=duplicate))

    def test_context_rejects_bad_bindings(self):
        mutations = {
            "head": "A" * 40,
            "ref": "refs/heads/a..b",
            "input": "b" * 63,
            "run": "c" * 33,
            "row": "Bad Row",
            "platform": "linux-riscv64",
        }
        for key, value in mutations.items():
            with self.subTest(key=key):
                ctx = context()
                ctx[key] = value
                self.assert_invalid(self.invoke("context", ctx["group"], stdin=json.dumps(ctx)))

    def test_context_accepts_canonical_pull_ref(self):
        ctx = context()
        ctx["ref"] = "refs/pull/42/head"
        result = self.invoke("context", ctx["group"], stdin=json.dumps(ctx))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_allowed_skips_are_narrow(self):
        valid = [
            context("all", skips={"stratum-auth": "stratum-fixture-absent"}),
            context("all", skips={"dashboard": "dashboard-fixture-absent"}),
            context("dashboard", skips={"dashboard": "dashboard-fixture-absent"}),
        ]
        for ctx in valid:
            self.assertEqual(self.invoke("context", ctx["group"], stdin=json.dumps(ctx)).returncode, 0)
        invalid = [
            context("stratum-auth", skips={"stratum-auth": "stratum-fixture-absent"}),
            context("network", skips={"network": "fixture-absent"}),
            context("all", skips={"dashboard": "unknown"}),
        ]
        for ctx in invalid:
            self.assert_invalid(self.invoke("context", ctx["group"], stdin=json.dumps(ctx)))

    def test_receipt_folds_events_and_validates(self):
        result, receipt = self.make_receipt(context())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([row["id"] for row in receipt["phases"]], ALL_PHASES[:4])
        self.assertEqual([row["passed"] for row in receipt["phases"]], [PASS_COUNTS[phase] for phase in ALL_PHASES[:4]])

    def test_receipt_emits_failed_evidence(self):
        ctx = context("connect")
        result, receipt = self.make_receipt(ctx, events(["connect"], failure="connect"), "fail", 7)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertEqual(receipt["phases"][0]["failed"], 1)
        self.assertEqual(receipt["cleanup"], "fail")
        self.assertEqual(receipt["exit_code"], 7)

    def test_receipt_normalizes_unknown_cleanup_to_failure(self):
        result, receipt = self.make_receipt(context("connect"), cleanup="unknown")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertEqual(receipt["cleanup"], "fail")

    def test_receipt_accepts_declared_optional_skip(self):
        ctx = context("dashboard", skips={"dashboard": "dashboard-fixture-absent"})
        result, receipt = self.make_receipt(ctx, events(["dashboard"], skip="dashboard"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(receipt["phases"][0]["skipped"], ["dashboard-fixture-absent"])

        all_context = context("all", skips={"stratum-auth": "stratum-fixture-absent"})
        all_result, all_receipt = self.make_receipt(all_context, events(ALL_PHASES, skip="stratum-auth"))
        self.assertEqual(all_result.returncode, 0, all_result.stderr)
        self.assertEqual(all_receipt["phases"][4]["skipped"], ["stratum-fixture-absent"])

    def test_receipt_rejects_unexplained_or_unknown_skip(self):
        ctx = context("dashboard")
        self.assert_failed_evidence(self.make_receipt(ctx, events(["dashboard"], skip="dashboard"))[0])
        bad = [{"event": "phase", "id": "dashboard"}, {"event": "skip", "reason": "unknown"}]
        self.assert_failed_evidence(self.make_receipt(ctx, bad)[0])

    def test_receipt_rejects_event_before_phase(self):
        for row in ({"event": "pass"}, {"event": "fail"}, {"event": "skip", "reason": "unknown"}):
            with self.subTest(row=row):
                self.assert_failed_evidence(self.make_receipt(context("connect"), [row])[0])

    def test_receipt_rejects_reordered_duplicate_and_substituted_phases(self):
        bad_orders = [
            ["worker-api", "connect", "api-impact", "network"],
            ["connect", "connect", "api-impact", "network"],
            ["connect", "worker-api", "dashboard", "network"],
        ]
        for phases in bad_orders:
            with self.subTest(phases=phases):
                self.assert_failed_evidence(self.make_receipt(context(), events(phases))[0])

    def test_receipt_rejects_malformed_event_json(self):
        paths = self.files([context("connect"), '{"event":"phase","id":"connect"}\n{'])
        self.assert_failed_evidence(self.invoke("receipt", paths[0], paths[1], "pass", 0))

    def test_pass_counts_follow_harness_phase_bodies(self):
        for group in PASS_COUNTS:
            result, receipt = self.make_receipt(context(group))
            self.assertEqual(result.returncode, 0, group)
            self.assertEqual(receipt["phases"][0]["passed"], PASS_COUNTS[group])

    def test_added_harness_assertion_changes_the_derived_count(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        copy_dir = Path(directory.name)
        for path in HERE.glob("e2e-*.sh"):
            (copy_dir / path.name).write_text(path.read_text(encoding="utf-8"), encoding="utf-8")
        for name, anchor in (("e2e-pithead.sh", "phase_network() {\n"), ("e2e-refresh-window.sh", "refresh_profile_finish() {\n")):
            text = (copy_dir / name).read_text(encoding="utf-8")
            self.assertIn(anchor, text)
            (copy_dir / name).write_text(text.replace(anchor, anchor + "    true && ok 'added'\n", 1), encoding="utf-8")
        counts = harness_counts(copy_dir)
        expected = dict(PASS_COUNTS, network=PASS_COUNTS["network"] + 1, control=PASS_COUNTS["control"] + 1)
        expected["control-replay-thermal"] += 1
        expected["control-replay-pools"] += 1
        self.assertEqual(counts, expected)
        rows = [{"event": "phase", "id": "network"}] + [{"event": "pass"}] * counts["network"]
        result, _ = self.make_receipt(context("network"), rows)
        self.assertNotEqual(result.returncode, 0)

    def test_receipt_rejects_fewer_and_extra_passes(self):
        ctx = context("connect")
        too_few = events(["connect"])
        too_few.pop()
        too_many = events(["connect"]) + [{"event": "pass"}]
        for rows in (too_few, too_many):
            result, receipt = self.make_receipt(ctx, rows)
            self.assertNotEqual(result.returncode, 0)
            self.assertIsNotNone(receipt)

    def test_check_joins_receipts_independent_of_order(self):
        first = context("connect", "first")
        second = context("dashboard", "second", "linux-aarch64")
        _, first_receipt = self.make_receipt(first)
        _, second_receipt = self.make_receipt(second)
        result = self.check([first, second], [second_receipt, first_receipt])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_check_accepts_repeated_group_on_distinct_rows_and_platforms(self):
        first = context("connect", "first")
        second = context("connect", "second", "linux-aarch64")
        _, first_receipt = self.make_receipt(first)
        _, second_receipt = self.make_receipt(second)
        result = self.check([first, second], [first_receipt, second_receipt])
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_check_rejects_missing_and_duplicate_receipts(self):
        first = context("connect", "first")
        second = context("dashboard", "second", "linux-aarch64")
        _, first_receipt = self.make_receipt(first)
        self.assert_invalid(self.check([first, second], [first_receipt]))
        self.assert_invalid(self.check([first, second], [first_receipt, first_receipt]))

    def test_check_rejects_plan_binding_disagreement_and_duplicate_rows(self):
        first = context("connect", "same")
        stale = context("dashboard", "other", "linux-aarch64")
        stale["head"] = "d" * 40
        self.assert_invalid(self.check([first, stale], []))
        duplicate = context("dashboard", "same", "linux-aarch64")
        self.assert_invalid(self.check([first, duplicate], []))

    def test_check_rejects_every_stale_receipt_binding(self):
        original = context("connect", "first")
        _, receipt = self.make_receipt(original)
        replacements = {
            "head": "d" * 40,
            "ref": "refs/tags/v1",
            "input": "e" * 64,
            "run": "f" * 32,
            "group": "network",
            "row": "other",
            "platform": "linux-aarch64",
        }
        for key, value in replacements.items():
            with self.subTest(key=key):
                changed = copy.deepcopy(receipt)
                changed["context"][key] = value
                self.assert_invalid(self.check([original], [changed]))

    def test_check_rejects_mutated_phase_cleanup_and_exit(self):
        ctx = context("connect")
        _, receipt = self.make_receipt(ctx)
        mutations = []
        missing = copy.deepcopy(receipt)
        missing["phases"] = []
        mutations.append(missing)
        negative = copy.deepcopy(receipt)
        negative["phases"][0]["passed"] = -1
        mutations.append(negative)
        boolean = copy.deepcopy(receipt)
        boolean["phases"][0]["passed"] = True
        mutations.append(boolean)
        cleanup = copy.deepcopy(receipt)
        cleanup["cleanup"] = "fail"
        mutations.append(cleanup)
        exited = copy.deepcopy(receipt)
        exited["exit_code"] = 1
        mutations.append(exited)
        extra = copy.deepcopy(receipt)
        extra["extra"] = 1
        mutations.append(extra)
        for changed in mutations:
            self.assert_invalid(self.check([ctx], [changed]))

    def test_check_rejects_empty_plan_and_duplicate_json_keys(self):
        self.assert_invalid(self.check([], []))
        paths = self.files(['[{"schema":1,"schema":1}]'])
        self.assert_invalid(self.invoke("check", paths[0]))

        ctx = context("connect")
        _, receipt = self.make_receipt(ctx)
        duplicate = json.dumps(receipt).replace('"cleanup": "pass"', '"cleanup": "pass", "cleanup": "pass"')
        paths = self.files([[ctx], duplicate])
        self.assert_invalid(self.invoke("check", *paths))


if __name__ == "__main__":
    unittest.main()
