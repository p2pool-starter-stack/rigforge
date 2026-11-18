import base64
import ipaddress
import json
import os
from pathlib import Path
import subprocess
import unittest
from unittest.mock import Mock, patch

import docs_replay
from docs_replay import (Guest, PlatformError, ReplayError, block, candidate,
                         check_config, recipes, replay)


class Markers(unittest.TestCase):
    def test_repository_recipes(self):
        self.assertEqual(set(recipes(Path(__file__).resolve().parent.parent)),
                         {"clone", "dry-run", "setup", "reboot"})

    def test_extracts_verbatim(self):
        text = "<!-- docs-replay:setup:begin -->\n```bash\nsudo ./rigforge.sh\n```\n<!-- docs-replay:setup:end -->"
        self.assertEqual(block(text, "setup"), "sudo ./rigforge.sh\n")
        self.assertEqual(block(text.replace("rigforge.sh", "rigforge.sh setup"), "setup"),
                         "sudo ./rigforge.sh setup\n")

    def test_missing_duplicate_empty_reversed_and_malformed_blocks_fail(self):
        begin = "<!-- docs-replay:setup:begin -->"
        end = "<!-- docs-replay:setup:end -->"
        for text in ("", begin + begin + end, end + begin,
                     begin + "\n```bash\n\n```\n" + end,
                     begin + "\n```bash\nif\n```\n" + end,
                     begin + "echo unmarked" + end):
            with self.subTest(text=text), self.assertRaises(ReplayError):
                block(text, "setup")


class Configuration(unittest.TestCase):
    def config(self):
        return {"pools": [{"url": f"fixture-{os.getpid()}:{10000 + os.getpid() % 40000}",
                           "user": "docs-replay", "pass": "x"}],
                "api_allow_from": str(ipaddress.IPv4Address(os.getpid()))}

    def test_minimal_fixture_is_accepted(self):
        check_config(json.dumps(self.config()))

    def test_credentials_and_extra_settings_are_rejected(self):
        for field, value in (("ACCESS_TOKEN", "fixture"), ("api", "enabled"),
                             ("control", "enabled"), ("DONATION", 1)):
            data = self.config()
            data[field] = value
            with self.subTest(field=field), self.assertRaises(ReplayError):
                check_config(json.dumps(data))
        for field, value in (("user", "nonfixture"), ("pass", "nonfixture"), ("tls", True)):
            data = self.config()
            data["pools"][0][field] = value
            with self.subTest(field=field), self.assertRaises(ReplayError):
                check_config(json.dumps(data))

    def test_endpoint_cannot_embed_credentials_or_a_path(self):
        for transform in (lambda url: "credential@" + url, lambda url: url + "/path"):
            data = self.config()
            data["pools"][0]["url"] = transform(data["pools"][0]["url"])
            with self.assertRaises(ReplayError):
                check_config(json.dumps(data))

    def test_allowlist_accepts_the_lane_comma_list_and_rejects_invalid_members(self):
        data = self.config()
        data["api_allow_from"] = f"{data['api_allow_from']}, ::1/128"
        check_config(json.dumps(data))
        for value in ("127.0.0.1/32, not-a-network", "127.0.0.1/32,", " "):
            data = self.config()
            data["api_allow_from"] = value
            with self.subTest(value=value), self.assertRaises(ReplayError):
                check_config(json.dumps(data))


class Candidate(unittest.TestCase):
    def test_driver_checkout_head_is_the_candidate(self):
        completed = Mock(return_value=Mock(returncode=0, stdout="ab" * 20 + "\n"))
        with patch.object(docs_replay.subprocess, "run", completed):
            self.assertEqual(candidate(Path("/fixture")), "ab" * 20)

    def test_missing_or_malformed_head_is_refused(self):
        for result in (Mock(returncode=128, stdout=""), Mock(returncode=0, stdout="main\n")):
            with self.subTest(returncode=result.returncode), \
                    patch.object(docs_replay.subprocess, "run", Mock(return_value=result)), \
                    self.assertRaises(ReplayError):
                candidate(Path("/fixture"))


