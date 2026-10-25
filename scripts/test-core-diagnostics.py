#!/usr/bin/env python3
"""Core diagnostic subprocess, redaction and lifecycle acceptance. Run in Actions."""
import copy
import hashlib
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('core_diagnostics', Path(__file__).with_name('core-diagnostics.py'))
diagnostics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostics)


class CoreDiagnosticsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        for name in ('.env', 'api.env', 'compose.yaml'):
            (self.root / name).write_text('private-input-unchanged\n')
        self.running = True
        self.ids = b'a' * 64 + b'\n'
        self.owner = str(self.root)
        self.build = False
        self.local_image = True
        self.calls = []
        self.exit = 0
        self.raw = None
        self.report = {'schema': 'core-diagnostics/v1', 'read_only': True, 'external_services_probed': False,
                       'healthy': True, 'sections': {name: {'status': 'ok', 'data': {}} for name in
                       ('configuration', 'installation', 'runtime', 'administrator_entry', 'providers', 'modules')}}
        self.report['sections']['administrator_entry']['data'] = {'path': '[redacted]', 'path_disclosed': False}

    def process(self, arguments, **options):
        self.calls.append(arguments)
        self.assertEqual(self.root, options['cwd'])
        self.assertEqual(subprocess.DEVNULL, options['stdin'])
        self.assertLessEqual(options['timeout'], 30)
        self.assertGreater(options['timeout'], 0)
        if arguments[1:3] == ['compose', 'ps']:
            return subprocess.CompletedProcess(arguments, 0, self.ids, b'')
        if arguments[1] == 'inspect':
            body = [{'Config': {'Labels': {'com.docker.compose.service': 'txboard',
                     'com.docker.compose.project.working_dir': self.owner}},
                     'State': {'Status': 'running' if self.running else 'exited'}}]
            return subprocess.CompletedProcess(arguments, 0, json.dumps(body).encode(), b'')
        if arguments[1:3] == ['compose', 'config']:
            service = {'image': 'sha256:' + '1' * 64}
            if self.build:
                service['build'] = {'context': '/private/do-not-build'}
            return subprocess.CompletedProcess(arguments, 0, json.dumps({'services': {'txboard': service}}).encode(), b'')
        if arguments[1:3] == ['image', 'inspect']:
            return subprocess.CompletedProcess(arguments, 0 if self.local_image else 1, b'[]', b'')
        self.assertIn('core:diagnose', arguments)
        return subprocess.CompletedProcess(arguments, self.exit, self.raw if self.raw is not None else json.dumps(self.report).encode(),
                                           b'private stderr password must never be exported')

    def invoke(self, show=False):
        with patch.object(diagnostics.subprocess, 'run', side_effect=self.process):
            return diagnostics.inspect_core(self.root, show)

    def test_running_unhealthy_container_can_be_inspected_without_a_restart_or_file_changes(self):
        before = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in self.root.iterdir()}
        self.assertEqual(self.report, self.invoke())
        command = self.calls[-1]
        self.assertEqual(['docker', 'compose', 'exec', '-T', 'txboard', 'php', '/www/artisan'], command[:7])
        self.assertNotIn('--show-admin-path', command)
        self.assertNotIn('restart', command)
        self.assertEqual(before, {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in self.root.iterdir()})

    def test_stopped_container_uses_a_one_off_without_entrypoint_or_dependency_startup(self):
        self.running = False
        self.invoke()
        command = self.calls[-1]
        for option in ('--rm', '--no-deps'):
            self.assertIn(option, command)
        self.assertEqual('never', command[command.index('--pull') + 1])
        self.assertEqual('php', command[command.index('--entrypoint') + 1])
        self.assertIn('CACHE_DRIVER=array', command)
        self.assertIn('SETTING_CACHE_STORE=array', command)
        self.assertNotIn('--no-build', command)
        self.assertFalse(any(value in command for value in ('up', 'start', 'restart', 'pull', 'build', 'migrate')))

    def test_missing_container_can_use_the_existing_local_image_without_creating_a_database(self):
        self.ids = b''
        self.invoke()
        self.assertIn('run', self.calls[-1])
        self.assertEqual(4, len(self.calls))

    def test_stopped_diagnostics_refuse_compose_build_configuration(self):
        self.running = False
        self.build = True
        with self.assertRaisesRegex(diagnostics.DiagnosticError, 'CORE_DIAGNOSTICS_BUILD_CONFIGURATION_REFUSED'):
            self.invoke()
        self.assertFalse(any('core:diagnose' in command for command in self.calls))

    def test_missing_local_image_never_triggers_a_build_or_pull(self):
        self.running = False
        self.local_image = False
        with self.assertRaisesRegex(diagnostics.DiagnosticError, 'CORE_DIAGNOSTICS_LOCAL_IMAGE_REQUIRED'):
            self.invoke()
        self.assertFalse(any('core:diagnose' in command or 'pull' in command or 'build' in command for command in self.calls))

    def test_degraded_report_survives_the_expected_nonzero_core_exit(self):
        self.report['healthy'] = False
        self.report['sections']['runtime'] = {'status': 'error', 'error_code': 'INSTALLATION_AUTHORITY_WORKER_MISMATCH'}
        self.exit = 1
        self.assertEqual(self.report, self.invoke())

    def test_admin_path_requires_explicit_operator_option(self):
        self.report['sections']['administrator_entry']['data'] = {'path': '/private-admin-path', 'path_disclosed': True}
        with self.assertRaisesRegex(diagnostics.DiagnosticError, 'CORE_DIAGNOSTICS_INVALID'):
            self.invoke()
        self.assertEqual(self.report, self.invoke(True))
        self.assertIn('--show-admin-path', self.calls[-1])

    def test_unrelated_container_is_not_executed(self):
        self.owner = '/different/deployment'
        with self.assertRaisesRegex(diagnostics.DiagnosticError, 'CORE_CONTAINER_OWNERSHIP_INVALID'):
            self.invoke()
        self.assertFalse(any('core:diagnose' in command for command in self.calls))

    def test_ambiguous_container_selection_is_rejected(self):
        self.ids += b'b' * 64 + b'\n'
        with self.assertRaisesRegex(diagnostics.DiagnosticError, 'CORE_CONTAINER_AMBIGUOUS'):
            self.invoke()
        self.assertEqual(1, len(self.calls))

    def test_old_image_or_invalid_php_output_is_not_echoed(self):
        self.exit = 1
        self.raw = b'SQLSTATE: mysql://user:NEVER_EXPORT_PASSWORD@private-host'
        with self.assertRaisesRegex(diagnostics.DiagnosticError, '^CORE_DIAGNOSTICS_UNAVAILABLE$'):
            self.invoke()

    def test_timeout_discards_private_subprocess_details(self):
        with patch.object(diagnostics.subprocess, 'run', side_effect=subprocess.TimeoutExpired('NEVER_EXPORT_PASSWORD', 30)):
            with self.assertRaisesRegex(diagnostics.DiagnosticError, '^CORE_DIAGNOSTICS_TIMEOUT$'):
                diagnostics.inspect_core(self.root)

    def test_missing_configuration_does_not_create_files_or_run_docker(self):
        (self.root / 'api.env').unlink()
        with self.assertRaisesRegex(diagnostics.DiagnosticError, 'DEPLOYMENT_CONFIGURATION_REQUIRED'):
            self.invoke()
        self.assertEqual([], self.calls)

    def test_duplicate_keys_and_oversized_reports_are_rejected(self):
        for raw, code in ((b'{"healthy":false,"healthy":true}', 'CORE_DIAGNOSTICS_INVALID'),
                          (b'x' * 131073, 'CORE_DIAGNOSTICS_RESPONSE_LIMIT')):
            with self.subTest(code=code):
                self.raw = raw
                with self.assertRaisesRegex(diagnostics.DiagnosticError, code):
                    self.invoke()

    def test_core_cannot_claim_success_with_an_error_section(self):
        self.report['sections']['runtime'] = {'status': 'error', 'error_code': 'INSTALLATION_AUTHORITY_NATIVE_NOT_READY'}
        with self.assertRaisesRegex(diagnostics.DiagnosticError, 'CORE_DIAGNOSTICS_INVALID'):
            self.invoke()

    def test_invalid_report_shapes_never_escape_as_a_traceback(self):
        for report in ([], None, {}, {'schema': 'different'}, copy.deepcopy(self.report)):
            if isinstance(report, dict) and 'sections' in report:
                report['sections']['configuration'] = []
            with self.subTest(report=report):
                self.raw = json.dumps(report).encode()
                with self.assertRaises(diagnostics.DiagnosticError):
                    self.invoke()


if __name__ == '__main__':
    unittest.main()
