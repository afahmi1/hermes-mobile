"""--doctor reports APNs push precisely (configured, key unreadable or invalid, IDs missing or malformed, a test
server, the phones registered and APNs's last answer), from the shell or the installed service, never the values.
--push-test sends one test notification to every registered phone and reports each answer."""
import io
import json
import os
import plistlib
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Bridge"))
import bridge_devices  # noqa: E402
import bridge_doctor  # noqa: E402

SECRET_ID = "KEYID12345"
SECRET_TEAM = "TEAM987654"
TOKEN = "ab" * 32


def make_key(path):
    """A throwaway P-256 key in the .p8 (PKCS#8 PEM) form Apple hands out."""
    ec = subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout"], check=True, capture_output=True)
    p8 = subprocess.run(["openssl", "pkcs8", "-topk8", "-nocrypt"], input=ec.stdout, check=True, capture_output=True)
    path.write_bytes(p8.stdout)
    path.chmod(0o600)


@unittest.skipUnless(shutil.which("openssl"), "openssl needed to make a throwaway key")
class DoctorPushTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.key = self.root / "AuthKey.p8"
        make_key(self.key)

    def tearDown(self):
        self.tmp.cleanup()

    def full(self):
        return {"HERMES_MOBILE_APNS_KEY_PATH": str(self.key), "HERMES_MOBILE_APNS_KEY_ID": SECRET_ID,
                "HERMES_MOBILE_APNS_TEAM_ID": SECRET_TEAM}

    def assert_no_values(self, result):
        text = " ".join(result) if isinstance(result, (tuple, list)) else result
        for value in (SECRET_ID, SECRET_TEAM, str(self.key), TOKEN):
            self.assertNotIn(value, text)

    def test_not_configured_is_a_warning(self):
        result = bridge_doctor.push_check(env={}, service={})
        self.assertEqual(result[0], bridge_doctor.WARN)
        self.assertIn("not configured", result[1])

    def test_configured_from_shell(self):
        result = bridge_doctor.push_check(env=self.full(), service={})
        self.assertEqual(result[0], bridge_doctor.OK, result)
        self.assert_no_values(result)

    def test_configured_from_installed_service(self):
        result = bridge_doctor.push_check(env={}, service=self.full())
        self.assertEqual(result[0], bridge_doctor.OK, result)
        self.assert_no_values(result)

    def test_partial_or_missing_key_fails_without_values(self):
        partial = self.full()
        del partial["HERMES_MOBILE_APNS_TEAM_ID"]
        result = bridge_doctor.push_check(env=partial, service={})
        self.assertEqual(result[0], bridge_doctor.FAIL)
        self.assertIn("HERMES_MOBILE_APNS_TEAM_ID", result[1])
        self.assert_no_values(result)
        gone = self.full()
        self.key.unlink()
        result = bridge_doctor.push_check(env=gone, service={})
        self.assertEqual(result[0], bridge_doctor.FAIL)
        self.assert_no_values(result)

    def test_a_file_that_is_not_an_apns_key_fails(self):
        self.key.write_text("not a real key")
        result = bridge_doctor.push_check(env=self.full(), service={})
        self.assertEqual(result[0], bridge_doctor.FAIL)
        self.assertIn(".p8", result[1])
        self.assert_no_values(result)

    @unittest.skipIf(os.name != "posix" or os.geteuid() == 0, "needs file permissions that bind")
    def test_unreadable_key_fails(self):
        self.key.chmod(0o000)
        try:
            result = bridge_doctor.push_check(env=self.full(), service={})
        finally:
            self.key.chmod(0o600)
        self.assertEqual(result[0], bridge_doctor.FAIL)
        self.assertIn("can't read", result[1])
        self.assert_no_values(result)

    def test_malformed_key_id_or_team_id_fails_by_name(self):
        env = {**self.full(), "HERMES_MOBILE_APNS_KEY_ID": "abc"}
        result = bridge_doctor.push_check(env=env, service={})
        self.assertEqual(result[0], bridge_doctor.FAIL)
        self.assertIn("HERMES_MOBILE_APNS_KEY_ID", result[1])
        self.assertNotIn("TEAM_ID", result[1])
        self.assert_no_values(result)

    def test_key_others_can_read_and_a_test_server_warn(self):
        self.key.chmod(0o644)
        self.assertEqual(bridge_doctor.push_check(env=self.full(), service={})[0], bridge_doctor.WARN)
        self.key.chmod(0o600)
        result = bridge_doctor.push_check(env={**self.full(), "HERMES_MOBILE_APNS_HOST": "https://localhost:1"}, service={})
        self.assertEqual(result[0], bridge_doctor.WARN)
        self.assertIn("test server", result[1])

    def test_reads_launch_agent_and_systemd_unit(self):
        agents = self.root / "Library" / "LaunchAgents"
        agents.mkdir(parents=True)
        with (agents / "local.abduel.hermes-mobile.plist").open("wb") as f:
            plistlib.dump({"EnvironmentVariables": self.full()}, f)
        self.assertEqual(bridge_doctor._service_env(self.root)["HERMES_MOBILE_APNS_KEY_ID"], SECRET_ID)
        units = self.root / ".config" / "systemd" / "user"
        units.mkdir(parents=True)
        (units / "hermes-mobile-bridge.service").write_text(
            "[Service]\nEnvironment=HERMES_MOBILE_APNS_TEAM_ID=%s\n" % SECRET_TEAM)
        self.assertEqual(bridge_doctor._service_env(self.root)["HERMES_MOBILE_APNS_TEAM_ID"], SECRET_TEAM)

    def test_last_apns_answer_is_reported_with_its_fix(self):
        state = self.root / "state"
        self.assertIsNone(bridge_doctor.push_last_check(state))  # nothing sent yet: no line
        (state / "push").mkdir(parents=True)
        status = state / "push" / "status.json"
        error = {"at": int(time.time()), "event": "run.completed", "env": "production", "status": 403,
                 "reason": "InvalidProviderToken"}
        status.write_text(json.dumps({"last": error, "last_error": error}))
        result = bridge_doctor.push_last_check(state)
        self.assertEqual(result[0], bridge_doctor.FAIL)
        self.assertIn("HERMES_MOBILE_APNS_KEY_ID", result[2])
        status.write_text(json.dumps({"last": {**error, "reason": "DeviceTokenNotForTopic", "status": 400}}))
        self.assertIn("HERMES_MOBILE_APNS_TOPIC", bridge_doctor.push_last_check(state)[2])
        status.write_text(json.dumps({"last": {**error, "status": 200, "reason": ""}, "last_error": error}))
        result = bridge_doctor.push_last_check(state)
        self.assertEqual(result[0], bridge_doctor.OK)
        self.assertIn("Earlier error", result[1])

    def test_registered_phones_are_counted_read_only(self):
        state = self.root / "state"
        self.assertIsNone(bridge_doctor.push_phones_check(state, True))
        devices = bridge_devices.Devices(state / "devices")
        devices.issue({"did": "d1", "dev": "Phone", "issued": 0, "exp": int(time.time()) + 3600, "method": "local"})
        result = bridge_doctor.push_phones_check(state, True)
        self.assertEqual((bridge_doctor.WARN, "No phone has registered for push yet."), result[:2])
        devices.set_push_token("d1", TOKEN, "production", "acct", "com.phone.app")
        db = state / "devices" / "devices.sqlite3"
        before = db.read_bytes()
        result = bridge_doctor.push_phones_check(state, True)
        self.assertEqual(bridge_doctor.OK, result[0])
        self.assertIn("1 phone(s) registered for push (production 1)", result[1])
        self.assertEqual(before, db.read_bytes())
        self.assert_no_values(result)


