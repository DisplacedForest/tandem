import base64
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('runtime_package', ROOT / 'apps/vera-mac/scripts/package_runtime.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RuntimePackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def archive(self, entries):
        path = self.root / 'archive.tar'
        with tarfile.open(path, 'w') as archive:
            for name, data, link in entries:
                item = tarfile.TarInfo(name)
                if link is not None:
                    item.type = tarfile.SYMTYPE
                    item.linkname = link
                    archive.addfile(item)
                else:
                    item.size = len(data)
                    archive.addfile(item, io.BytesIO(data))
        return path

    def test_rejects_traversal_and_external_links(self):
        for name, link in [('package/../../escape', None), ('package/link', '../../escape'), ('/package/file', None)]:
            with self.subTest(name=name, link=link), self.assertRaises(ValueError):
                MODULE.extract_tar(self.archive([(name, b'x', link)]), self.root / 'out', 'package')
        self.assertFalse((self.root / 'escape').exists())

    def test_preserves_internal_links_and_file_bytes(self):
        archive = self.archive([('package/bin/python3', b'python', None), ('package/bin/python', b'', 'python3')])
        MODULE.extract_tar(archive, self.root / 'out', 'package')
        self.assertEqual((self.root / 'out/bin/python').read_bytes(), b'python')
        self.assertEqual(len(MODULE.validate_tree(self.root / 'out')), 2)
        MODULE.materialize_links(self.root / 'out')
        self.assertFalse((self.root / 'out/bin/python').is_symlink())
        self.assertEqual((self.root / 'out/bin/python').read_bytes(), b'python')

    def test_duplicate_normalized_paths_require_identical_bytes(self):
        archive = self.archive([('package/./file', b'original', None), ('package/file', b'changed', None)])
        with self.assertRaisesRegex(ValueError, 'Conflicting'):
            MODULE.extract_tar(archive, self.root / 'out', 'package')

    def test_cache_is_checked_even_offline(self):
        cache = self.root / 'cache'
        cache.mkdir()
        digest = hashlib.sha256(b'expected').hexdigest()
        (cache / digest).write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            MODULE.download('https://nodejs.org/artifact', digest, cache, True)
        with self.assertRaisesRegex(ValueError, 'origin'):
            MODULE.download('https://untrusted.example/artifact', digest, cache, True)

    def test_wheels_cannot_install_startup_hooks(self):
        path = self.root / 'wheel.zip'
        with zipfile.ZipFile(path, 'w') as wheel:
            wheel.writestr('example.dist-info/LICENSE', 'MIT')
            wheel.writestr('startup.pth', 'import unsafe')
        with self.assertRaisesRegex(ValueError, 'Unsupported'):
            MODULE.extract_wheel(path, self.root / 'site')

    def test_lock_contains_only_pinned_supported_wheels(self):
        lock = json.loads((ROOT / 'apps/vera-mac/runtime/runtime-lock.json').read_text())
        self.assertEqual(lock['platform'], 'macos-arm64')
        self.assertEqual(lock['python']['version'], '3.12.15')
        self.assertGreaterEqual(tuple(map(int, lock['node']['version'].split('.'))), (24, 9, 0))
        self.assertEqual(len(lock['node']['sha256']), 64)
        for wheel in lock['wheels']:
            self.assertEqual(len(wheel['sha256']), 64)
            self.assertTrue(wheel['filename'].endswith('py3-none-any.whl') or 'cp312-cp312-macosx' in wheel['filename'] and 'arm64' in wheel['filename'])
            self.assertTrue(wheel['license'])
        self.assertFalse(any('main.py' in name or 'config' in name or 'scheduler' in name for name in MODULE.SOURCES))

    def application(self, files=None):
        source = self.root / 'application'
        source.mkdir()
        package = {'name': 'test-runtime', 'version': '1.0.0', 'dependencies': {'fixture': '1.0.0'},
                   'files': files or ['sidecar.mjs', 'runtime.mjs']}
        (source / 'package.json').write_text(json.dumps(package))
        (source / 'sidecar.mjs').write_text('import "./runtime.mjs"')
        (source / 'runtime.mjs').write_text('export const runtime = true')
        (source / 'secret.txt').write_text('not a package input')
        archive = self.archive([('package/package.json', json.dumps({
            'name': 'fixture', 'version': '1.0.0', 'scripts': {'postinstall': 'exit 99'}
        }).encode(), None), ('package/LICENSE', b'MIT', None), ('package/index.js', b'export {}', None)])
        digest = hashlib.sha512(archive.read_bytes()).digest()
        integrity = 'sha512-' + base64.b64encode(digest).decode()
        lock = {'lockfileVersion': 3, 'packages': {'': package, 'node_modules/fixture': {
            'version': '1.0.0', 'license': 'MIT', 'integrity': integrity,
            'resolved': 'https://registry.npmjs.org/fixture/-/fixture-1.0.0.tgz'
        }}}
        (source / 'package-lock.json').write_text(json.dumps(lock))
        cache = self.root / 'cache'
        cache.mkdir()
        (cache / digest.hex()).write_bytes(archive.read_bytes())
        return source, cache, lock, digest

    def test_locked_application_includes_only_declared_sources_and_exact_dependencies(self):
        source, cache, lock, digest = self.application()
        destination = self.root / 'runtime'
        copied = MODULE.copy_application(source, destination)
        self.assertEqual(copied, ['package-lock.json', 'package.json', 'runtime.mjs', 'sidecar.mjs'])
        self.assertFalse((destination / 'secret.txt').exists())
        audit = MODULE.assemble_npm(source, destination, cache, True)
        self.assertEqual((destination / 'node_modules/fixture/LICENSE').read_bytes(), b'MIT')
        self.assertEqual(audit[0]['version'], '1.0.0')
        self.assertFalse(audit[0]['scripts_executed'])
        manifest = destination / 'manifest.json'
        manifest.write_text(json.dumps({'files': MODULE.validate_tree(destination)}))
        seal = MODULE.file_hash(manifest).hex()
        MODULE.verify(destination, seal)
        (destination / 'runtime.mjs').write_text('tampered')
        with self.assertRaisesRegex(ValueError, 'inventory'):
            MODULE.verify(destination, seal)

    def test_locked_application_rejects_mismatched_manifest_and_corrupt_cache(self):
        source, cache, lock, digest = self.application()
        lock['packages']['']['dependencies'] = {'fixture': '2.0.0'}
        (source / 'package-lock.json').write_text(json.dumps(lock))
        with self.assertRaisesRegex(ValueError, 'manifest and lock'):
            MODULE.assemble_npm(source, self.root / 'runtime', cache, True)
        lock['packages']['']['dependencies'] = {'fixture': '1.0.0'}
        (source / 'package-lock.json').write_text(json.dumps(lock))
        (cache / digest.hex()).write_bytes(b'corrupt')
        with self.assertRaisesRegex(ValueError, 'checksum'):
            MODULE.assemble_npm(source, self.root / 'runtime', cache, True)

    def test_application_source_list_rejects_traversal_and_links(self):
        source, cache, lock, digest = self.application(['../secret.txt'])
        with self.assertRaisesRegex(ValueError, 'Unsafe'):
            MODULE.copy_application(source, self.root / 'runtime')
        package = json.loads((source / 'package.json').read_text())
        package['files'] = ['linked.mjs']
        (source / 'package.json').write_text(json.dumps(package))
        (source / 'linked.mjs').symlink_to(source / 'runtime.mjs')
        with self.assertRaisesRegex(ValueError, 'Invalid application'):
            MODULE.copy_application(source, self.root / 'runtime')

    def test_manifest_seal_rejects_consistent_but_unapproved_inventory(self):
        runtime = self.root / 'runtime'
        runtime.mkdir()
        (runtime / 'agent').write_bytes(b'original')
        manifest = runtime / 'manifest.json'
        manifest.write_text(json.dumps({'files': MODULE.validate_tree(runtime)}))
        seal = MODULE.file_hash(manifest).hex()
        MODULE.verify(runtime, seal)
        (runtime / 'agent').write_bytes(b'changed')
        manifest.write_text(json.dumps({'files': [{'path': 'agent', 'sha256': MODULE.file_hash(runtime / 'agent').hex()}]}))
        with self.assertRaisesRegex(ValueError, 'seal mismatch'):
            MODULE.verify(runtime, seal)


if __name__ == '__main__':
    unittest.main()
