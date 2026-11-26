"""install.sh keeps every HERMES_MOBILE_* setting across a reinstall.

The installer runs for real, but only inside a scratch HOME with PATH shims that log instead of touching
launchd, systemd, tailscale, curl or lsof. It never sees the real HOME."""
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

BRIDGE = Path(__file__).resolve().parents[1] / "Bridge"
sys.path.insert(0, str(BRIDGE))
import install_env  # noqa: E402

JSON_VAL = '{"alpha":["bot-a","bot b"],"q":"it\'s 100%"}'
SETTINGS = {
    "HERMES_MOBILE_OWNER_LOGIN": "owner@example.com",
    "HERMES_MOBILE_OWNER_MANAGED": "1",
    "HERMES_MOBILE_TRUST_TAILSCALE_SERVE": "1",
    "HERMES_MOBILE_PERSONA_HOSTS": '["bot-a","bacta-protocol"]',
    "HERMES_MOBILE_MANAGEABLE_BOTS": '["captains-log"]',
    "HERMES_MOBILE_WORKSPACE_BOTS": JSON_VAL,
    "HERMES_MOBILE_WORKSPACES": '{"alpha":["bot-a"]}',
    "HERMES_MOBILE_MEDIA_MAX_BYTES": "4096",
}


class Parsing(unittest.TestCase):
    def test_merge_rules(self):
        existing = {"HERMES_MOBILE_A": "old", "HERMES_MOBILE_B": "keep", "HERMES_MOBILE_C": "gone"}
        merged, adopted, over, removed = install_env.merge(
            existing, {"HERMES_MOBILE_A": "new", "HERMES_MOBILE_C": "", "HERMES_MOBILE_LABEL": "x",
                       "HERMES_MOBILE_D": "d", "PATH": "/bin", "hermes_mobile_e": "no"})
        self.assertEqual(merged, {"HERMES_MOBILE_A": "new", "HERMES_MOBILE_B": "keep", "HERMES_MOBILE_D": "d"})
        self.assertEqual((adopted, over, removed), (["HERMES_MOBILE_B"], ["HERMES_MOBILE_A"], ["HERMES_MOBILE_C"]))

    def test_unit_parser_handles_quotes_and_escapes(self):
        d = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, d)
        u = d / "x.service"
        u.write_text('[Service]\nEnvironment=HERMES_MOBILE_PORT=9131\n'
                     'Environment="HERMES_MOBILE_J={\\"a\\":[1,2]} 100%%"\n'
                     "Environment='HERMES_MOBILE_OLD={\"x\":[\"y\"]}'\nEnvironment=OTHER=1 HERMES_MOBILE_TWO=2\n")
        self.assertEqual(install_env.read_unit(str(u)), {
            "HERMES_MOBILE_PORT": "9131", "HERMES_MOBILE_J": '{"a":[1,2]} 100%',
            "HERMES_MOBILE_OLD": '{"x":["y"]}', "HERMES_MOBILE_TWO": "2"})


