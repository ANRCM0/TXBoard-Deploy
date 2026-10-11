#!/usr/bin/env python3
"""Fail-closed conversion planner for an XBoard dump restored to a disposable TXBoard database."""
import argparse
import gzip
import json
import re
import sys
from pathlib import Path

IDENT = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
MIGRATION = re.compile(r"^[0-9]{4}_[0-9]{2}_[0-9]{2}_(?:[0-9]{6}_)?[a-z0-9_]+$")
ALLOWED = {"migrations", "failed_jobs", "personal_access_tokens", "password_reset_tokens",
           "password_resets", "jobs", "job_batches", "cache", "cache_locks", "sessions"}
# Old XBoard access-audit plugin tables are NOT equivalent to TXBoard's native
# tx_access_audit_* schema. Dropping them from an isolated import is opt-in.
LEGACY_AUDIT_TABLES = {
    "audit_access_logs", "audit_ban_logs", "audit_hourly_stats",
    "audit_node_status", "audit_reports", "audit_rules",
}
LEGACY_AUDIT_MIGRATIONS = {
    "2026_09_16_000001_create_access_audit_tables",
    "2026_09_16_000002_create_audit_node_status_table",
    "2026_09_16_000003_create_audit_access_logs_table",
    "2026_09_17_000004_add_audit_hot_path_indexes",
    "2026_09_17_000005_create_audit_analytics_tables",
}
# Already applied in the legacy source, but no longer shipped by TXBoard.
# Keep its history entry and effect; do not attempt to replay or synthesize it.
RETIRED_LEGACY_MIGRATIONS = {"2026_03_28_050000_lowercase_existing_emails"}
FORBIDDEN = re.compile(r"^\s*(?:USE\s+|(?:CREATE|DROP|ALTER)\s+(?:DATABASE|SCHEMA|USER)\b|"
                       r"GRANT\s+|REVOKE\s+|FLUSH\s+PRIVILEGES\b|SET\s+GLOBAL\b|SOURCE\s+|\\\.)", re.I)

def fail(message):
    raise ValueError(message)

def names(path, regex=IDENT):
    arr = [s.strip() for s in path.read_text(encoding="utf-8").splitlines() if s.strip()]
    if not arr or len(set(arr)) != len(arr) or any(not regex.fullmatch(s) for s in arr):
        fail(f"{path.name}: empty, duplicate, or invalid identifiers")
    return arr

def inspect_dump(path):
    if not path.is_file() or path.is_symlink() or path.suffix != ".gz" or path.stat().st_size == 0:
        fail("source must be a nonempty regular .sql.gz file, not a symlink")
    with gzip.open(path, "rt", encoding="utf-8", errors="replace") as stream:
        found = False
        for number, line in enumerate(stream, 1):
            line = line.lstrip("\ufeff")
            if line.lstrip().startswith(("--", "#")):
                continue
            if FORBIDDEN.search(line):
                fail(f"cross-database/privileged SQL near line {number}")
            if re.match(r"^\s*CREATE\s+TABLE\b", line, re.I):
                found = True
        if not found:
            fail("no CREATE TABLE statements were found")
    print("XBoard SQL dump passed offline preflight")

def make_plan(tables, history, native, discard_legacy_audit=False):
    if "migrations" not in tables or any(t.startswith("tx_") for t in tables):
        fail("missing migration ledger or mixed/native target schema")
    legacy = sorted(t for t in tables if t.startswith("v2_"))
    if not {"v2_user", "v2_settings", "v2_order", "v2_plan"}.issubset(legacy):
        fail("not a complete supported XBoard schema")
    audit_tables = sorted(set(tables) & LEGACY_AUDIT_TABLES)
    audit_history = sorted(set(history) & LEGACY_AUDIT_MIGRATIONS)
    if (audit_tables or audit_history) and not discard_legacy_audit:
        fail("legacy access-audit plugin data detected; explicit --discard-legacy-audit "
             "is required to drop it from the isolated destination")
    known_discard = LEGACY_AUDIT_TABLES if discard_legacy_audit else set()
    unknown = sorted(set(tables) - set(legacy) - ALLOWED - known_discard)
    if unknown:
        fail("unknown non-XBoard tables: " + ", ".join(unknown))
    native = set(native)
    mapped = {}
    retired = []
    for m in history:
        if m in RETIRED_LEGACY_MIGRATIONS:
            retired.append(m)
            continue
        if discard_legacy_audit and m in LEGACY_AUDIT_MIGRATIONS:
            continue
        dest = m if m in native else m.replace("v2_", "tx_").replace("legacy_servers", "reality_servers")
        if dest not in native:
            fail("unrecognized XBoard migration: " + m)
        mapped[m] = dest
    if len(set(mapped.values())) != len(mapped):
        fail("conflicting historical migration mappings")
    required = {"2023_03_19_000000_create_tx_tables", "2023_08_14_221234_create_tx_settings_table"}
    if not required.issubset(set(mapped.values())):
        fail("essential XBoard migration history missing")
    return {
        "schemaVersion": 1, "kind": "isolated-xboard-import",
        "sourceTableCount": len(tables), "sourceMigrationCount": len(history),
        "discardedLegacyAuditTables": audit_tables,
        "discardedLegacyAuditMigrations": audit_history,
        "retainedRetiredMigrationHistory": retired,
        "tableRenames": [{"from": t, "to": "tx_" + t[3:]} for t in legacy],
        "migrationRenames": [{"from": m, "to": d} for m, d in mapped.items() if m != d],
        "warnings": [
            "Only the isolated disposable import target may be modified; never use the source XBoard database.",
            "Retain the original XBoard backup and APP_KEY for recovery.",
            "External plugins, media and node agents require independent acceptance.",
            "A production cutover needs a fresh, consistent dump after freezing all XBoard writers.",
        ],
    }

