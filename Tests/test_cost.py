"""Per-reply cost from Hermes's ledger: subscription routes are included, unknown routes are not $0."""
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import hermes_mobile_bridge as bridge


class CostTests(unittest.TestCase):
    def test_billing_kind(self):
        k = bridge.billing_kind
        self.assertEqual(k("claude-subscription-directsdk-experimental", est=277.0), "included")
        self.assertEqual(k("openai-codex", "subscription_included", "included"), "included")
        self.assertEqual(k("xai-oauth"), "included")
        self.assertEqual(k("openrouter", "", "estimated", est=1.2), "priced")
        self.assertEqual(k("deepseek", est=0.4), "priced")
        self.assertEqual(k("custom", "", "unknown"), "unknown")

    def _db(self, home, rows):
        con = sqlite3.connect(home / "state.db")
        con.execute("CREATE TABLE session_model_usage (session_id TEXT, model TEXT, billing_provider TEXT, "
                    "billing_base_url TEXT DEFAULT '', billing_mode TEXT, task TEXT DEFAULT '', api_call_count INT, "
                    "input_tokens INT, output_tokens INT, cache_read_tokens INT, cache_write_tokens INT DEFAULT 0, "
                    "reasoning_tokens INT DEFAULT 0, estimated_cost_usd REAL, actual_cost_usd REAL, cost_status TEXT, "
                    "cost_source TEXT, first_seen REAL, last_seen REAL)")
        con.executemany("INSERT INTO session_model_usage (session_id, model, billing_provider, billing_mode, api_call_count, "
                        "input_tokens, output_tokens, cache_read_tokens, estimated_cost_usd, actual_cost_usd, cost_status) "
                        "VALUES (?,?,?,?,?,?,?,?,?,?,?)", rows)
        con.commit(); con.close()

    def test_ledger_summary_and_turn_delta(self):
        with tempfile.TemporaryDirectory() as tmp:
            home = Path(tmp)
            self._db(home, [("chat", "opus", "claude-subscription-x", "", 4, 1000, 200, 0, 3.5, 0, "estimated"),
                            ("chat", "glm", "openrouter", "", 2, 500, 100, 0, 0.02, 0, "estimated"),
                            ("chat", "local", "custom", "", 1, 10, 10, 0, 0, 0, "unknown")])
            with patch.object(bridge, "profile_home", return_value=home):
                before = bridge.cost_ledger("default", "chat")
                total = bridge.cost_summary(before.values())
                self.assertAlmostEqual(total["usd"], 0.02)
                self.assertAlmostEqual(total["included_api_usd"], 3.5)
                self.assertTrue(total["included"] and total["unknown"])
                con = sqlite3.connect(home / "state.db")
                con.execute("UPDATE session_model_usage SET api_call_count=3, estimated_cost_usd=0.05 WHERE model='glm'")
                con.commit(); con.close()
                turn = bridge.cost_summary(bridge.cost_delta(before, bridge.cost_ledger("default", "chat")))
                self.assertAlmostEqual(turn["usd"], 0.03)
                self.assertFalse(turn["included"])


if __name__ == "__main__":
    unittest.main()
