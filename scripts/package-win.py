#!/usr/bin/env python3
"""Build the unsigned, offline Windows x64 runtime and release-pinned installer."""
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
NODE_VERSION = '22.22.0'
NODE_ARCHIVE = f'node-v{NODE_VERSION}-win-x64.zip'
NODE_BASE = f'https://nodejs.org/dist/v{NODE_VERSION}'
NODE_SHA256 = 'c97fa376d2becdc8863fcd3ca2dd9a83a9f3468ee7ccf7a6d076ec66a645c77a'
# Project files are enumerated, never copied from the checkout recursively.
PROJECT_FILES = (
    'package.json', 'LICENSE', 'bin/opencu.cmd',
    'scripts/opencu-win.mjs', 'src/server.mjs', 'src/opencu-runtime.mjs',
    'src/tool-arguments.mjs', 'src/coordinate-state.mjs', '.build/win/opencu-engine.exe',
    'src/agent-desktop.mjs', 'scripts/agent-desktop/Host.cs', 'scripts/agent-desktop/setup.ps1',
)
NODE_FILES = ('node/node.exe', 'node/LICENSE', 'node/SHASUMS256.txt', 'node/provenance.json')


def sha256(file):
    with Path(file).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def engine_sources(root):
    return sorted(['native-win/Cargo.toml', 'native-win/Cargo.lock', 'scripts/build-win.mjs'] +
                  [p.relative_to(root).as_posix() for p in (root / 'native-win/src').rglob('*.rs')])


def check_engine(root):
    engine = root / '.build/win/opencu-engine.exe'
    receipt = root / '.build/win/engine-manifest.json'
    if not engine.is_file() or not receipt.is_file():
        raise ValueError('Windows engine/build manifest missing; run npm run build:win first.')
    sources = engine_sources(root)
    if any((root / name).stat().st_mtime_ns > engine.stat().st_mtime_ns for name in sources):
        raise ValueError('Windows engine is older than its sources; run npm run build:win.')
    built = json.loads(receipt.read_text())
    package = json.loads((root / 'package.json').read_text())
    if (built['executable_sha256'] != sha256(engine) or built['version'] != package['version'] or
            built['source_files'] != {name: sha256(root / name) for name in sources}):
        raise ValueError('Windows engine differs from current sources/version; run npm run build:win.')
    return built


def render_installer(template, version, checksum):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[0-9a-f]{64}', checksum):
        raise ValueError('Invalid release version or SHA-256')
    replacements = {'VERSION': version, 'SHA256': checksum,
                    'ASSET_URL': f'https://github.com/Daily-AC/opencu/releases/download/v{version}/opencu-win-x64.zip',
                    'MANIFEST_JSON': json.dumps({'name': 'opencu', 'version': version, 'platform': 'win32',
                        'mcp': {'command': r'node\node.exe', 'args': [r'src\server.mjs']}}, separators=(',', ':'))}
    for key, value in replacements.items():
        if template.count(f'@@{key}@@') != 1:
            raise ValueError(f'Expected exactly one {key} placeholder')
        template = template.replace(f'@@{key}@@', value)
    if '@@' in template or not template.isascii():
        raise ValueError('Installer must be fully rendered ASCII')
    return template


def download(url, destination):
    # No retries or offline fallback: a failed download stops this build.
    with urllib.request.urlopen(url, timeout=60) as response, destination.open('wb') as target:
        shutil.copyfileobj(response, target)


