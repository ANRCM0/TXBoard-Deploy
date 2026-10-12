#!/usr/bin/env python3
"""Opt-in real Docker/Core/SQL crash test on a fresh signed isolated shadow copy.

The fixture, backup and signed release must already exist. This intentionally kills
the executor after a committed Core backfill batch, then proves forward recovery.
No image/database rollback or fixture deletion is performed by this test.
"""
import argparse
import importlib.util
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("upgrade", Path(__file__).with_name("upgrade.py"))
upgrade = importlib.util.module_from_spec(spec)
spec.loader.exec_module(upgrade)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("dir", "manifest", "signature", "trust-dir", "backup", "backup-evidence", "deploy-bundle"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--fault-child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    upgrade.require(os.name == "posix", "real_docker_test_requires_linux")
    manifest, digest = upgrade.load_signed_manifest(args.manifest, args.signature, args.trust_dir)
    catalog = manifest["profile"] == upgrade.CATALOG_PROFILE
    backfill_step = "plan-catalog-shadow-backfill-v1" if catalog else "subscription-shadow-backfill-v1"
    cursor_field = "cursor_plan_id" if catalog else "cursor_user_id"
    backend = upgrade.DockerShadowBackend(args.dir, args.backup, args.backup_evidence, digest, manifest, args.deploy_bundle)
    if args.fault_child:
        def hook(event, step):
            if event == "after_side_effect" and step == backfill_step:
                print("committed-backfill-before-checkpoint-result", flush=True)
                time.sleep(60)
                raise AssertionError("controller did not kill executor")
        with upgrade.InstallLock(args.dir):
            journal = upgrade.Journal(args.dir)
            try:
                upgrade.Runner(journal, backend, manifest, digest, hook=hook).execute()
            finally:
                journal.close()
        raise AssertionError("fresh backfill batch was not executed")

    upgrade.require(not (args.dir / ".upgrade-in-progress").exists(), "real_fault_test_requires_fresh_copy")
    backend.check(manifest)
    command = [sys.executable, "-B", __file__, *sys.argv[1:], "--fault-child"]
    child = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        line = child.stdout.readline()
        upgrade.require(line.strip() == "committed-backfill-before-checkpoint-result", "fault_boundary_not_reached")
        child.kill()  # SIGKILL: no finally/exit trap can write the missing result.
        child.wait(timeout=10)
        upgrade.require(child.returncode != 0, "executor_was_not_killed")
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=10)
        child.stdout.close()
        child.stderr.close()
    journal = upgrade.Journal(args.dir, readonly=True)
    try:
        before = journal.report(manifest["release_id"])
        step = next(s for s in before["steps"] if s["step"] == backfill_step)
        upgrade.require(step["result"] is None, "missing_result_not_preserved")
        upgrade.require(before["status"] == "backfilling", "unexpected_interrupted_phase")
    finally:
        journal.close()
    durable = backend.probe(backfill_step)
    upgrade.require(durable["status"] in ("partial", "applied") and int(durable["checkpoint"][cursor_field]) > 0, "core_batch_not_durable")
    with upgrade.InstallLock(args.dir):
        journal = upgrade.Journal(args.dir)
        try:
            report = upgrade.Runner(journal, backend, manifest, digest).execute(recover=True)
        finally:
            journal.close()
    upgrade.require(report["status"] == "completed", "recovery_not_completed")
    upgrade.require((args.dir / ".upgrade-in-progress").is_file(), "binary_guard_not_retained")
    duplicate = backend.sql("SELECT COUNT(*) FROM (SELECT legacy_plan_id FROM tx_plan_catalog_shadow GROUP BY legacy_plan_id HAVING COUNT(*)>1) duplicate_maps" if catalog else
        "SELECT COUNT(*) FROM (SELECT legacy_user_id FROM tx_legacy_subscription_map GROUP BY legacy_user_id HAVING COUNT(*)>1) duplicate_maps")
    upgrade.require(duplicate == "0", "duplicate_legacy_mapping")
    print(json.dumps({"profile": manifest["profile"], "result": "passed", "fault": "SIGKILL after Core batch commit before journal result",
                      "core_cursor_after_kill": durable["checkpoint"][cursor_field], "manifest_sha256": digest,
                      "authority": "legacy", "duplicate_maps": "0", "binary_guard_retained": True, "target_digest": report["source"]["target_digest"]}, indent=2))


if __name__ == "__main__":
    try:
        main()
    except upgrade.UpgradeError as exc:
        print(json.dumps({"error_code": exc.code}), file=sys.stderr)
        sys.exit(1)
