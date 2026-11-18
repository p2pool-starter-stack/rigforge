import base64
import json
import ipaddress
import os
from pathlib import Path
import re
import shlex
import subprocess
import time
import uuid
from urllib.parse import urlsplit
from xml.etree import ElementTree


PROBE_TAG = "v99.99.99"
ALLOWED_SECOND_SOURCE = "169.254.241.3"


class ReplayError(Exception):
    pass


class PlatformError(ReplayError):
    pass


def block(text, name):
    parser = Path(__file__).with_name("docs-replay-commands.sh")
    result = subprocess.run(["bash", str(parser), "--block", name],
                            input=text, text=True, capture_output=True)
    if result.returncode:
        raise ReplayError(f"invalid {name} documentation block")
    return result.stdout


def recipes(root):
    guide = (root / "docs/getting-started.md").read_text()
    commands = {name: block(guide, name)
                for name in ("clone", "dry-run", "setup", "reboot")}
    quick = block((root / "README.md").read_text(), "quick-start")
    if quick != commands["clone"] + commands["setup"]:
        raise ReplayError("README quick start and walkthrough commands differ")
    return commands


class Guest:
    def __init__(self, domain):
        self.domain = str(uuid.UUID(domain))

    def virsh(self, *args):
        try:
            result = subprocess.run(["virsh", "--connect", "qemu:///system", *args], capture_output=True,
                                    text=True, timeout=20, env={**os.environ, "LC_ALL": "C"})
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise PlatformError("libvirt command unavailable or timed out") from exc
        if result.returncode:
            raise PlatformError("libvirt command failed")
        return result.stdout

    def agent(self, command, **arguments):
        reply = json.loads(self.virsh("qemu-agent-command", self.domain,
                                     json.dumps({"execute": command, "arguments": arguments})))
        if "error" in reply or "return" not in reply:
            raise PlatformError("guest agent command failed")
        return reply["return"]

    def start(self, script):
        return self.agent("guest-exec", path="/bin/bash", arg=["-se"],
                          **{"input-data": base64.b64encode(script.encode()).decode(),
                             "capture-output": True})["pid"]

    def run(self, script, timeout=60):
        pid = self.start(script)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            status = self.agent("guest-exec-status", pid=pid)
            if status["exited"]:
                if status.get("exitcode") != 0:
                    raise ReplayError("guest check or documented command failed")
                if status.get("out-truncated"):
                    raise ReplayError("guest command output was truncated")
                return base64.b64decode(status.get("out-data", "")).decode()
            time.sleep(1)
        raise ReplayError("guest command timed out; discard the disposable VM")

    def boot_id(self):
        value = self.run("cat /proc/sys/kernel/random/boot_id\n").strip()
        return str(uuid.UUID(value))

    def reboot(self, script, timeout=300):
        previous = self.boot_id()
        try:
            self.start(script)
        except PlatformError:
            pass
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            time.sleep(2)
            try:
                if self.boot_id() != previous:
                    return
            except (PlatformError, ReplayError, ValueError):
                pass
        state = self.virsh("domstate", self.domain).strip()
        if state != "running":
            raise PlatformError("guest remained stopped after reboot")
        raise PlatformError("guest failed to return with a new boot ID")


def candidate(root):
    result = subprocess.run(["git", "-C", str(root), "rev-parse", "HEAD"],
                            capture_output=True, text=True)
    sha = result.stdout.strip()
    if result.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ReplayError("candidate commit of the driver checkout is unavailable")
    return sha


