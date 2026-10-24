#!/usr/bin/env python3
"""Read the bounded Core report without starting the normal application entrypoint."""
import argparse
import json
import re
import subprocess
import sys
from pathlib import Path


class DiagnosticError(Exception):
    pass


def require(condition, code):
    if not condition:
        raise DiagnosticError(code)


def invoke(root, arguments, timeout=30):
    try:
        return subprocess.run(['docker', *arguments], cwd=root, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise DiagnosticError('CORE_DIAGNOSTICS_TIMEOUT') from None
    except OSError:
        raise DiagnosticError('DOCKER_UNAVAILABLE') from None


def decode(output):
    require(len(output) <= 131072, 'CORE_DIAGNOSTICS_RESPONSE_LIMIT')
    try:
        return json.loads(output, object_pairs_hook=unique_pairs)
    except (ValueError, UnicodeError):
        raise DiagnosticError('CORE_DIAGNOSTICS_UNAVAILABLE') from None


def unique_pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, 'CORE_DIAGNOSTICS_INVALID')
        result[key] = value
    return result


def inspect_core(root, show_admin_path=False):
    require(root.is_dir() and not root.is_symlink() and root.resolve() == root, 'UNSAFE_INSTALLATION_DIRECTORY')
    for name in ('compose.yaml', '.env', 'api.env'):
        path = root / name
        require(path.is_file() and not path.is_symlink(), 'DEPLOYMENT_CONFIGURATION_REQUIRED')

    process = invoke(root, ['compose', 'ps', '--all', '-q', 'txboard'], timeout=10)
    require(process.returncode == 0, 'CORE_CONTAINER_LOOKUP_FAILED')
    ids = process.stdout.decode('ascii', errors='replace').split()
    require(len(ids) <= 1 and all(re.fullmatch(r'[a-f0-9]{12,64}', value) for value in ids), 'CORE_CONTAINER_AMBIGUOUS')
    running = False
    if ids:
        process = invoke(root, ['inspect', '--type', 'container', ids[0]], timeout=10)
        require(process.returncode == 0, 'CORE_CONTAINER_LOOKUP_FAILED')
        containers = decode(process.stdout)
        require(isinstance(containers, list) and len(containers) == 1 and isinstance(containers[0], dict), 'CORE_CONTAINER_LOOKUP_FAILED')
        container = containers[0]
        require(isinstance(container.get('Config'), dict) and isinstance(container.get('State'), dict), 'CORE_CONTAINER_LOOKUP_FAILED')
        labels = container['Config'].get('Labels') or {}
        require(isinstance(labels, dict), 'CORE_CONTAINER_LOOKUP_FAILED')
        require(labels.get('com.docker.compose.service') == 'txboard'
                and labels.get('com.docker.compose.project.working_dir') == str(root), 'CORE_CONTAINER_OWNERSHIP_INVALID')
        running = container.get('State', {}).get('Status') == 'running'

    if running:
        command = ['compose', 'exec', '-T', 'txboard', 'php', '/www/artisan']
    else:
        process = invoke(root, ['compose', 'config', '--format', 'json'], timeout=10)
        require(process.returncode == 0, 'DEPLOYMENT_CONFIGURATION_UNAVAILABLE')
        configuration = decode(process.stdout)
        services = configuration.get('services') if isinstance(configuration, dict) else None
        service = services.get('txboard') if isinstance(services, dict) else None
        require(isinstance(service, dict) and 'build' not in service and service.get('pull_policy') != 'build',
                'CORE_DIAGNOSTICS_BUILD_CONFIGURATION_REFUSED')
        image = service.get('image')
        require(isinstance(image, str) and re.fullmatch(r'[a-z0-9][A-Za-z0-9._:/@-]{0,511}', image), 'CORE_DIAGNOSTICS_IMAGE_REQUIRED')
        process = invoke(root, ['image', 'inspect', image], timeout=10)
        require(process.returncode == 0, 'CORE_DIAGNOSTICS_LOCAL_IMAGE_REQUIRED')
        # Never pull/build, run entrypoint migrations, start dependencies or publish ports.
        command = ['compose', 'run', '-T', '--rm', '--no-deps', '--pull', 'never',
                   '-e', 'CACHE_DRIVER=array', '-e', 'SETTING_CACHE_STORE=array',
                   '-e', 'QUEUE_CONNECTION=sync', '-e', 'SESSION_DRIVER=array',
                   '--entrypoint', 'php', 'txboard', '/www/artisan']
    command += ['core:diagnose', '--json', '--no-interaction']
    if show_admin_path:
        command.append('--show-admin-path')
    process = invoke(root, command)
    require(process.returncode in (0, 1), 'CORE_DIAGNOSTICS_UNAVAILABLE')
    report = decode(process.stdout)
    require(isinstance(report, dict) and set(report) == {'schema', 'read_only', 'external_services_probed', 'healthy', 'sections'}
            and report['schema'] == 'core-diagnostics/v1' and report['read_only'] is True
            and report['external_services_probed'] is False and type(report['healthy']) is bool, 'CORE_DIAGNOSTICS_INVALID')
    sections = report['sections']
    require(isinstance(sections, dict) and set(sections) == {'configuration', 'installation', 'runtime', 'administrator_entry', 'providers', 'modules'}, 'CORE_DIAGNOSTICS_INVALID')
    for section in sections.values():
        require(isinstance(section, dict) and section.get('status') in ('ok', 'error', 'not_applicable'), 'CORE_DIAGNOSTICS_INVALID')
        if section['status'] == 'ok':
            require(isinstance(section.get('data'), dict), 'CORE_DIAGNOSTICS_INVALID')
        elif section['status'] == 'error':
            require(isinstance(section.get('error_code'), str)
                    and re.fullmatch(r'[A-Z][A-Z0-9_]{1,127}', section['error_code']), 'CORE_DIAGNOSTICS_INVALID')
    expected_healthy = not any(section['status'] == 'error' for section in sections.values())
    require(report['healthy'] == expected_healthy and process.returncode == (0 if report['healthy'] else 1), 'CORE_DIAGNOSTICS_INVALID')
    entry = sections['administrator_entry']
    if entry['status'] == 'ok':
        data = entry['data']
        require(data.get('path_disclosed') is show_admin_path, 'CORE_DIAGNOSTICS_INVALID')
        require(isinstance(data.get('path'), str) and (re.fullmatch(r'/[A-Za-z0-9_-]{1,128}', data['path']) if show_admin_path
                else data['path'] == '[redacted]'), 'CORE_DIAGNOSTICS_INVALID')
    return report


def main():
    parser = argparse.ArgumentParser(description='Read Core diagnostics; never retry or change installation state.')
    parser.add_argument('--dir', type=Path, required=True)
    parser.add_argument('--show-admin-path', action='store_true', help='include the private administrator entry; do not share this output')
    args = parser.parse_args()
    try:
        report = inspect_core(args.dir.absolute(), args.show_admin_path)
        print(json.dumps(report, sort_keys=True))
        return 0 if report['healthy'] else 1
    except DiagnosticError as error:
        print(json.dumps({'schema': 'txboard.core-diagnostics-error/v1', 'error_code': str(error)}))
        return 1
    except (OSError, ValueError):
        print(json.dumps({'schema': 'txboard.core-diagnostics-error/v1', 'error_code': 'DEPLOYMENT_CONFIGURATION_UNAVAILABLE'}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