class Agent(unittest.TestCase):
    def setUp(self):
        self.guest = Guest("00000000-0000-4000-8000-000000000001")

    def test_non_uuid_domain_refused(self):
        with self.assertRaises(ValueError):
            Guest("existing-domain")

    def test_exec_requires_success(self):
        for status in ({"exited": True, "exitcode": 1},
                       {"exited": True, "signal": 9},
                       {"exited": True, "exitcode": 0, "out-truncated": True}):
            with self.subTest(status=status), patch.object(self.guest, "agent", side_effect=[{"pid": 42}, status]):
                with self.assertRaises(ReplayError):
                    self.guest.run("true\n")

    def test_exec_preserves_script_and_decodes_output(self):
        status = {"exited": True, "exitcode": 0,
                  "out-data": base64.b64encode(b"done\n").decode()}
        with patch.object(self.guest, "agent", side_effect=[{"pid": 42}, status]) as agent:
            self.assertEqual(self.guest.run("printf 'done\\n'\n"), "done\n")
            arguments = agent.call_args_list[0].kwargs
            self.assertEqual(base64.b64decode(arguments["input-data"]), b"printf 'done\\n'\n")

    def test_reboot_requires_new_boot_id(self):
        with patch.object(self.guest, "boot_id", side_effect=["before", "before", "after"]), \
                patch.object(self.guest, "start"), patch("docs_replay.time.sleep"):
            self.guest.reboot("sudo reboot\n")

    def test_reboot_can_disconnect_before_exec_acknowledgement(self):
        with patch.object(self.guest, "boot_id", side_effect=["before", "after"]), \
                patch.object(self.guest, "start", side_effect=PlatformError("disconnected")), \
                patch("docs_replay.time.sleep"):
            self.guest.reboot("sudo reboot\n")

    def test_stopped_guest_is_platform_failure(self):
        with patch.object(self.guest, "boot_id", return_value="before"), \
                patch.object(self.guest, "start"), \
                patch.object(self.guest, "virsh", return_value="shut off\n"):
            with self.assertRaisesRegex(PlatformError, "remained stopped"):
                self.guest.reboot("sudo reboot\n", timeout=0)

    def test_running_guest_without_new_boot_is_not_autostart_failure(self):
        with patch.object(self.guest, "boot_id", return_value="before"), \
                patch.object(self.guest, "start"), \
                patch.object(self.guest, "virsh", return_value="running\n"):
            with self.assertRaisesRegex(PlatformError, "new boot ID"):
                self.guest.reboot("sudo reboot\n", timeout=0)