def replay(root, guest, config):
    commands = recipes(root)
    commit = candidate(root)
    allow_from = json.loads(config)["api_allow_from"]
    token = uuid.uuid4().hex
    info = guest.virsh("dominfo", guest.domain)
    if not re.search(r"^Persistent:\s+no\s*$", info, re.MULTILINE):
        raise ReplayError("docs replay requires a transient disposable domain")
    if guest.virsh("domstate", guest.domain).strip() != "running":
        raise PlatformError("disposable guest is not running")
    if ElementTree.fromstring(guest.virsh("dumpxml", guest.domain)).get("type") != "kvm":
        raise PlatformError("docs replay requires a KVM guest")
    work = guest.run("umask 022; mktemp -d /var/tmp/rigforge-docs.XXXXXX\n").strip()
    if not re.fullmatch(r"/var/tmp/rigforge-docs\.[A-Za-z0-9]+", work):
        raise ReplayError("invalid guest scratch directory")
    quoted = shlex.quote(work)
    clone = f"{quoted}/rigforge"
    helper = base64.b64encode((root / "tests/e2e-docs-guest.sh").read_bytes()).decode()
    prepared = base64.b64encode(config).decode()
    guest.run(f"chmod 755 {quoted}\ncd {quoted}\nprintf %s {helper} | base64 -d >check.sh\n"
              f"mkdir -m 700 state\n" + commands["clone"], timeout=300)
    guest.run(f"cd {quoted}/rigforge\numask 077\nprintf %s {prepared} | base64 -d >config.json\n")
    check = f"bash {quoted}/check.sh"
    args = f"{quoted}/rigforge {quoted}/state"
    guest.run(f"{check} baseline {args}\n")
    guest.run(f"cd {quoted}/rigforge\n" + commands["dry-run"])
    guest.run(f"{check} dry-run-check {args}\n")
    print("PASS: documented clone and dry run preserved system state", flush=True)
    guest.run(f"cd {quoted}/rigforge\n" + commands["setup"], timeout=3600)
    guest.reboot(commands["reboot"])
    guest.run(f"{check} installed {args}\n", timeout=600)
    print("PASS: reboot autostart, donation, pool, shares and read-only API", flush=True)
    guest.run(f"E2E_ALLOWLIST_ALLOWED_SOURCE={ALLOWED_SECOND_SOURCE} {check} allowlist-refuse {args}\n", timeout=300)
    guest.run("cd " + clone + "\njq --arg source " + shlex.quote(ALLOWED_SECOND_SOURCE) +
              " '.api_allow_from = $source' config.json >config.tmp && mv config.tmp config.json\n"
              "sudo ./rigforge.sh apply\n", timeout=300)
    guest.run(f"E2E_ALLOWLIST_ALLOWED_SOURCE={ALLOWED_SECOND_SOURCE} {check} allowlist-accept {args}\n", timeout=180)
    guest.run("cd " + clone + "\njq --arg original " + shlex.quote(allow_from) +
              " '.api_allow_from = $original' config.json >config.tmp && mv config.tmp config.json\n"
              "sudo ./rigforge.sh apply\n", timeout=300)
    print("PASS: API allowlist refused a second source and accepted an allowed source", flush=True)
    guest.run("cd " + clone + "\njq --arg token " + shlex.quote(token) +
              " '.control = \"enabled\" | .control_upgrade = \"enabled\" | .ACCESS_TOKEN = $token'"
              " config.json >config.tmp && mv config.tmp config.json\n"
              "sudo ./rigforge.sh apply\n", timeout=600)
    guest.run(f"E2E_CONTROL_TOKEN={token} {check} control-apply {args}\n", timeout=480)
    guest.run(f"E2E_CONTROL_TOKEN={token} {check} control-revert {args}\n", timeout=480)
    print("PASS: writable control path applied one change and rolled back one change", flush=True)
    guest.run("cd " + clone + "\nprobe=$(git -c user.name=docs-replay -c user.email=docs-replay@localhost"
              " commit-tree 'HEAD^{tree}' -p HEAD -m 'docs replay upgrade probe')\n"
              "git tag " + PROBE_TAG + " \"$probe\"\n", timeout=120)
    guest.run(f"E2E_CONTROL_TOKEN={token} E2E_UPGRADE_LEG=noop E2E_CONTROL_PROBE_TAG={PROBE_TAG} "
              f"{check} upgrade-leg {args}\n", timeout=480)
    guest.run(f"E2E_CONTROL_TOKEN={token} E2E_UPGRADE_LEG=refused E2E_CONTROL_PROBE_TAG={PROBE_TAG} "
              f"{check} upgrade-leg {args}\n", timeout=900)
    print("PASS: remote-upgrade chain reached noop and refused a forged tag with the checkout intact", flush=True)
    guest.run(f"cd {quoted}/rigforge\ngit fetch --quiet --tags origin\n"
              f"git fetch --quiet origin {commit}\ngit checkout --quiet --force FETCH_HEAD\n"
              "sudo ./rigforge.sh upgrade\n", timeout=2400)
    guest.run(f"E2E_CONTROL_TOKEN={token} E2E_EXPECTED_HEAD={commit} {check} upgraded {args}\n", timeout=900)
    print("PASS: remote upgrade from the previous release to the candidate kept shares landing", flush=True)
    digest = guest.run(f"cd {quoted}/rigforge\nsha256sum config.json | awk '{{print $1}}'\n").strip()
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ReplayError("config digest is unreadable")
    archive = guest.run(f"cd {quoted}/rigforge\nsudo ./rigforge.sh backup --yes\n"
                        "ls -1 backups/rigforge-backup-*.tar.gz | sort | tail -1\n",
                        timeout=300).strip().splitlines()[-1]
    if not re.fullmatch(r"backups/rigforge-backup-[0-9]{8}-[0-9]{6}\.tar\.gz", archive):
        raise ReplayError("backup archive path is invalid")
    guest.run(f"cd {quoted}/rigforge\njq '.DONATION = 1' config.json >config.tmp && mv config.tmp config.json\n")
    guest.run(f"cd {quoted}/rigforge\nsudo ./rigforge.sh restore --yes {shlex.quote(archive)}\n", timeout=300)
    guest.run(f"E2E_RESTORED_CONFIG_SHA256={digest} {check} restored {args}\n", timeout=120)
    print("PASS: backup and restore round-tripped the config", flush=True)
    guest.run(f"cd {quoted}/rigforge\nsudo ./rigforge.sh uninstall --yes\n", timeout=120)
    guest.reboot(commands["reboot"])
    guest.run(f"{check} removed {args}\n")
    print("PASS: uninstall remained complete after reboot", flush=True)
    guest.run(f"cd {quoted}/rigforge\numask 077\nprintf %s {prepared} | base64 -d >config.json\n")
    guest.run(f"cd {quoted}/rigforge\nsudo env RIGFORGE_APPLIANCE=1 LC_ALL=C ./rigforge.sh\n", timeout=3600)
    guest.run(f"{check} appliance {args}\n", timeout=300)
    print("PASS: appliance mode ran with runtime-only units on the stock systemd guest", flush=True)
    guest.run(f"cd {quoted}/rigforge\nsudo env RIGFORGE_APPLIANCE=1 ./rigforge.sh uninstall --yes\n", timeout=120)


