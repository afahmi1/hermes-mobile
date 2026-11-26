"""--doctor's gateway check: a process that doesn't answer /health is not a running gateway."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "Bridge"))
import bridge_doctor  # noqa: E402


class DoctorGatewayTest(unittest.TestCase):
    def test_no_gateway_is_a_failure(self):
        status, detail, fix = bridge_doctor.gateway_check(False, 8642, probe=lambda p: True)
        self.assertEqual(status, bridge_doctor.FAIL)
        self.assertIn("No running", detail)
        self.assertIn("hermes gateway run", fix)

    def test_answering_gateway_is_ok(self):
        seen = []
        status, detail, fix = bridge_doctor.gateway_check(True, 8642, probe=lambda p: seen.append(p) or True)
        self.assertEqual((status, fix, seen), (bridge_doctor.OK, "", [8642]))

    def test_process_without_health_is_a_failure(self):
        # Seen after a Hermes update: the gateway process existed for five minutes before it listened,
        # the phone got 502s, and the doctor said "running".
        status, detail, fix = bridge_doctor.gateway_check(True, 8642, probe=lambda p: False)
        self.assertEqual(status, bridge_doctor.FAIL)
        self.assertIn("doesn't answer", detail)
        self.assertIn("starting", fix)

    def test_refused_connection_is_a_failure_not_a_crash(self):
        def refuse(p):
            raise ConnectionRefusedError()
        self.assertEqual(bridge_doctor.gateway_check(True, 8642, probe=refuse)[0], bridge_doctor.FAIL)

    def test_real_probe_against_a_closed_port(self):
        self.assertEqual(bridge_doctor.gateway_check(True, 1)[0], bridge_doctor.FAIL)


if __name__ == "__main__":
    unittest.main()
