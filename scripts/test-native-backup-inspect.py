#!/usr/bin/env python3
"""Backup inspection regressions; execution is deferred to concentrated acceptance."""
import gzip
import hashlib
import importlib.util
import io
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('native_runtime', Path(__file__).with_name('native-runtime.py'))
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)
STAMP = '20261019T010203Z'
ENV = b'APP_KEY=synthetic-test-key\nCORE_INSTALLATION_MODE=native\n'


class BackupInspectionTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.folder = self.root / 'backups' / STAMP
        self.folder.mkdir(parents=True)
        self.members = {'.env': b'TXBOARD_IMAGE=sha256:' + b'1' * 64 + b'\n',
                        'api.env': ENV, 'compose.yaml': b'name: txboard\n', 'native': None}
        self.members.update({'native/' + name: b'synthetic-material\n' for name in native.REQUIRED_FILES})
        (self.folder / 'env').write_bytes(ENV)
        (self.folder / 'db.sql.gz').write_bytes(gzip.compress(b'-- synthetic SQL fixture\n'))
        (self.folder / 'MANIFEST').write_text('native=1\nconsistency=online-snapshot\n')
        self.write_archive()

    def write_archive(self, link=None):
        with tarfile.open(self.folder / 'native-deployment.tar.gz', 'w:gz') as archive:
            for name, data in self.members.items():
                member = tarfile.TarInfo(name)
                if data is None:
                    member.type = tarfile.DIRTYPE
                    archive.addfile(member)
                else:
                    member.size = len(data)
                    archive.addfile(member, io.BytesIO(data))
            if link:
                member = tarfile.TarInfo(link)
                member.type, member.linkname = tarfile.SYMTYPE, '/outside'
                archive.addfile(member)
        self.checksums()

    def checksums(self):
        names = ('env', 'db.sql.gz', 'MANIFEST', 'native-deployment.tar.gz')
        (self.folder / 'CHECKSUMS.sha256').write_text(''.join(
            hashlib.sha256((self.folder / name).read_bytes()).hexdigest() + '  ' + name + '\n' for name in names))

    def test_complete_materials_require_a_separate_restore_rehearsal(self):
        result = native.inspect_backup(self.root, STAMP)
        self.assertTrue(result['integrity_verified'])
        self.assertTrue(result['materials_verified'])
        self.assertTrue(result['immutable_image_recorded'])
        self.assertEqual(result['consistency'], 'online-snapshot')
        self.assertEqual(result['restore_rehearsal'], 'required_in_isolated_environment')
        self.assertNotIn('synthetic-test-key', str(result))

    def test_checksum_does_not_match_modified_dump(self):
        (self.folder / 'db.sql.gz').write_bytes(gzip.compress(b'changed'))
        with self.assertRaisesRegex(native.NativeError, 'BACKUP_CHECKSUM_MISMATCH'):
            native.inspect_backup(self.root, STAMP)

    def test_valid_hash_of_corrupt_compression_is_rejected(self):
        (self.folder / 'db.sql.gz').write_bytes(b'not-gzip')
        self.checksums()
        with self.assertRaisesRegex(native.NativeError, 'BACKUP_ARCHIVE_INVALID'):
            native.inspect_backup(self.root, STAMP)

    def test_database_and_native_environment_must_share_the_same_key(self):
        self.members['api.env'] = ENV.replace(b'synthetic-test-key', b'different-key')
        self.write_archive()
        with self.assertRaisesRegex(native.NativeError, 'BACKUP_NATIVE_MATERIALS_INCOMPLETE'):
            native.inspect_backup(self.root, STAMP)

    def test_missing_signing_material_is_rejected(self):
        del self.members['native/signer.seed']
        self.write_archive()
        with self.assertRaisesRegex(native.NativeError, 'BACKUP_NATIVE_MATERIALS_INCOMPLETE'):
            native.inspect_backup(self.root, STAMP)

    def test_directory_cannot_substitute_for_required_material(self):
        self.members['native/signer.seed'] = None
        self.write_archive()
        with self.assertRaisesRegex(native.NativeError, 'BACKUP_MEMBER_INVALID'):
            native.inspect_backup(self.root, STAMP)

    def test_links_and_traversal_are_rejected_without_extraction(self):
        self.write_archive(link='native/link')
        with self.assertRaisesRegex(native.NativeError, 'BACKUP_MEMBER_INVALID'):
            native.inspect_backup(self.root, STAMP)
        self.members['../outside'] = b'escape'
        self.write_archive()
        with self.assertRaisesRegex(native.NativeError, 'BACKUP_MEMBER_INVALID'):
            native.inspect_backup(self.root, STAMP)
        self.assertFalse((self.root / 'outside').exists())

    def test_original_durable_backup_record_cannot_be_replaced(self):
        with self.assertRaisesRegex(native.NativeError, 'BACKUP_RECORD_CHANGED'):
            native.inspect_backup(self.root, STAMP, '0' * 64)
        with self.assertRaisesRegex(native.NativeError, 'BACKUP_RECORD_INVALID'):
            native.inspect_backup(self.root, '../outside')

    def test_inspection_does_not_invoke_docker_or_write_files(self):
        def snapshot():
            return {str(path.relative_to(self.root)): hashlib.sha256(path.read_bytes()).hexdigest()
                    for path in self.root.rglob('*') if path.is_file()}
        before = snapshot()
        with patch.object(native.subprocess, 'run', side_effect=AssertionError('external process')):
            native.inspect_backup(self.root, STAMP)
        self.assertEqual(before, snapshot())


if __name__ == '__main__':
    unittest.main()
