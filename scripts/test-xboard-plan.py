#!/usr/bin/env python3
"""Unit tests for the offline source guard and source->native schema plan."""
import gzip
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("xboard_plan", ROOT / "scripts/xboard-plan.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

TABLES = ["migrations", "failed_jobs", "v2_user", "v2_settings", "v2_order", "v2_plan"]
HISTORY = [
    "2023_03_19_000000_create_v2_tables",
    "2023_08_14_221234_create_v2_settings_table",
    "2025_01_04_optimize_plan_table",
    "2025_01_05_131425_create_v2_server_table",
    "2026_04_19_235904_backfill_utls_for_legacy_servers",
]
NATIVE = [
    "2023_03_19_000000_create_tx_tables",
    "2023_08_14_221234_create_tx_settings_table",
    "2025_01_04_optimize_plan_table",
    "2025_01_05_131425_create_tx_server_table",
    "2026_04_19_235904_backfill_utls_for_reality_servers",
]

class TestXBoardImport(unittest.TestCase):
    def test_complete_mapping_and_historical_filename(self):
        with tempfile.TemporaryDirectory() as dirname:
            folder = Path(dirname)
            for name, values in (("tables", TABLES), ("history", HISTORY), ("native", NATIVE)):
                (folder / name).write_text("\n".join(values) + "\n")
            self.assertEqual(m.names(folder / "history", m.MIGRATION), HISTORY)
        plan = m.make_plan(TABLES, HISTORY, NATIVE)
        self.assertEqual(len(plan["tableRenames"]), 4)
        self.assertEqual(len(plan["migrationRenames"]), 4)
        stmts = m.sql(plan)
        self.assertIn("RENAME TABLE", stmts)
        self.assertIn("v2_user", stmts)
        self.assertIn("create_tx_tables", stmts)
        self.assertNotIn("WHEN '2025_01_04_optimize_plan_table'", stmts)

    def test_unknown_version_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "unrecognized"):
            m.make_plan(TABLES, HISTORY + ["2099_01_01_custom"], NATIVE)

    def test_mixed_schema_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "mixed/native"):
            m.make_plan(TABLES + ["tx_user"], HISTORY, NATIVE)

    def test_custom_tables_cannot_be_silently_discarded(self):
        with self.assertRaisesRegex(ValueError, "unknown non-XBoard"):
            m.make_plan(TABLES + ["secret_plugin_accounts"], HISTORY, NATIVE)

    def test_history_collisions_rejected(self):
        history = HISTORY + ["2023_03_19_000000_create_tx_tables"]
        with self.assertRaisesRegex(ValueError, "conflicting"):
            m.make_plan(TABLES, history, NATIVE)

    def test_dump_scan_blocks_cross_db_statements(self):
        with tempfile.TemporaryDirectory() as dirname:
            bad = Path(dirname) / "bad.sql.gz"
            with gzip.open(bad, "wt") as f:
                f.write("CREATE TABLE v2_user (id int);\nUSE production;\n")
            with self.assertRaisesRegex(ValueError, "cross-database"):
                m.inspect_dump(bad)
            good = Path(dirname) / "good.sql.gz"
            with gzip.open(good, "wt") as f:
                f.write("-- MySQL dump\nCREATE TABLE v2_user (id int);\n")
            m.inspect_dump(good)

if __name__ == "__main__":
    unittest.main()
