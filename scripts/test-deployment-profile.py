#!/usr/bin/env python3
"""Deferred capacity regressions. Run with the later consolidated acceptance batch."""
import importlib.util
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('deployment_profile', Path(__file__).with_name('deployment-profile.py'))
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


class CapacityPlanTest(unittest.TestCase):
    def capacity(self, **changes):
        return dict(memory_mib=8192, available_mib=7000, cpus=4, disk_free_mib=65536, disk_path='/') | changes

    def planned(self, name='auto', mode='local', installed=False, **changes):
        with patch.object(profile, 'host_capacity', return_value=self.capacity(**changes)):
            return profile.plan(Path('/unused'), name, mode, 7, installed)

    def test_auto_selects_a_profile_that_fits_every_budget(self):
        result = self.planned()
        self.assertEqual(result['profile'], 'balanced')
        self.assertTrue(result['ready'])
        self.assertEqual(result['required_memory_mib'], 4736)
        self.assertEqual(self.planned(cpus=2)['profile'], 'minimal')
        self.assertEqual(self.planned(disk_free_mib=10000)['profile'], 'minimal')

    def test_explicit_profile_fails_closed_for_each_missing_resource(self):
        cases = [({'memory_mib': 2000}, 'HOST_MEMORY_INSUFFICIENT'),
                 ({'available_mib': 2000}, 'AVAILABLE_MEMORY_INSUFFICIENT'),
                 ({'cpus': 1.5}, 'CPU_CAPACITY_INSUFFICIENT'),
                 ({'disk_free_mib': 7000}, 'DISK_HEADROOM_INSUFFICIENT')]
        for changes, failure in cases:
            with self.subTest(failure=failure):
                result = self.planned('minimal', **changes)
                self.assertFalse(result['ready'])
                self.assertIn(failure, result['failures'])

    def test_installed_check_does_not_count_live_services_memory_twice(self):
        result = self.planned('balanced', installed=True, available_mib=256)
        self.assertTrue(result['ready'])
        self.assertFalse(self.planned('balanced', available_mib=256)['ready'])

    def test_host_and_external_database_are_not_budgeted_as_managed_mysql(self):
        for mode in ('host', 'external'):
            result = self.planned('minimal', mode, available_mib=2000)
            self.assertTrue(result['ready'])
            self.assertEqual(result['required_memory_mib'], 1792)
            self.assertIn('EXTERNAL_DATABASE_CAPACITY_NOT_INCLUDED', result['warnings'])

    def test_cgroup_memory_and_cpu_are_respected(self):
        data = {'/proc/meminfo': 'MemTotal: 8388608 kB\nMemAvailable: 7340032 kB',
                '/sys/fs/cgroup/memory.max': str(3 * 1024**3),
                '/sys/fs/cgroup/memory.current': str(1024**3),
                '/sys/fs/cgroup/cpu.max': '150000 100000'}
        with patch.object(profile, 'text_file', side_effect=lambda path: data.get(path, '')), \
             patch.object(profile.os, 'sched_getaffinity', return_value={0, 1, 2, 3}), \
             patch.object(profile.shutil, 'disk_usage', return_value=SimpleNamespace(free=10 * 1024**3)):
            capacity = profile.host_capacity(Path('/'))
        self.assertEqual(capacity['memory_mib'], 3072)
        self.assertEqual(capacity['available_mib'], 2048)
        self.assertEqual(capacity['cpus'], 1.5)


if __name__ == '__main__':
    unittest.main()