def check_config(config):
    data = json.loads(config)
    allowed = {"pools", "DONATION", "api_allow_from", "HOME_DIR", "threads"}
    if not isinstance(data, dict) or set(data) - allowed:
        raise ReplayError("prepared config contains unsupported settings")
    pools = data.get("pools", [])
    if not isinstance(pools, list) or len(pools) != 1 or not isinstance(pools[0], dict):
        raise ReplayError("prepared config needs exactly one throwaway pool")
    if (set(pools[0]) - {"url", "user", "pass"}
            or not isinstance(pools[0].get("url"), str)
            or not pools[0]["url"] or "://" in pools[0]["url"]
            or data.get("DONATION", 0) != 0
            or not isinstance(data.get("api_allow_from"), str) or not data["api_allow_from"]
            or data.get("HOME_DIR") not in (None, "", "DYNAMIC_HOME")
            or pools[0].get("user", "docs-replay") != "docs-replay"
            or pools[0].get("pass", "x") not in ("", "x")):
        raise ReplayError("prepared config needs one throwaway pool, donation zero and an API allowlist")
    try:
        ipaddress.ip_network(data["api_allow_from"], strict=False)
    except ValueError:
        raise ReplayError("prepared config api_allow_from must be one valid address or network") from None
    endpoint = urlsplit("//" + pools[0]["url"])
    if (not endpoint.hostname or not endpoint.port or endpoint.username is not None
            or endpoint.password is not None or endpoint.path or endpoint.query or endpoint.fragment
            or any(c.isspace() for c in pools[0]["url"])):
        raise ReplayError("prepared pool must be a plain endpoint without credentials")


def main():
    root = Path(__file__).resolve().parent.parent
    if os.environ.get("E2E_DOCS_DISPOSABLE") != "1":
        raise ReplayError("set E2E_DOCS_DISPOSABLE=1 only for a throwaway VM")
    domain = os.environ.get("E2E_DOCS_VM_UUID", "")
    config = Path(os.environ["E2E_DOCS_CONFIG"]).read_bytes()
    check_config(config)
    replay(root, Guest(domain), config)


if __name__ == "__main__":
    try:
        main()
    except PlatformError as error:
        print(f"PLATFORM FAIL: {error}")
        raise SystemExit(2)
    except (ReplayError, KeyError, ValueError, OSError, ElementTree.ParseError) as error:
        print(f"FAIL: {error}" if isinstance(error, ReplayError) else "FAIL: invalid replay inputs")
        raise SystemExit(1)