def prepare_node(stage, downloads):
    sums = downloads / 'SHASUMS256.txt'
    download(f'{NODE_BASE}/SHASUMS256.txt', sums)
    official = {line.split()[1]: line.split()[0] for line in sums.read_text().splitlines() if line.strip()}
    if official.get(NODE_ARCHIVE) != NODE_SHA256:
        raise ValueError('Official SHASUMS256.txt differs from the pinned Node.js archive SHA-256.')
    archive = downloads / NODE_ARCHIVE
    download(f'{NODE_BASE}/{NODE_ARCHIVE}', archive)
    if sha256(archive) != NODE_SHA256:
        raise ValueError('Downloaded Node.js archive failed SHA-256 verification.')
    node = stage / 'node'
    node.mkdir()
    with zipfile.ZipFile(archive) as bundle:
        for name in ('node.exe', 'LICENSE'):
            info = bundle.getinfo(f'node-v{NODE_VERSION}-win-x64/{name}')
            if info.is_dir():
                raise ValueError(f'Invalid Node archive member: {name}')
            with bundle.open(info) as source, (node / name).open('wb') as dest:
                shutil.copyfileobj(source, dest)
    shutil.copyfile(sums, node / 'SHASUMS256.txt')
    provenance = {'version': NODE_VERSION, 'archive_url': f'{NODE_BASE}/{NODE_ARCHIVE}',
                  'archive_sha256': NODE_SHA256, 'checksums_url': f'{NODE_BASE}/SHASUMS256.txt',
                  'files': {name: sha256(node / name) for name in ('node.exe', 'LICENSE', 'SHASUMS256.txt')}}
    (node / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')


def production_packages(lock):
    packages = {}
    for name, metadata in lock['packages'].items():
        if not name or metadata.get('dev'):
            continue
        parts = PurePosixPath(name).parts
        if (parts[0] != 'node_modules' or '..' in parts or '\\' in name or
                not metadata.get('resolved', '').startswith('https://registry.npmjs.org/') or
                not metadata.get('integrity', '').startswith('sha512-')):
            raise ValueError(f'Not a locked public npm package: {name}')
        packages[name] = metadata
    return packages


def dependency_files(deps, packages):
    allowed = set()
    for name, metadata in sorted(packages.items()):
        directory = deps / name
        if not directory.exists() and metadata.get('optional'):
            continue
        installed = json.loads((directory / 'package.json').read_text())
        if installed.get('version') != metadata['version']:
            raise ValueError(f'Dependency version mismatch: {name}')
        for base, dirs, files in os.walk(directory, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d != 'node_modules')
            if any((Path(base) / d).is_symlink() for d in dirs):
                raise ValueError(f'Symlink in dependency: {name}')
            for file in sorted(files):
                # TypeScript sources, typings and source maps are not loaded at runtime;
                # they double the file count and push paths toward MAX_PATH.
                if file.endswith(('.ts', '.mts', '.cts', '.map')):
                    continue
                path = Path(base) / file
                if path.is_symlink() or not path.is_file():
                    raise ValueError(f'Non-regular dependency file: {path}')
                allowed.add(path.relative_to(deps).as_posix())
    return allowed


def license_files(directory):
    return sorted(p for p in directory.rglob('*') if p.is_file() and
                  re.match(r'^(licen[cs]e|copying|notice|copyright)([.\-_]|$)', p.name, re.I))


def copy_licenses(stage, deps, packages, root):
    notices = ['OpenCU third-party components', '',
               'Node.js: official distribution; license and bundled component notices in node/LICENSE.',
               'npm packages: licenses below and in node_modules; versions locked by the build.', '']
    licenses = set()
    def copy(file, relative):
        target = stage / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(file, target)
        licenses.add(relative)
    for name in sorted(packages):
        directory = deps / name
        if not directory.exists():
            continue
        files = license_files(directory)
        if not files:
            raise ValueError(f'Missing npm license: {name}')
        for file in files:
            copy(file, 'third-party/npm/' + name.removeprefix('node_modules/') + '/' + file.relative_to(directory).as_posix())
        notices.append(f'{name}: {packages[name]["version"]}')
    metadata = json.loads(subprocess.check_output([
        'cargo', 'metadata', '--locked', '--offline', '--format-version', '1',
        '--manifest-path', str(root / 'native-win/Cargo.toml')], text=True, cwd=root))
    notices += ['', 'Rust dependencies (including build dependencies):']
    for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
        if package['name'] == 'opencu-engine':
            continue
        directory = Path(package['manifest_path']).parent
        files = license_files(directory)
        if not files:
            raise ValueError(f'Missing Rust license: {package["name"]}')
        for file in files:
            copy(file, f'third-party/rust/{package["name"]}-{package["version"]}/' + file.relative_to(directory).as_posix())
        notices.append(f'{package["name"]} {package["version"]}: {package["license"]}')
    sysroot = Path(subprocess.check_output(['rustc', '--print', 'sysroot'], text=True, cwd=root).strip())
    copy(sysroot / 'share/doc/rust/COPYRIGHT-library.html', 'third-party/rust-std/COPYRIGHT.html')
    linker = os.environ.get('CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER', 'x86_64-w64-mingw32-gcc')
    compiler = shutil.which(linker)
    if not compiler:
        raise ValueError('MinGW linker missing; cannot collect its runtime license.')
    # Homebrew places bin under a toolchain-x86_64 subdirectory of the prefix.
    prefix = Path(compiler).resolve().parent.parent
    mingw_license = next((p / 'COPYING' for p in (prefix, prefix.parent) if (p / 'COPYING').is_file()), None)
    if mingw_license is None:
        raise ValueError(f'MinGW runtime license missing under {prefix} or its parent')
    copy(mingw_license, 'third-party/mingw-w64/COPYING')
    notices += ['', 'Rust standard library: third-party/rust-std/COPYRIGHT.html',
                'MinGW-w64 runtime: third-party/mingw-w64/COPYING']
    (stage / 'THIRD-PARTY-NOTICES.txt').write_text('\n'.join(notices) + '\n')
    return licenses | {'THIRD-PARTY-NOTICES.txt'}


def write_archive(stage, output, allowed):
    actual = set()
    for p in stage.rglob('*'):
        if p.is_symlink():
            raise ValueError(f'Symlink in package: {p}')
        if p.is_file():
            actual.add(p.relative_to(stage).as_posix())
    if actual != set(allowed):
        raise ValueError(f'Package allow-list mismatch: extra={sorted(actual - set(allowed))}, missing={sorted(set(allowed) - actual)}')
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as bundle:
        for name in sorted(allowed):
            if '..' in PurePosixPath(name).parts or name.startswith('/') or '\\' in name:
                raise ValueError(f'Unsafe archive name: {name}')
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = (0o100755 if name == 'bin/opencu' else 0o100644) << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            bundle.writestr(entry, (stage / name).read_bytes())


def main():
    built = check_engine(ROOT)
    version = built['version']
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.win-package-', dir=dist) as temporary:
        temp = Path(temporary)
        stage, deps, downloads = (temp / name for name in ('stage', 'deps', 'downloads'))
        for directory in (stage, deps, downloads):
            directory.mkdir()
        prepare_node(stage, downloads)
        for name in PROJECT_FILES:
            source = ROOT / name
            if source.is_symlink() or not source.is_file():
                raise ValueError(f'Missing or non-regular project file: {name}')
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
        for name in ('package.json', 'package-lock.json'):
            shutil.copyfile(ROOT / name, deps / name)
        # Fresh install, not the development node_modules tree. Integrity is enforced by npm ci.
        subprocess.run(['npm.cmd' if os.name == 'nt' else 'npm', 'ci', '--ignore-scripts', '--omit=dev',
                        '--no-audit', '--no-fund'], cwd=deps, check=True)
        packages = production_packages(json.loads((ROOT / 'package-lock.json').read_text()))
        files = dependency_files(deps, packages)
        for name in sorted(files):
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(deps / name, target)
        licenses = copy_licenses(stage, deps, packages, ROOT)
        allowed = set(PROJECT_FILES) | set(NODE_FILES) | files | licenses
        # Refuse edits/rebuilds during packaging as well.
        if check_engine(ROOT) != built:
            raise ValueError('Engine changed during packaging; build again.')
        archive = temp / 'opencu-win-x64.zip'
        write_archive(stage, archive, allowed)
        checksum = sha256(archive)
        installer = render_installer((ROOT / 'scripts/install-win.ps1.template').read_text(), version, checksum)
        (temp / 'install.ps1').write_bytes(installer.encode('ascii'))
        (temp / (archive.name + '.sha256')).write_text(f'{checksum}  {archive.name}\n')
        for name in (archive.name, archive.name + '.sha256', 'install.ps1'):
            (temp / name).replace(dist / name)
        print(json.dumps({'archive': str(dist / archive.name), 'sha256': checksum, 'version': version,
                          'node': NODE_VERSION, 'files': len(allowed), 'production_packages': len(packages)}, indent=2))


if __name__ == '__main__':
    main()
