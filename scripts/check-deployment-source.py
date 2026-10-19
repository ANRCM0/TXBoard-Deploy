#!/usr/bin/env python3
"""Static deployment source checks. Does not start services or exercise workflows."""
import ast
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
installer = (ROOT / 'install.sh').read_text(encoding='utf-8')
backup = (ROOT / 'backup.sh').read_text(encoding='utf-8')
marker = "cat > backup.sh <<'BACKUP'\n"
assert installer.count(marker) == 1, 'embedded backup start is ambiguous'
embedded = installer.split(marker, 1)[1].split('\nBACKUP\nchmod 700 backup.sh', 1)[0] + '\n'
assert embedded == backup, 'installer backup helper differs from standalone source'

assert installer.index('\nselect_database_mode\n') < installer.index('\nconfigure_resources\n') < installer.index('\nconfigure_database\n'), 'capacity check must precede database provisioning'
assert installer.index(' validate-config --dir ') < installer.index('\nconfigure_database\n'), 'private source checks must precede database provisioning'

# These values must be produced before the unquoted Compose heredoc is rendered.
compose = installer.split('cat > compose.yaml <<EOF\n', 1)[1].split('\nEOF\n', 1)[0]
env_block = installer.split('cat > .env <<EOF\n', 1)[1].split('\nEOF\n', 1)[0]
resource_prefixes = ('CORE_MEMORY_', 'CORE_CPUS', 'DATABASE_MEMORY_', 'DATABASE_CPUS', 'BACKUP_MEMORY_', 'BACKUP_CPUS',
                     'OCTANE_', 'HORIZON_', 'WORKER_MEMORY_', 'REDIS_MEMORY_', 'RESOURCE_PROFILE')
for key in re.findall(r'\\\$\{(TXBOARD_[A-Z_]+)', compose):
    if key.removeprefix('TXBOARD_').startswith(resource_prefixes):
        assert re.search(r'^' + key + '=', env_block, re.M), 'missing generated resource setting: ' + key
for line in compose.splitlines():
    if any(key in line for key in ('TXBOARD_CORE_MEMORY_', 'TXBOARD_BACKUP_MEMORY_', 'TXBOARD_CORE_CPUS', 'TXBOARD_REDIS_MEMORY_',
                                   'TXBOARD_RESOURCE_PROFILE', 'TXBOARD_HORIZON_', 'TXBOARD_OCTANE_', 'TXBOARD_WORKER_MEMORY_')):
        assert r'\${' in line, 'resource variable expanded before Compose: ' + line
assert compose.count('$NATIVE_BACKUP_VOLUME_BLOCK') == 1, 'native backup bind must be singular'
assert 'BACKUP_NATIVE_MODE: "$NATIVE_BACKUP_MODE"' in compose
for script in ('deployment-profile.py', 'native-runtime.py', 'test-deployment-profile.py', 'test-native-backup-inspect.py'):
    ast.parse((ROOT / 'scripts' / script).read_text(encoding='utf-8'), filename=script)
print('Deployment source invariants: passed (static only)')
