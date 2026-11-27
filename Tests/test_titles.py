import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import subprocess
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import bridge_titles as t

CHAT = [("user", "first ask " + "x" * 400), ("assistant", "a1"), ("user", "second"),
        ("user", "third"), ("user", "fourth"), ("assistant", "latest answer")]


class DigestTests(unittest.TestCase):
    def test_opening_latest_asks_and_answer(self):
        d = t.digest(CHAT)
        self.assertTrue(d.startswith("Started with: first ask"))
        self.assertNotIn("x" * 301, d)
        self.assertEqual(d.count("Then:"), 3)
        self.assertIn("Latest answer: latest answer", d)

    def test_bounded_and_empty(self):
        self.assertLessEqual(len(t.digest([("user", "y" * 5000)] * 10)), 1400)
        self.assertEqual(t.digest([]), "")
        self.assertEqual(t.suggest(Path("/tmp"), []), "")


class SuggestTests(unittest.TestCase):
    def test_cleans_and_rejects_non_titles(self):
        for out, want in [('{"title": "  Fix   rename  "}', "Fix rename"), ('{"title": "$ df -h /"}', ""),
                          ("garbage", ""), ('{"title": null}', "")]:
            with patch.object(t.subprocess, "run", return_value=SimpleNamespace(stdout=out)):
                self.assertEqual(t.suggest(Path("/tmp"), CHAT), want, out)

    def test_timeout_is_no_suggestion(self):
        with patch.object(t.subprocess, "run", side_effect=subprocess.TimeoutExpired("x", 1)):
            self.assertEqual(t.suggest(Path("/tmp"), CHAT), "")


if __name__ == "__main__":
    unittest.main()