def quoted_identifier(name):
    if not IDENT.fullmatch(name):
        fail("unsafe SQL identifier")
    return chr(96) + name + chr(96)

def quoted_migration(name):
    if not MIGRATION.fullmatch(name):
        fail("unsafe migration name")
    return "'" + name + "'"

def sql(plan):
    renames = plan["tableRenames"]
    lines = ["-- Only for isolated XBoard imports", "SET SESSION lock_wait_timeout=10;"]
    # The exact old plugin tables/ledger entries are disposable ONLY in the
    # freshly restored target. Fail if MySQL cannot drop them safely.
    audit_tables = plan.get("discardedLegacyAuditTables", [])
    if audit_tables:
        if any(t not in LEGACY_AUDIT_TABLES for t in audit_tables):
            fail("unsafe legacy audit table removal requested")
        lines.append("DROP TABLE " + ", ".join(quoted_identifier(t) for t in audit_tables) + ";")
    audit_history = plan.get("discardedLegacyAuditMigrations", [])
    if audit_history:
        if any(m not in LEGACY_AUDIT_MIGRATIONS for m in audit_history):
            fail("unsafe legacy audit migration removal requested")
        lines.append("DELETE FROM migrations WHERE migration IN (" +
                     ", ".join(quoted_migration(m) for m in audit_history) + ");")
    lines.append("RENAME TABLE " + ",\n  ".join(
        f"{quoted_identifier(r['from'])} TO {quoted_identifier(r['to'])}" for r in renames
    ) + ";")
    changes = plan["migrationRenames"]
    if changes:
        whens = " ".join(f"WHEN {quoted_migration(r['from'])} THEN {quoted_migration(r['to'])}" for r in changes)
        items = ", ".join(quoted_migration(r["from"]) for r in changes)
        lines.append("UPDATE migrations SET migration = CASE migration " + whens
                     + " ELSE migration END WHERE migration IN (" + items + ");")
    return "\n".join(lines) + "\n"

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ("tables", "history", "native", "plan", "sql", "check-dump"):
        parser.add_argument("--" + arg, type=Path)
    parser.add_argument("--discard-legacy-audit", action="store_true",
                        help="Drop exact allowlisted old audit plugin tables and history in isolated target")
    a = parser.parse_args()
    try:
        if a.check_dump:
            inspect_dump(a.check_dump)
        else:
            if not all((a.tables, a.history, a.native, a.plan, a.sql)):
                parser.error("--tables, --history, --native, --plan, --sql required")
            plan = make_plan(names(a.tables), names(a.history, MIGRATION), names(a.native, MIGRATION),
                             discard_legacy_audit=a.discard_legacy_audit)
            a.plan.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            a.sql.write_text(sql(plan), encoding="utf-8")
            a.plan.chmod(0o600)
            a.sql.chmod(0o600)
            print(f"Review plan: {len(plan['tableRenames'])} tables, {len(plan['migrationRenames'])} ledger entries; "
                  f"discard audit tables={len(plan['discardedLegacyAuditTables'])}, "
                  f"audit migration rows={len(plan['discardedLegacyAuditMigrations'])}, "
                  f"retired retained={len(plan['retainedRetiredMigrationHistory'])}")
        return 0
    except (OSError, EOFError, ValueError, UnicodeError) as error:
        print("XBoard import refused: " + str(error), file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
