import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Status"))
from hermes_status_server import parse_auth_list


class ProviderTests(unittest.TestCase):
    def test_labels_with_spaces_count_towards_the_pool(self):
        rows = ["openrouter (12 credentials):"]
        for i in range(12):
            rows.append(f"  #{i} Integration key {i} api_key id=fixture{i} priority={i}")
        self.assertEqual(len(parse_auth_list("\n".join(rows))["openrouter"]["credentials"]), 12)
