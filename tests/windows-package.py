"""Offline packaging checks; called by npm test. No downloads or installers run."""
import importlib.util
import json
import ntpath
import os
from pathlib import Path
import re
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('package_win', ROOT / 'scripts/package-win.py')
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)


class PackageTests(unittest.TestCase):
    def test_installer_embeds_release_hash_url_and_host_manifest(self):
        checksum = '1234567890abcdef' * 4
        script = pack.render_installer((ROOT / 'scripts/install-win.ps1.template').read_text(), '3.2.1', checksum)
        self.assertTrue(script.isascii())
        self.assertNotIn('@@', script)
        self.assertIn(f"$expectedHash = '{checksum}'", script)
        self.assertIn('/releases/download/v3.2.1/opencu-win-x64.zip', script)
        manifest = json.loads(re.search(r"\$manifest = '([^']+)' \| ConvertFrom-Json", script)[1])
        root = r'C:\Users\Fixture name\AppData\Local\OpenCU'
        manifest['mcp']['command'] = ntpath.join(root, manifest['mcp']['command'])
        manifest['mcp']['args'] = [ntpath.join(root, arg) for arg in manifest['mcp']['args']]
        contract = (ROOT / 'docs/host-integration.md').read_text()
        example = json.loads(re.search(r'```json\n(.*?)\n```', contract, re.S)[1])
        self.assertEqual(manifest, {**example, 'version': '3.2.1', 'mcp': {
            'command': root + r'\node\node.exe', 'args': [root + r'\src\server.mjs']}})
        # No interpreter termination anywhere in executable installer statements.
        self.assertNotRegex('\n'.join(l for l in script.splitlines() if not l.lstrip().startswith('#')), r'(?im)(?:^|[;{}])\s*exit\b')
        self.assertIn('Text.UTF8Encoding($false)', script)
        self.assertIn('[Net.SecurityProtocolType]::Tls12', script)
        self.assertLess(script.index('if ($actualHash -ne $expectedHash)'), script.index('Expand-Archive'))
        self.assertLess(script.index('[IO.Directory]::Move($stage, $install)'), script.index('[IO.File]::Move($manifestTemp, $manifestPath)'))

    def test_installer_rejects_invalid_release_values_and_non_ascii(self):
        template = (ROOT / 'scripts/install-win.ps1.template').read_text()
        for version, checksum in [('1.2.3', 'bad'), ("1.2.3'; throw 'bad", 'a'*64)]:
            with self.assertRaises(ValueError):
                pack.render_installer(template, version, checksum)
        with self.assertRaises(ValueError):
            pack.render_installer(template + '\n# Non-ASCII: \u4e2d', '1.2.3', 'a'*64)
        with self.assertRaises(ValueError):
            pack.render_installer(template.replace('@@SHA256@@', ''), '1.2.3', 'a'*64)

    def test_archive_allow_list_and_deterministic_order(self):
        with tempfile.TemporaryDirectory(dir=ROOT / '.cache') as tmp:
            root = Path(tmp); stage = root / 'stage'; stage.mkdir()
            (stage / 'z.txt').write_text('last'); (stage / 'a.txt').write_text('first')
            allowed = {'z.txt', 'a.txt'}
            first, second = root / 'one.zip', root / 'two.zip'
            pack.write_archive(stage, first, allowed)
            os.utime(stage / 'a.txt', (1700000000, 1700000000))
            pack.write_archive(stage, second, allowed)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            with zipfile.ZipFile(first) as archive:
                self.assertEqual(archive.namelist(), ['a.txt', 'z.txt'])
            (stage / 'private-token').write_text('fixture-only')
            with self.assertRaisesRegex(ValueError, 'allow-list'):
                pack.write_archive(stage, second, allowed)
            (stage / 'private-token').unlink(); (stage / 'a.txt').unlink()
            with self.assertRaisesRegex(ValueError, 'allow-list'):
                pack.write_archive(stage, second, allowed)
            (stage / 'a.txt').symlink_to(stage / 'z.txt')
            with self.assertRaisesRegex(ValueError, 'Symlink'):
                pack.write_archive(stage, second, allowed)

    def test_only_locked_production_dependencies_are_collected(self):
        metadata = {'version': '1', 'resolved': 'https://registry.npmjs.org/fixture/-/fixture-1.tgz', 'integrity': 'sha512-fixture'}
        lock = {'packages': {'': {}, 'node_modules/production': metadata,
                'node_modules/development': {**metadata, 'dev': True}}}
        packages = pack.production_packages(lock)
        self.assertEqual(list(packages), ['node_modules/production'])
        with tempfile.TemporaryDirectory(dir=ROOT / '.cache') as tmp:
            root = Path(tmp)
            for name in ('production', 'development', 'production/node_modules/unlisted'):
                folder = root / 'node_modules' / name; folder.mkdir(parents=True)
                (folder / 'package.json').write_text('{"version":"1"}')
            self.assertEqual(pack.dependency_files(root, packages), {'node_modules/production/package.json'})
        lock['packages']['node_modules/private'] = {**metadata, 'resolved': 'file:../private'}
        with self.assertRaises(ValueError):
            pack.production_packages(lock)

    def test_engine_missing_stale_tampered_or_wrong_version_is_refused(self):
        with tempfile.TemporaryDirectory(dir=ROOT / '.cache') as tmp:
            root = Path(tmp)
            with self.assertRaisesRegex(ValueError, 'missing'):
                pack.check_engine(root)
            sources = ['native-win/Cargo.toml', 'native-win/Cargo.lock', 'scripts/build-win.mjs', 'native-win/src/main.rs']
            for name in sources:
                p = root / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('fixture source')
                os.utime(p, ns=(1_000_000_000, 1_000_000_000))
            (root / 'package.json').write_text('{"version":"0.3.1"}')
            engine = root / '.build/win/opencu-engine.exe'; engine.parent.mkdir(parents=True)
            engine.write_bytes(b'fixture'); os.utime(engine, ns=(2_000_000_000, 2_000_000_000))
            receipt = root / '.build/win/engine-manifest.json'
            manifest = {'version': '0.3.1', 'executable_sha256': pack.sha256(engine),
                        'source_files': {name: pack.sha256(root / name) for name in sources}}
            receipt.write_text(json.dumps(manifest)); self.assertEqual(pack.check_engine(root), manifest)
            os.utime(root / sources[0], ns=(3_000_000_000, 3_000_000_000))
            with self.assertRaisesRegex(ValueError, 'older'):
                pack.check_engine(root)
            os.utime(root / sources[0], ns=(1_000_000_000, 1_000_000_000))
            (root / sources[0]).write_text('different'); os.utime(root / sources[0], ns=(1_000_000_000, 1_000_000_000))
            with self.assertRaisesRegex(ValueError, 'differs'):
                pack.check_engine(root)
            (root / sources[0]).write_text('fixture source'); os.utime(root / sources[0], ns=(1_000_000_000, 1_000_000_000))
            engine.write_bytes(b'tampered'); os.utime(engine, ns=(2_000_000_000, 2_000_000_000))
            with self.assertRaisesRegex(ValueError, 'differs'):
                pack.check_engine(root)
            engine.write_bytes(b'fixture'); os.utime(engine, ns=(2_000_000_000, 2_000_000_000))
            (root / 'package.json').write_text('{"version":"99.0.0"}')
            with self.assertRaisesRegex(ValueError, 'differs'):
                pack.check_engine(root)

    def test_project_allow_list_contains_runtime_only_and_all_runtime_sources(self):
        self.assertEqual({p.relative_to(ROOT).as_posix() for p in (ROOT / 'src').glob('*.mjs')},
                         {p for p in pack.PROJECT_FILES if p.startswith('src/')})
        for name in pack.PROJECT_FILES:
            self.assertTrue((ROOT / name).is_file() or name == '.build/win/opencu-engine.exe')
            self.assertFalse(any(part in {'.git', '.cache', 'tests', 'native', 'native-win', 'adapters'} for part in Path(name).parts))
        self.assertIn('scripts/opencu-win.mjs', pack.PROJECT_FILES)
        self.assertIn('node/LICENSE', pack.NODE_FILES)


if __name__ == '__main__':
    (ROOT / '.cache').mkdir(exist_ok=True)
    unittest.main()
