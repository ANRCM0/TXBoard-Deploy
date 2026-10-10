#!/usr/bin/env python3
"""Fail-closed conversion planner for an XBoard dump restored to a disposable TXBoard database."""
import argparse
import gzip
import json
import re
import sys
from pathlib import Path

IDENT = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")
MIGRATION = re.compile(r"^[0-9]{4}_[0-9]{2}_[0-9]{2}_[0-9]{6}_[a-z0-9_]+$")
ALLOWED = {"migrations", "failed_jobs", "personal_access_tokens", "password_reset_tokens",
           "password_resets", "jobs", "job_batches", "cache", "cache_locks", "sessions"}
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

def make_plan(tables, history, native):
    if "migrations" not in tables or any(t.startswith("tx_") for t in tables):
        fail("missing migration ledger or mixed/native target schema")
    legacy = sorted(t for t in tables if t.startswith("v2_"))
    if not {"v2_user", "v2_settings", "v2_order", "v2_plan"}.issubset(legacy):
        fail("not a complete supported XBoard schema")
    unknown = sorted(set(tables) - set(legacy) - ALLOWED)
    if unknown:
        fail("unknown non-XBoard tables: " + ", ".join(unknown))
    native = set(native)
    mapped = {}
    for m in history:
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
    lines = ["-- Only for isolated XBoard imports", "SET SESSION lock_wait_timeout=10;",
             "RENAME TABLE " + ",\n  ".join(
                 f"{quoted_identifier(r['from'])} TO {quoted_identifier(r['to'])}" for r in renames
             ) + ";"]
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
    a = parser.parse_args()
    try:
        if a.check_dump:
            inspect_dump(a.check_dump)
        else:
            if not all((a.tables, a.history, a.native, a.plan, a.sql)):
                parser.error("--tables, --history, --native, --plan, --sql required")
            plan = make_plan(names(a.tables), names(a.history, MIGRATION), names(a.native, MIGRATION))
            a.plan.write_text(json.dumps(plan, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            a.sql.write_text(sql(plan), encoding="utf-8")
            a.plan.chmod(0o600)
            a.sql.chmod(0o600)
            print(f"Review plan: {len(plan['tableRenames'])} tables, {len(plan['migrationRenames'])} ledger entries")
        return 0
    except (OSError, EOFError, ValueError, UnicodeError) as error:
        print("XBoard import refused: " + str(error), file=sys.stderr)
        return 1

if __name__ == "__main__":
    sys.exit(main())
