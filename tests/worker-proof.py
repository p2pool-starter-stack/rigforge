#!/usr/bin/env python3
import json
from pathlib import Path
import re
import sys


CONTEXT_FIELDS = {
    "schema",
    "head",
    "ref",
    "input",
    "run",
    "group",
    "row",
    "platform",
    "allowed_skips",
}
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
GROUPS = set(ALL_PHASES) | {
    "all",
    "network-sequence",
    "control-replay-thermal",
    "control-replay-pools",
}
PASS_COUNTS = {
    "connect": 8,
    "worker-api": 10,
    "api-impact": 3,
    "network": 10,
    "stratum-auth": 4,
    "dashboard": 2,
    "dev-fee": 1,
    "control": 5,
    "access-tokens": 7,
    "control-replay-thermal": 9,
    "control-replay-pools": 9,
}
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
HEX32 = re.compile(r"[0-9a-f]{32}\Z")
ROW = re.compile(r"[a-z][a-z0-9_-]{0,63}\Z")


class Invalid(Exception):
    pass


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Invalid
        result[key] = value
    return result


def parse_json(text):
    try:
        return json.loads(
            text,
            object_pairs_hook=unique_object,
            parse_constant=lambda value: (_ for _ in ()).throw(Invalid()),
        )
    except (Invalid, json.JSONDecodeError, RecursionError, UnicodeError):
        raise Invalid from None


def read_json(path):
    try:
        return parse_json(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError):
        raise Invalid from None


def exact_object(value, fields):
    if not isinstance(value, dict) or set(value) != fields:
        raise Invalid


def valid_ref(value):
    if not isinstance(value, str) or not value.startswith(("refs/heads/", "refs/tags/", "refs/pull/")):
        return False
    if any(ord(char) < 33 or ord(char) > 126 for char in value):
        return False
    if any(token in value for token in ("..", "//", "@{", "\\", "~", "^", ":", "?", "*", "[")):
        return False
    if value.endswith(("/", ".")):
        return False
    parts = value.split("/")
    if any(not part or part.startswith(".") or part.endswith(".lock") for part in parts):
        return False
    if value.startswith("refs/pull/"):
        return len(parts) == 4 and parts[2].isdigit() and parts[2] != "0" and parts[3] in {"head", "merge"}
    return len(parts) >= 3


def phase_ids(group):
    if group == "all":
        return ALL_PHASES
    if group == "network-sequence":
        return ALL_PHASES[:4]
    return [group]


def validate_context(value, expected_group=None):
    exact_object(value, CONTEXT_FIELDS)
    if type(value["schema"]) is not int or value["schema"] != 1:
        raise Invalid
    if not isinstance(value["head"], str) or not HEX40.fullmatch(value["head"]):
        raise Invalid
    if not valid_ref(value["ref"]):
        raise Invalid
    if not isinstance(value["input"], str) or not HEX64.fullmatch(value["input"]):
        raise Invalid
    if not isinstance(value["run"], str) or not HEX32.fullmatch(value["run"]):
        raise Invalid
    if not isinstance(value["group"], str) or value["group"] not in GROUPS or (
        expected_group is not None and value["group"] != expected_group
    ):
        raise Invalid
    if not isinstance(value["row"], str) or not ROW.fullmatch(value["row"]):
        raise Invalid
    if not isinstance(value["platform"], str) or value["platform"] not in {"linux-x86_64", "linux-aarch64"}:
        raise Invalid
    skips = value["allowed_skips"]
    if not isinstance(skips, dict) or not all(isinstance(key, str) and isinstance(item, str) for key, item in skips.items()):
        raise Invalid
    allowed = {}
    if value["group"] == "all":
        allowed = {
            "stratum-auth": "stratum-fixture-absent",
            "dashboard": "dashboard-fixture-absent",
        }
    elif value["group"] == "dashboard":
        allowed = {"dashboard": "dashboard-fixture-absent"}
    if any(allowed.get(key) != item for key, item in skips.items()):
        raise Invalid
    return value


def valid_counter(value):
    return type(value) is int and value >= 0