@unittest.skipUnless(shutil.which("openssl"), "openssl needed to make a throwaway key")
class PushTestCommand(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.key = self.root / "AuthKey.p8"
        make_key(self.key)
        self.env = {"HERMES_MOBILE_APNS_KEY_PATH": str(self.key), "HERMES_MOBILE_APNS_KEY_ID": SECRET_ID,
                    "HERMES_MOBILE_APNS_TEAM_ID": SECRET_TEAM}
        self.devices = bridge_devices.Devices(self.root / "devices")
        self.devices.issue({"did": "d1", "dev": "Abduel's iPhone", "issued": 0, "exp": int(time.time()) + 3600,
                            "method": "local"})
        self.devices.set_push_token("d1", TOKEN, "production", "acct", "com.phone.app")
        self.sent = []
        self.answer = (200, "")

    def send(self, url, headers, body):
        self.sent.append((url, headers, json.loads(body)))
        return self.answer

    def run_test(self, env=None):
        out = io.StringIO()
        with redirect_stdout(out):
            code = bridge_doctor.push_test(self.devices, self.root / "push" / "status.json", env=env or self.env,
                                           service={}, send=self.send)
        return code, out.getvalue()

    def test_delivers_to_every_registered_phone_and_names_it(self):
        code, out = self.run_test()
        self.assertEqual(0, code, out)
        self.assertIn("Abduel's iPhone (production): delivered", out)
        url, headers, body = self.sent[0]
        self.assertEqual("https://api.push.apple.com/3/device/" + TOKEN, url)
        self.assertEqual("com.phone.app", headers["apns-topic"])
        self.assertEqual({"aps"}, set(body))
        for value in (SECRET_ID, SECRET_TEAM, str(self.key), TOKEN):
            self.assertNotIn(value, out)
        self.assertEqual(200, json.loads((self.root / "push" / "status.json").read_text())["last"]["status"])

    def test_dead_token_is_reported_and_removed(self):
        self.answer = (410, "Unregistered")
        code, out = self.run_test()
        self.assertEqual(1, code)
        self.assertIn("APNs 410 Unregistered (token removed)", out)
        self.assertEqual([], self.devices.push_targets())

    def test_unconfigured_or_no_phone_says_what_to_do(self):
        code, out = self.run_test(env={"HERMES_MOBILE_APNS_KEY_ID": SECRET_ID})
        self.assertEqual(1, code)
        self.assertIn("half configured", out)
        self.assertEqual([], self.sent)
        self.devices.clear_push_token("d1")
        code, out = self.run_test()
        self.assertEqual(1, code)
        self.assertIn("No phone has registered", out)


if __name__ == "__main__":
    unittest.main()