class Sandbox(unittest.TestCase):
    OS = "Darwin"

    def setUp(self):
        self.root = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="install-sbx-"))).resolve()
        self.home = self.root / "home"
        self.home.mkdir()
        self.shims = self.root / "shims"
        self.shims.mkdir()
        self.calls = self.root / "calls.log"
        for name in ("launchctl", "systemctl", "tailscale", "curl", "lsof", "loginctl"):
            f = self.shims / name
            body = '#!/bin/sh\necho "%s $*" >> "%s"\n' % (name, self.calls)
            if name == "launchctl":  # `print` fails while the "job" is marked not loaded
                body += '[ "$1" = print ] && [ -e "%s" ] && exit 1\n' % (self.root / "not-loaded")
            f.write_text(body + "exit 0\n")
            f.chmod(0o755)
        if self.OS == "Linux":
            f = self.shims / "uname"
            f.write_text('#!/bin/sh\necho Linux\n')
            f.chmod(0o755)
        self.label = "local.test.sandbox"
        self.plist = self.home / "Library/LaunchAgents" / (self.label + ".plist")
        self.unit = self.home / ".config/systemd/user/hermes-mobile-bridge.service"

    def run_install(self, **extra):
        env = {"HOME": str(self.home), "PATH": "%s:/usr/bin:/bin:/usr/sbin:/sbin" % self.shims,
               "HERMES_HOME": str(self.home / ".hermes"), "XDG_DATA_HOME": str(self.home / "share"),
               "XDG_CONFIG_HOME": str(self.home / ".config"), "HERMES_PYTHON": sys.executable,
               "HERMES_MOBILE_LABEL": self.label, "HERMES_MOBILE_PORT": "9561", "TMPDIR": str(self.root)}
        env.update(extra)
        env = {k: v for k, v in env.items() if v is not None}  # None = leave unset
        self.assertTrue(str(self.home).startswith(str(self.root)))  # never the real HOME
        r = subprocess.run(["/bin/bash", str(BRIDGE / "install.sh")], env=env, capture_output=True, text=True,
                           timeout=120, cwd=str(self.root))
        return r

    def written(self):
        if self.OS == "Linux":
            return install_env.read_unit(str(self.unit))
        with open(self.plist, "rb") as f:
            return {k: v for k, v in plistlib.load(f)["EnvironmentVariables"].items() if k.startswith("HERMES_MOBILE_")}

    def port(self):
        if self.OS == "Linux":
            return install_env.read_unit(str(self.unit))["HERMES_MOBILE_PORT"]
        with open(self.plist, "rb") as f:
            return plistlib.load(f)["EnvironmentVariables"]["HERMES_MOBILE_PORT"]

    def calls_since(self, mark):
        return self.calls.read_text().splitlines()[mark:] if self.calls.exists() else []

    def mark(self):
        return len(self.calls_since(0))

    def check_reinstall(self):
        r1 = self.run_install(**SETTINGS)
        self.assertEqual(r1.returncode, 0, r1.stderr)
        first = self.written()
        for k, v in SETTINGS.items():
            self.assertEqual(first[k], v, k)
        self.assertNotIn("HERMES_MOBILE_LABEL", first)
        # Reinstall with NO settings in the environment: nothing is lost.
        r2 = self.run_install()
        self.assertEqual(r2.returncode, 0, r2.stderr)
        self.assertEqual(self.written(), first)
        self.assertIn("Kept from the existing service", r2.stderr)
        for k in SETTINGS:
            self.assertIn(k, r2.stderr)
        for v in ("owner@example.com", "bacta-protocol", "4096"):
            self.assertNotIn(v, r2.stdout + r2.stderr)  # names only, never values
        # The caller's environment overrides one value, the rest survive, empty removes.
        r3 = self.run_install(HERMES_MOBILE_OWNER_LOGIN="new@example.com", HERMES_MOBILE_MEDIA_MAX_BYTES="")
        self.assertEqual(r3.returncode, 0, r3.stderr)
        third = self.written()
        self.assertEqual(third["HERMES_MOBILE_OWNER_LOGIN"], "new@example.com")
        self.assertNotIn("HERMES_MOBILE_MEDIA_MAX_BYTES", third)
        for k in SETTINGS:
            if k not in ("HERMES_MOBILE_OWNER_LOGIN", "HERMES_MOBILE_MEDIA_MAX_BYTES"):
                self.assertEqual(third[k], SETTINGS[k], k)
        # The port is adopted when the caller doesn't set one.
        env_no_port = dict(HERMES_MOBILE_PORT=None)
        r4 = self.run_install(**env_no_port)
        self.assertEqual(r4.returncode, 0, r4.stderr)
        self.assertEqual(self.port(), "9561")
        # The service manager was only ever called through the logging shims.
        self.assertTrue(self.calls.exists())


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("plutil"), "needs macOS plutil")
class MacInstaller(Sandbox):
    OS = "Darwin"

    def test_reinstall_keeps_settings(self):
        self.check_reinstall()
        self.assertIn("launchctl bootstrap", self.calls.read_text())

    def test_first_install_bootstraps(self):
        r = self.run_install(**SETTINGS)
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = "\n".join(self.calls_since(0))
        self.assertIn("launchctl bootout", calls)
        self.assertIn("launchctl bootstrap", calls)
        self.assertNotIn("launchctl kickstart", calls)
        self.assertIn("bootstrap", r.stdout)

    def test_unchanged_reinstall_kickstarts_only(self):
        self.assertEqual(self.run_install(**SETTINGS).returncode, 0)
        before = self.plist.read_bytes()
        m = self.mark()
        r = self.run_install()  # settings come from the installed plist
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = "\n".join(self.calls_since(m))
        self.assertIn("launchctl kickstart -k gui/", calls)
        self.assertIn(self.label, calls)
        self.assertNotIn("bootstrap", calls)
        self.assertNotIn("bootout", calls)
        self.assertEqual(self.plist.read_bytes(), before)  # plist left alone
        self.assertIn("kickstart (no bootstrap)", r.stdout)
        self.assertIn("/m/ping", "\n".join(self.calls_since(m)))
        for v in ("owner@example.com", "bacta-protocol"):
            self.assertNotIn(v, r.stdout + r.stderr)

    def test_changed_setting_bootstraps_again(self):
        self.assertEqual(self.run_install(**SETTINGS).returncode, 0)
        m = self.mark()
        r = self.run_install(HERMES_MOBILE_MEDIA_MAX_BYTES="8192")
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = "\n".join(self.calls_since(m))
        self.assertIn("launchctl bootout", calls)
        self.assertIn("launchctl bootstrap", calls)
        self.assertNotIn("kickstart", calls)
        self.assertEqual(self.written()["HERMES_MOBILE_MEDIA_MAX_BYTES"], "8192")

    def test_unchanged_but_not_loaded_bootstraps(self):
        self.assertEqual(self.run_install(**SETTINGS).returncode, 0)
        (self.root / "not-loaded").write_text("")
        m = self.mark()
        r = self.run_install()
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = "\n".join(self.calls_since(m))
        self.assertIn("launchctl bootstrap", calls)
        self.assertNotIn("kickstart", calls)