def validate_receipt(receipt, expected=None):
    exact_object(receipt, {"schema", "context", "phases", "cleanup", "exit_code"})
    if type(receipt["schema"]) is not int or receipt["schema"] != 1:
        raise Invalid
    context = validate_context(receipt["context"])
    if expected is not None and context != expected:
        raise Invalid
    phases = receipt["phases"]
    if not isinstance(phases, list) or len(phases) != len(phase_ids(context["group"])):
        raise Invalid
    if [row.get("id") if isinstance(row, dict) else None for row in phases] != phase_ids(context["group"]):
        raise Invalid
    for row in phases:
        exact_object(row, {"id", "passed", "failed", "skipped"})
        if not valid_counter(row["passed"]) or not valid_counter(row["failed"]):
            raise Invalid
        if not isinstance(row["skipped"], list) or not all(isinstance(item, str) for item in row["skipped"]):
            raise Invalid
        expected_skip = context["allowed_skips"].get(row["id"])
        passed = row["passed"] == PASS_COUNTS[row["id"]] and row["failed"] == 0 and row["skipped"] == []
        skipped = expected_skip is not None and row["passed"] == 0 and row["failed"] == 0 and row["skipped"] == [expected_skip]
        if not (passed or skipped):
            raise Invalid
    if receipt["cleanup"] != "pass" or type(receipt["exit_code"]) is not int or receipt["exit_code"] != 0:
        raise Invalid
    return receipt


def parse_events(path, context):
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        raise Invalid from None
    phases = []
    expected = phase_ids(context["group"])
    current = None
    for line in lines:
        if not line:
            raise Invalid
        event = parse_json(line)
        if not isinstance(event, dict) or "event" not in event:
            raise Invalid
        kind = event["event"]
        if kind == "phase":
            exact_object(event, {"event", "id"})
            if len(phases) >= len(expected) or event["id"] != expected[len(phases)]:
                raise Invalid
            current = {"id": event["id"], "passed": 0, "failed": 0, "skipped": []}
            phases.append(current)
            continue
        if current is None:
            raise Invalid
        if kind == "pass":
            exact_object(event, {"event"})
            current["passed"] += 1
        elif kind == "fail":
            exact_object(event, {"event"})
            current["failed"] += 1
        elif kind == "skip":
            exact_object(event, {"event", "reason"})
            reason = context["allowed_skips"].get(current["id"])
            if event["reason"] != reason:
                raise Invalid
            current["skipped"].append(event["reason"])
        else:
            raise Invalid
    return phases


def command_context(args):
    if len(args) != 1 or args[0] not in GROUPS:
        raise Invalid
    context = validate_context(parse_json(sys.stdin.read()), args[0])
    print(json.dumps(context, sort_keys=True, separators=(",", ":")))
    return 0


def command_receipt(args):
    if len(args) != 4 or args[2] not in {"pass", "fail", "unknown"} or not re.fullmatch(r"-?(0|[1-9][0-9]*)", args[3]):
        raise Invalid
    context = validate_context(read_json(args[0]))
    cleanup = "pass" if args[2] == "pass" else "fail"
    exit_code = int(args[3])
    try:
        phases = parse_events(args[1], context)
    except Invalid:
        receipt = {
            "schema": 1,
            "context": context,
            "phases": [],
            "cleanup": cleanup,
            "exit_code": exit_code or 1,
        }
        print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
        return 1
    receipt = {
        "schema": 1,
        "context": context,
        "phases": phases,
        "cleanup": cleanup,
        "exit_code": exit_code,
    }
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    try:
        validate_receipt(receipt, context)
    except Invalid:
        return 1
    return 0


def command_check(args):
    if len(args) < 2:
        raise Invalid
    plan = read_json(args[0])
    if not isinstance(plan, list) or not plan:
        raise Invalid
    contexts = [validate_context(item) for item in plan]
    binding = {key: contexts[0][key] for key in ("head", "ref", "input", "run")}
    if any(any(item[key] != value for key, value in binding.items()) for item in contexts):
        raise Invalid
    if len({item["row"] for item in contexts}) != len(contexts):
        raise Invalid
    expected = {json.dumps(item, sort_keys=True, separators=(",", ":")): item for item in contexts}
    if len(expected) != len(contexts) or len(args[1:]) != len(contexts):
        raise Invalid
    seen = set()
    for path in args[1:]:
        receipt = read_json(path)
        exact_object(receipt, {"schema", "context", "phases", "cleanup", "exit_code"})
        key = json.dumps(receipt["context"], sort_keys=True, separators=(",", ":"))
        if key not in expected or key in seen:
            raise Invalid
        validate_receipt(receipt, expected[key])
        seen.add(key)
    if seen != set(expected):
        raise Invalid
    return 0


def main():
    if len(sys.argv) < 2:
        raise Invalid
    commands = {"context": command_context, "receipt": command_receipt, "check": command_check}
    command = commands.get(sys.argv[1])
    if command is None:
        raise Invalid
    return command(sys.argv[2:])


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (Invalid, KeyError, TypeError, ValueError):
        print("worker-proof: invalid input", file=sys.stderr)
        sys.exit(2)