class Sequence(unittest.TestCase):
    CANDIDATE = "cd" * 20

    def setUp(self):
        self.root = Path(__file__).resolve().parent.parent
        self.guest = Mock()
        self.guest.virsh.side_effect = ["Persistent: no\n", "running\n", "<domain type='kvm' />"]
        self.guest.run.side_effect = (["/var/tmp/rigforge-docs.TEST\n"] + [""] * 19 +
                                      ["a" * 64 + "\n", "backups/rigforge-backup-20261117-010203.tar.gz\n"] +
                                      [""] * 9)
        self.config = json.dumps({
            "pools": [{"url": f"fixture-{os.getpid()}:12345", "user": "docs-replay", "pass": "x"}],
            "DONATION": 0, "api_allow_from": "127.0.0.1/32, ::1/128"}).encode()
        patcher = patch.object(docs_replay, "candidate", return_value=self.CANDIDATE)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_full_battery_drives_both_reboots_in_order(self):
        with patch("builtins.print"):
            replay(self.root, self.guest, self.config)
        commands = recipes(self.root)
        scripts = [call.args[0] for call in self.guest.run.call_args_list]
        self.assertEqual(len(scripts), 31)
        self.assertTrue(scripts[1].endswith(commands["clone"]))
        self.assertIn("config.json", scripts[2])
        for index, marker in ((3, " baseline "), (4, commands["dry-run"]), (5, " dry-run-check "),
                              (6, commands["setup"]), (7, " installed "),
                              (8, " allowlist-refuse "), (9, "169.254.241.3"),
                              (10, " allowlist-accept "), (12, '.control = "enabled"'),
                              (13, " control-apply "), (14, " control-revert "),
                              (15, "git tag v99.99.99"), (16, "E2E_UPGRADE_LEG=noop"),
                              (17, "E2E_UPGRADE_LEG=refused"),
                              (18, f"git fetch --quiet origin {self.CANDIDATE}"),
                              (19, f"E2E_EXPECTED_HEAD={self.CANDIDATE}"), (19, "check.sh upgraded"),
                              (20, "sha256sum config.json"), (21, "backup --yes"),
                              (23, "restore --yes backups/rigforge-backup-20261117-010203.tar.gz"),
                              (24, "E2E_RESTORED_CONFIG_SHA256=" + "a" * 64),
                              (25, "uninstall --yes"), (26, " removed "),
                              (28, "RIGFORGE_APPLIANCE=1 LC_ALL=C ./rigforge.sh"), (29, " appliance ")):
            with self.subTest(marker=marker):
                self.assertIn(marker, scripts[index])
        self.assertEqual([call.args[0] for call in self.guest.reboot.call_args_list],
                         [commands["reboot"], commands["reboot"]])

    def test_bad_digest_or_archive_path_stops_before_restore(self):
        for digest, archive, stop in (
                ("not-a-digest", "backups/rigforge-backup-20261117-010203.tar.gz", 21),
                ("a" * 64, "backups/untrusted.tar.gz", 22)):
            with self.subTest(archive=archive):
                self.guest.reset_mock()
                self.guest.virsh.side_effect = ["Persistent: no\n", "running\n", "<domain type='kvm' />"]
                self.guest.run.side_effect = (["/var/tmp/rigforge-docs.TEST\n"] + [""] * 19 +
                                              [digest + "\n", archive + "\n"])
                with patch("builtins.print"), self.assertRaisesRegex(ReplayError, "digest|archive"):
                    replay(self.root, self.guest, self.config)
                self.assertEqual(self.guest.run.call_count, stop)

    def test_persistent_domain_is_refused_before_mutation(self):
        self.guest.virsh.side_effect = None
        self.guest.virsh.return_value = "Persistent: yes\n"
        with self.assertRaisesRegex(ReplayError, "transient"):
            replay(self.root, self.guest, self.config)
        self.guest.run.assert_not_called()

    def test_stopped_domain_is_refused_before_mutation(self):
        self.guest.virsh.side_effect = ["Persistent: no\n", "shut off\n"]
        with self.assertRaisesRegex(PlatformError, "not running"):
            replay(self.root, self.guest, self.config)
        self.guest.run.assert_not_called()

    def test_emulated_domain_is_refused_before_mutation(self):
        self.guest.virsh.side_effect = ["Persistent: no\n", "running\n", "<domain type='qemu' />"]
        with self.assertRaisesRegex(PlatformError, "KVM"):
            replay(self.root, self.guest, self.config)
        self.guest.run.assert_not_called()

    def test_failed_dry_run_check_prevents_setup(self):
        self.guest.run.side_effect = ["/var/tmp/rigforge-docs.TEST\n"] + [""] * 4 + [ReplayError("changed")]
        with self.assertRaisesRegex(ReplayError, "changed"):
            replay(self.root, self.guest, self.config)
        self.guest.reboot.assert_not_called()
        self.assertEqual(self.guest.run.call_count, 6)


if __name__ == "__main__":
    unittest.main()