class LinuxInstaller(Sandbox):
    OS = "Linux"

    def test_reinstall_keeps_settings(self):
        self.check_reinstall()
        self.assertIn("systemctl --user restart", self.calls.read_text())

    def test_first_install_reloads_and_restarts(self):
        r = self.run_install(**SETTINGS)
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = "\n".join(self.calls_since(0))
        self.assertIn("systemctl --user daemon-reload", calls)
        self.assertIn("systemctl --user restart", calls)

    def test_unchanged_reinstall_skips_reload_but_restarts(self):
        self.assertEqual(self.run_install(**SETTINGS).returncode, 0)
        before = self.unit.read_bytes()
        m = self.mark()
        r = self.run_install()
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = "\n".join(self.calls_since(m))
        self.assertNotIn("daemon-reload", calls)
        self.assertIn("systemctl --user restart", calls)
        self.assertEqual(self.unit.read_bytes(), before)

    def test_changed_setting_reloads_and_restarts(self):
        self.assertEqual(self.run_install(**SETTINGS).returncode, 0)
        m = self.mark()
        r = self.run_install(HERMES_MOBILE_MEDIA_MAX_BYTES="8192")
        self.assertEqual(r.returncode, 0, r.stderr)
        calls = "\n".join(self.calls_since(m))
        self.assertIn("daemon-reload", calls)
        self.assertIn("systemctl --user restart", calls)

    def test_control_character_rejected(self):
        r = self.run_install(HERMES_MOBILE_OWNER_LOGIN="a\nb")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("HERMES_MOBILE_OWNER_LOGIN", r.stderr)
        self.assertFalse(self.unit.exists())


if __name__ == "__main__":
    unittest.main()
