#!/usr/bin/env python3
"""Read-only host capacity planning for Core deployments."""
import argparse
import json
import os
import shutil
from pathlib import Path

MIB = 1024 * 1024
PROFILES = {
    'minimal': dict(core_mib=1024, database_mib=768, backup_mib=256, reserve_mib=512,
                    core_cpus=1, database_cpus=0.5, backup_cpus=0.25, min_cpus=2, disk_gib=8,
                    octane=1, pipeline=1, business=1, notification=1, worker_mib=128, redis_mib=128),
    'balanced': dict(core_mib=2048, database_mib=1536, backup_mib=384, reserve_mib=768,
                     core_cpus=2, database_cpus=1, backup_cpus=0.5, min_cpus=4, disk_gib=16,
                     octane=2, pipeline=2, business=1, notification=1, worker_mib=128, redis_mib=256),
    'performance': dict(core_mib=4096, database_mib=3072, backup_mib=512, reserve_mib=1024,
                        core_cpus=4, database_cpus=2, backup_cpus=0.5, min_cpus=8, disk_gib=32,
                        octane=4, pipeline=4, business=2, notification=2, worker_mib=192, redis_mib=512),
}


def text_file(path):
    try:
        return Path(path).read_text().strip()
    except OSError:
        return ''


def host_capacity(path):
    memory = {}
    for line in text_file('/proc/meminfo').splitlines():
        key, value = line.split(':', 1)
        memory[key] = int(value.split()[0]) * 1024
    total = memory.get('MemTotal', 0)
    available = memory.get('MemAvailable', 0)
    # Use the most restrictive visible cgroup budget. Unknown capacity fails closed.
    for limit_path, usage_path in (('/sys/fs/cgroup/memory.max', '/sys/fs/cgroup/memory.current'),
                                   ('/sys/fs/cgroup/memory/memory.limit_in_bytes', '/sys/fs/cgroup/memory/memory.usage_in_bytes')):
        limit, usage = text_file(limit_path), text_file(usage_path)
        if limit.isdecimal() and int(limit) < (1 << 60):
            total = min(total, int(limit))
            available = min(available, max(0, int(limit) - int(usage))) if usage.isdecimal() else 0
    cpus = float(len(os.sched_getaffinity(0)) if hasattr(os, 'sched_getaffinity') else os.cpu_count() or 1)
    quota = text_file('/sys/fs/cgroup/cpu.max').split()
    if len(quota) == 2 and quota[0].isdecimal() and quota[1].isdecimal() and int(quota[1]) > 0:
        cpus = min(cpus, int(quota[0]) / int(quota[1]))
    quota, period = text_file('/sys/fs/cgroup/cpu/cpu.cfs_quota_us'), text_file('/sys/fs/cgroup/cpu/cpu.cfs_period_us')
    if quota.isdecimal() and period.isdecimal() and int(period) > 0:
        cpus = min(cpus, int(quota) / int(period))
    existing = path
    while not existing.exists() and existing != existing.parent:
        existing = existing.parent
    disk = shutil.disk_usage(existing)
    return dict(memory_mib=total // MIB, available_mib=available // MIB, cpus=round(cpus, 3),
                disk_free_mib=disk.free // MIB, disk_path=str(existing))


def plan(path, profile, database_mode, retention, installed=False):
    capacity = host_capacity(path)
    if profile == 'auto':
        profile = 'minimal'
        for name, values in PROFILES.items():
            required = values['core_mib'] + values['backup_mib'] + values['reserve_mib']
            if database_mode == 'local':
                required += values['database_mib']
            usable = capacity['memory_mib'] if installed else capacity['available_mib']
            if usable >= required and capacity['cpus'] >= values['min_cpus'] and capacity['disk_free_mib'] >= values['disk_gib'] * 1024:
                profile = name
    values = PROFILES[profile].copy()
    required = values['core_mib'] + values['backup_mib'] + values['reserve_mib']
    if database_mode == 'local':
        required += values['database_mib']
    failures = []
    if capacity['memory_mib'] < required:
        failures.append('HOST_MEMORY_INSUFFICIENT')
    if not installed and capacity['available_mib'] < required:
        failures.append('AVAILABLE_MEMORY_INSUFFICIENT')
    if capacity['cpus'] < values['min_cpus']:
        failures.append('CPU_CAPACITY_INSUFFICIENT')
    if capacity['disk_free_mib'] < values['disk_gib'] * 1024:
        failures.append('DISK_HEADROOM_INSUFFICIENT')
    warnings = ['CAPACITY_ESTIMATE_IS_NOT_A_LOAD_TEST', 'DATABASE_AND_BACKUP_GROWTH_REQUIRE_MONITORING',
                'GATEWAY_PROVIDER_AND_NODE_BUDGETS_NOT_INCLUDED']
    if database_mode != 'local':
        warnings.append('EXTERNAL_DATABASE_CAPACITY_NOT_INCLUDED')
    if retention == 0:
        warnings.append('UNLIMITED_BACKUP_RETENTION')
    return dict(schema='txboard.deployment-profile/v1', profile=profile, database_mode=database_mode,
                limits=values, required_memory_mib=required, capacity=capacity,
                ready=not failures, failures=failures, warnings=warnings)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dir', required=True, type=Path)
    parser.add_argument('--profile', choices=('auto', *PROFILES), default='auto')
    parser.add_argument('--db-mode', choices=('local', 'host', 'external'), default='local')
    parser.add_argument('--retention', type=int, default=7)
    parser.add_argument('--installed', action='store_true', help='check total budget; running services already consume available RAM')
    parser.add_argument('--field', help='emit a single public dotted field for shell integration')
    args = parser.parse_args()
    if args.retention < 0:
        parser.error('retention must be non-negative')
    result = plan(args.dir.absolute(), args.profile, args.db_mode, args.retention, args.installed)
    if args.field:
        value = result
        for key in args.field.split('.'):
            value = value[key]
        print(str(value).lower() if isinstance(value, bool) else value)
    else:
        print(json.dumps(result, sort_keys=True))
    return 0 if result['ready'] else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError):
        print(json.dumps({'schema': 'txboard.deployment-profile/v1', 'ready': False, 'failures': ['CAPACITY_UNAVAILABLE']}))
        raise SystemExit(1)
