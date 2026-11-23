"""Owner PIN verifier, shared persisted limiter and owner epoch (bridge_owner). Synthetic PIN only."""
import json
import os
import stat
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_owner as bo  # noqa: E402

PIN, WRONG = "5807", "1111"


class Clock:
    def __init__(self):
        self.now = 1_000_000.0

    def time(self):
        return self.now


class OwnerPinTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(self.enterContext(tempfile.TemporaryDirectory(prefix="pin-"))).resolve() / "state"
        self.clock = Clock()
        self.enterContext(patch.object(bo, "time", self.clock))

    def refuse(self, pin, code):
        with self.assertRaises(bo.OwnerError) as cm:
            bo.check_pin(self.dir, pin)
        self.assertEqual(cm.exception.code, code)
        return cm.exception

    def test_set_and_verify_and_file_shape(self):
        bo.set_pin(self.dir, PIN)
        self.assertIsNone(bo.check_pin(self.dir, PIN))
        f = self.dir / "owner_pin.json"
        self.assertEqual(stat.S_IMODE(f.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(self.dir.stat().st_mode), 0o700)
        doc = json.loads(f.read_text())
        self.assertEqual((doc["v"], doc["kdf"], doc["n"], doc["r"], doc["p"]), (1, "scrypt", 32768, 8, 1))
        self.assertNotIn(PIN, f.read_text())
        for p in self.dir.iterdir():
            self.assertNotIn(PIN.encode(), p.read_bytes())
        self.assertEqual([p.name for p in self.dir.iterdir() if p.name.endswith(".tmp")], [])

    def test_only_four_ascii_digits(self):
        for bad in ("123", "12345", "12a4", "١٢٣٤", "", " 123", None, 1234):
            with self.assertRaises(ValueError):
                bo.set_pin(self.dir, bad)
        bo.set_pin(self.dir, PIN)
        for bad in ("580", "58077", "58O7", "٥٨٠٧", 5807):
            self.refuse(bad, "pin_wrong")
            self.assertIsNone(bo.check_pin(self.dir, PIN))  # success resets the counter

    def test_wrong_pin_and_missing_pin(self):
        bo.set_pin(self.dir, PIN)
        self.refuse(WRONG, "pin_wrong")
        self.refuse(None, "pin_required")  # not counted as an attempt
        self.assertEqual(json.loads((self.dir / "owner_pin_attempts.json").read_text())["fails"], 1)

    def test_five_failures_lock_and_double_to_one_hour(self):
        bo.set_pin(self.dir, PIN)
        for _ in range(4):
            self.refuse(WRONG, "pin_wrong")
        e = self.refuse(WRONG, "pin_locked")
        self.assertEqual(e.status, 429)
        self.assertTrue(0 < e.retry_after <= 301)
        # Even the right PIN is refused while locked.
        self.refuse(PIN, "pin_locked")
        spans = []
        for _ in range(6):
            self.clock.now = json.loads((self.dir / "owner_pin_attempts.json").read_text())["until"] + 1
            for _ in range(4):
                self.refuse(WRONG, "pin_wrong")
            e = self.refuse(WRONG, "pin_locked")
            spans.append(e.retry_after)
        self.assertEqual(spans[0] // 100, 6)  # 600 s
        self.assertEqual(spans[1] // 100, 12)  # 1200 s
        self.assertTrue(all(s <= 3601 for s in spans))
        self.assertIn(spans[-1], (3600, 3601))

    def test_lock_persists_across_restart_and_success_resets(self):
        bo.set_pin(self.dir, PIN)
        for _ in range(5):
            with self.assertRaises(bo.OwnerError):
                bo.check_pin(self.dir, WRONG)
        # A restart keeps no in-memory state; the module must read the persisted counter from disk.
        with self.assertRaises(bo.OwnerError) as cm:
            bo.check_pin(self.dir, PIN)
        self.assertEqual(cm.exception.code, "pin_locked")
        self.clock.now += 301
        self.assertIsNone(bo.check_pin(self.dir, PIN))
        self.assertEqual(json.loads((self.dir / "owner_pin_attempts.json").read_text())["level"], 0)

    def test_fail_closed_verifier(self):
        self.refuse(PIN, "pin_unset")  # nothing set
        bo.set_pin(self.dir, PIN)
        f = self.dir / "owner_pin.json"
        os.chmod(f, 0o644)
        self.refuse(PIN, "pin_unset")
        os.chmod(f, 0o600)
        self.assertIsNone(bo.check_pin(self.dir, PIN))
        f.write_text("not json")
        os.chmod(f, 0o600)
        self.refuse(PIN, "pin_unset")
        bo.set_pin(self.dir, PIN)
        os.chmod(self.dir, 0o755)  # loose directory
        self.refuse(PIN, "pin_unset")
        os.chmod(self.dir, 0o700)
        real = self.dir / "real.json"
        f.rename(real)
        os.symlink(real, f)  # symlinked verifier
        self.refuse(PIN, "pin_unset")
        f.unlink()
        os.link(real, f)  # hardlinked verifier
        self.refuse(PIN, "pin_unset")

    def test_set_pin_refuses_symlinked_target(self):
        bo.set_pin(self.dir, PIN)
        f = self.dir / "owner_pin.json"
        victim = self.dir / "victim"
        victim.write_text("keep")
        f.unlink()
        os.symlink(victim, f)
        with self.assertRaises(bo.OwnerError):
            bo.set_pin(self.dir, PIN)
        self.assertEqual(victim.read_text(), "keep")

    def test_tampered_counter_locks_instead_of_resetting(self):
        bo.set_pin(self.dir, PIN)
        (self.dir / "owner_pin_attempts.json").write_text("garbage")
        os.chmod(self.dir / "owner_pin_attempts.json", 0o600)
        self.refuse(PIN, "pin_locked")

    def test_epoch_and_claims(self):
        e = bo.epoch(self.dir)
        self.assertEqual(stat.S_IMODE((self.dir / "owner_epoch").stat().st_mode), 0o600)
        self.assertTrue(bo.claims_are_owner({"own": 1, "iat": int(e)}, self.dir))
        self.assertFalse(bo.claims_are_owner({"own": 1, "iat": int(e) - 1}, self.dir))
        for bad in ({}, {"iat": int(e)}, {"own": True, "iat": int(e)}, {"own": 2, "iat": int(e)},
                    {"own": 1, "iat": "9999999999"}, {"own": 1}, None):
            self.assertFalse(bo.claims_are_owner(bad, self.dir))
        new = bo.rotate_epoch(self.dir)
        self.assertGreater(new, e)
        self.assertFalse(bo.claims_are_owner({"own": 1, "iat": int(e)}, self.dir))
        self.assertTrue(bo.claims_are_owner({"own": 1, "iat": new}, self.dir))

    def test_clear_pin(self):
        bo.set_pin(self.dir, PIN)
        bo.clear_pin(self.dir)
        self.refuse(PIN, "pin_unset")


if __name__ == "__main__":
    unittest.main()
