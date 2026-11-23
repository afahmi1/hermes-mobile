import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Status"))
from hermes_status_server import parse_auth_list


class ProviderTests(unittest.TestCase):
    def test_platform_report_from_previous_process_is_not_a_live_incident(self):
        from hermes_status_server import prior_platform_observation
        lifecycle = {"pid": 3, "phase": "running", "started_at": "2026-11-23T12:00:00+00:00"}
        stale = {"updated_at": "2026-04-28T12:00:00+00:00", "state": "retrying"}
        fresh = dict(stale, updated_at="2026-11-23T12:01:00+00:00")
        self.assertTrue(prior_platform_observation(stale, lifecycle, 3))
        self.assertFalse(prior_platform_observation(fresh, lifecycle, 3))
        self.assertFalse(prior_platform_observation(stale, lifecycle, 4))
        self.assertFalse(prior_platform_observation({}, lifecycle, 3))

    def test_labels_with_spaces_count_towards_the_pool(self):
        rows = ["openrouter (12 credentials):"]
        for i in range(12):
            rows.append(f"  #{i} Integration key {i} api_key id=fixture{i} priority={i}")
        self.assertEqual(len(parse_auth_list("\n".join(rows))["openrouter"]["credentials"]), 12)

    def test_ledger_aggregates_by_provider_and_skips_old_schemas(self):
        import sqlite3
        import tempfile
        from contextlib import closing
        from hermes_status_server import provider_ledger
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            old = root / "old"
            old.mkdir()
            (old / "state.db").touch()
            with closing(sqlite3.connect(root / "state.db")) as db, db:
                db.execute("CREATE TABLE session_model_usage(session_id,billing_provider,api_call_count,"
                           "input_tokens,output_tokens,last_seen)")
                db.executemany("INSERT INTO session_model_usage VALUES(?,?,?,?,?,?)",
                               [("1","test",1,50,4,10),("1","test",2,70,8,15),("2","",3,10,1,14)])
            data, scope = provider_ledger([("first",root),("alias",root),("old",old)])
            self.assertEqual(data["test"], dict(sessions=1,calls=3,input_tokens=120,output_tokens=12,last_seen=15))
            self.assertEqual(data["unattributed"]["calls"], 3)
            self.assertEqual(scope, dict(profiles_read=1, profiles_unavailable=1))

    def test_openrouter_deduplicates_and_labels_partial_readings(self):
        from unittest.mock import patch
        import hermes_status_server as server

        def check(url, key, **kwargs):
            if url.endswith("credits"):
                return {"data": {"total_credits": 10, "total_usage": 4}}
            if key == "unavailable":
                raise OSError()
            return {"data": {"usage_daily": 0, "usage_monthly": 2.5}}

        pool = {"credential_pool": {"openrouter": [{"access_token": s} for s in ["configured","unavailable"]]}}
        with patch.object(server, "env_value", return_value="configured"), patch.object(server, "read_json", return_value=pool), patch.object(server, "http_json", side_effect=check):
            data = server.openrouter_usage()
        self.assertEqual((data["keys_reporting"],data["key_count"]), (1,2))
        self.assertEqual(data["spend"]["usage_daily"], dict(usd=0,reporting=1))
        self.assertEqual(data["balance"]["remaining"], 6)
        self.assertNotIn("configured", str(data))

    def test_primary_provider_wins_over_nested_fallback(self):
        import tempfile
        from hermes_status_server import _model_default
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "config.yaml"
            p.write_text("model:\n  default: fast\n  fallbacks:\n    - provider: alternate\n  provider: primary\n")
            self.assertEqual(_model_default(p), ("fast","primary"))
