"""Cost on chat list rows: classified like the chat header's ledger, never inventing a charge."""
import _isolation  # noqa: F401  (must precede any bridge import; see Tests/_isolation.py)
import sqlite3
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import hermes_mobile_bridge as b


class RowCostTests(unittest.TestCase):
    def test_a_subscription_estimate_is_included_not_a_charge(self):
        # The real shape on Zayd's Mac: a Claude subscription route with a $135 rate-card estimate.
        row = {"cost_status": "estimated", "estimated_cost_usd": 135.80195, "actual_cost_usd": None,
               "billing_provider": "claude-subscription-directsdk-experimental", "billing_mode": None}
        self.assertEqual(b.row_cost(row), {"usd": 0.0, "included": True, "unknown": False, "included_api_usd": 135.80195})

    def test_a_priced_route_shows_its_estimate(self):
        row = {"cost_status": "estimated", "estimated_cost_usd": 0.4213, "billing_provider": "openrouter"}
        self.assertEqual(b.row_cost(row)["usd"], 0.4213)
        self.assertFalse(b.row_cost(row)["included"])

    def test_provider_price_wins_over_the_rate_card(self):
        row = {"cost_status": "actual", "estimated_cost_usd": 2.0, "actual_cost_usd": 1.25, "billing_provider": "openrouter"}
        self.assertEqual(b.row_cost(row)["usd"], 1.25)

    def test_nothing_recorded_stays_blank(self):
        self.assertIsNone(b.row_cost({"id": "x"}))
        self.assertIsNone(b.row_cost({"cost_status": "unknown", "billing_provider": "custom-local"}))
        self.assertIsNone(b.row_cost({"cost_status": "estimated", "estimated_cost_usd": 0, "billing_provider": "openrouter"}))

    def test_garbage_is_not_money(self):
        row = {"cost_status": "estimated", "estimated_cost_usd": True, "actual_cost_usd": float("nan"),
               "billing_provider": "openrouter"}
        self.assertIsNone(b.row_cost(row))

    def test_sql_rows_carry_cost_and_drop_the_raw_columns(self):
        con = sqlite3.connect(":memory:")
        con.row_factory = sqlite3.Row
        con.execute("CREATE TABLE sessions (id, source, model, title, started_at, ended_at, message_count, archived, "
                    "last_activity_at, parent_session_id, pinned, estimated_cost_usd, actual_cost_usd, cost_status, "
                    "billing_provider, billing_mode)")
        con.execute("INSERT INTO sessions VALUES ('s','local','m','t',1,NULL,2,0,2,NULL,0,0.5,NULL,'estimated','openrouter',NULL)")
        row = con.execute("SELECT %s FROM sessions" % b._session_cols(con)).fetchone()
        out = b._session_flags(row)
        self.assertEqual(out["cost"]["usd"], 0.5)
        self.assertFalse(any(key in out for key in b._COST_COLS))

    def test_older_databases_without_cost_columns_still_list(self):
        con = sqlite3.connect(":memory:")
        con.row_factory = sqlite3.Row
        con.execute("CREATE TABLE sessions (id, source, model, title, started_at, ended_at, message_count, archived, "
                    "last_activity_at, parent_session_id)")
        con.execute("INSERT INTO sessions VALUES ('s','local','m','t',1,NULL,2,0,2,NULL)")
        out = b._session_flags(con.execute("SELECT %s FROM sessions" % b._session_cols(con)).fetchone())
        self.assertNotIn("cost", out)


if __name__ == "__main__":
    unittest.main()
