"""--doctor reports whether APNs push is configured, from the shell or the installed service, never the values."""
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Bridge"))
import bridge_doctor  # noqa: E402

SECRET_ID = "KEYID12345"
SECRET_TEAM = "TEAM987654"


class DoctorPushTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.key = self.root / "AuthKey.p8"
        self.key.write_text("not a real key")

    def tearDown(self):
        self.tmp.cleanup()

    def full(self):
        return {"HERMES_MOBILE_APNS_KEY_PATH": str(self.key), "HERMES_MOBILE_APNS_KEY_ID": SECRET_ID,
                "HERMES_MOBILE_APNS_TEAM_ID": SECRET_TEAM}

    def assert_no_values(self, result):
        text = " ".join(result)
        for value in (SECRET_ID, SECRET_TEAM, str(self.key)):
            self.assertNotIn(value, text)

    def test_not_configured_is_a_warning(self):
        result = bridge_doctor.push_check(env={}, service={})
        self.assertEqual(result[0], bridge_doctor.WARN)
        self.assertIn("not configured", result[1])

    def test_configured_from_shell(self):
        result = bridge_doctor.push_check(env=self.full(), service={})
        self.assertEqual(result[0], bridge_doctor.OK)
        self.assert_no_values(result)

    def test_configured_from_installed_service(self):
        result = bridge_doctor.push_check(env={}, service=self.full())
        self.assertEqual(result[0], bridge_doctor.OK)
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


if __name__ == "__main__":
    unittest.main()
