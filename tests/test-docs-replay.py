import base64
import ipaddress
import json
import os
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

from docs_replay import Guest, PlatformError, ReplayError, block, check_config, recipes, replay


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
    def setUp(self):
        self.root = Path(__file__).resolve().parent.parent
        self.guest = Mock()
        self.guest.virsh.side_effect = ["Persistent: no\n", "running\n", "<domain type='kvm' />"]
        self.guest.run.side_effect = ["/var/tmp/rigforge-docs.TEST\n"] + [""] * 9

    def test_documents_drive_commands_across_both_reboots(self):
        with patch("builtins.print"):
            replay(self.root, self.guest, b"{}")
        commands = recipes(self.root)
        scripts = [call.args[0] for call in self.guest.run.call_args_list]
        self.assertTrue(scripts[1].endswith(commands["clone"]))
        self.assertIn("config.json", scripts[2])
        self.assertIn(" baseline ", scripts[3])
        self.assertTrue(scripts[4].endswith(commands["dry-run"]))
        self.assertIn(" dry-run-check ", scripts[5])
        self.assertTrue(scripts[6].endswith(commands["setup"]))
        self.assertIn(" installed ", scripts[7])
        self.assertIn("uninstall --yes", scripts[8])
        self.assertIn(" removed ", scripts[9])
        self.assertEqual([call.args[0] for call in self.guest.reboot.call_args_list],
                         [commands["reboot"], commands["reboot"]])

    def test_persistent_domain_is_refused_before_mutation(self):
        self.guest.virsh.side_effect = None
        self.guest.virsh.return_value = "Persistent: yes\n"
        with self.assertRaisesRegex(ReplayError, "transient"):
            replay(self.root, self.guest, b"{}")
        self.guest.run.assert_not_called()

    def test_stopped_domain_is_refused_before_mutation(self):
        self.guest.virsh.side_effect = ["Persistent: no\n", "shut off\n"]
        with self.assertRaisesRegex(PlatformError, "not running"):
            replay(self.root, self.guest, b"{}")
        self.guest.run.assert_not_called()

    def test_emulated_domain_is_refused_before_mutation(self):
        self.guest.virsh.side_effect = ["Persistent: no\n", "running\n", "<domain type='qemu' />"]
        with self.assertRaisesRegex(PlatformError, "KVM"):
            replay(self.root, self.guest, b"{}")
        self.guest.run.assert_not_called()

    def test_failed_dry_run_check_prevents_setup(self):
        self.guest.run.side_effect = ["/var/tmp/rigforge-docs.TEST\n"] + [""] * 4 + [ReplayError("changed")]
        with self.assertRaisesRegex(ReplayError, "changed"):
            replay(self.root, self.guest, b"{}")
        self.guest.reboot.assert_not_called()
        self.assertEqual(self.guest.run.call_count, 6)


if __name__ == "__main__":
    unittest.main()
