#!/usr/bin/env python3
"""Build the offline Linux x64 runtime and its release-pinned installer."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from importlib import import_module
win = import_module('package-win')

ROOT = Path(__file__).resolve().parents[1]
NODE_VERSION = win.NODE_VERSION
NODE_ARCHIVE = f'node-v{NODE_VERSION}-linux-x64.tar.xz'
NODE_SHA256 = '9aa8e9d2298ab68c600bd6fb86a6c13bce11a4eca1ba9b39d79fa021755d7c37'
ARCHIVE = 'opencu-linux-x64.tar.gz'
PROJECT_FILES = (
    'package.json', 'LICENSE', 'bin/opencu', 'src/server.mjs', 'src/opencu-runtime.mjs',
    'src/tool-arguments.mjs', 'src/coordinate-state.mjs', 'src/agent-desktop.mjs', 'src/agent-desktop-mac.mjs',
    '.build/linux/opencu-engine',
)
NODE_FILES = ('.dependencies/node/bin/node', '.dependencies/node/LICENSE', '.dependencies/node/SHASUMS256.txt',
              '.dependencies/node/provenance.json')
EXECUTABLES = {'bin/opencu', '.build/linux/opencu-engine', '.dependencies/node/bin/node'}


def engine_sources(root):
    rust = [p.relative_to(root).as_posix() for p in (root / 'native-linux/src').rglob('*.rs')]
    return sorted(['native-linux/Cargo.toml', 'native-linux/Cargo.lock', 'native-win/Cargo.toml', 'scripts/build-linux.mjs',
                   'native-win/src/lib.rs', 'native-win/src/observation.rs', 'native-win/src/foreground.rs',
                   'native-win/src/locked_patterns.rs'] + rust)


def check_engine(root):
    engine = root / '.build/linux/opencu-engine'
    receipt = root / '.build/linux/engine-manifest.json'
    if not engine.is_file() or not receipt.is_file():
        raise ValueError('Linux engine/build manifest missing; run npm run build:linux first.')
    built = json.loads(receipt.read_text())
    package = json.loads((root / 'package.json').read_text())
    if built.get('target') != 'x86_64-unknown-linux-musl':
        raise ValueError('The release package needs the x86_64 engine; run npm run build:linux without OPENCU_LINUX_TARGET.')
    sources = engine_sources(root)
    if (built['executable_sha256'] != win.sha256(engine) or built['version'] != package['version'] or
            built['source_files'] != {name: win.sha256(root / name) for name in sources}):
        raise ValueError('Linux engine differs from current sources/version; run npm run build:linux.')
    return built


def prepare_node(stage, downloads):
    base = win.NODE_BASE
    sums = downloads / 'SHASUMS256.txt'
    win.download(f'{base}/SHASUMS256.txt', sums)
    official = {line.split()[1]: line.split()[0] for line in sums.read_text().splitlines() if line.strip()}
    if official.get(NODE_ARCHIVE) != NODE_SHA256:
        raise ValueError('Official SHASUMS256.txt differs from the pinned Node.js archive SHA-256.')
    archive = downloads / NODE_ARCHIVE
    win.download(f'{base}/{NODE_ARCHIVE}', archive)
    if win.sha256(archive) != NODE_SHA256:
        raise ValueError('Downloaded Node.js archive failed SHA-256 verification.')
    node = stage / '.dependencies/node'
    (node / 'bin').mkdir(parents=True)
    prefix = f'node-v{NODE_VERSION}-linux-x64/'
    with tarfile.open(archive) as bundle:
        for name in ('bin/node', 'LICENSE'):
            info = bundle.getmember(prefix + name)
            if not info.isfile():
                raise ValueError(f'Invalid Node archive member: {name}')
            with bundle.extractfile(info) as source, (node / name).open('wb') as dest:
                shutil.copyfileobj(source, dest)
    shutil.copyfile(sums, node / 'SHASUMS256.txt')
    provenance = {'version': NODE_VERSION, 'archive_url': f'{base}/{NODE_ARCHIVE}', 'archive_sha256': NODE_SHA256,
                  'checksums_url': f'{base}/SHASUMS256.txt',
                  'files': {name: win.sha256(node / name) for name in ('bin/node', 'LICENSE', 'SHASUMS256.txt')}}
    (node / 'provenance.json').write_text(json.dumps(provenance, indent=2) + '\n')


def zig_lib_dir():
    env = subprocess.check_output(['zig', 'env'], text=True)
    match = re.search(r'\.lib_dir = "([^"]+)"', env) or re.search(r'"lib_dir":\s*"([^"]+)"', env)
    if not match:
        raise ValueError('Cannot find the zig library directory for the musl license.')
    return Path(match.group(1))


def copy_licenses(stage, deps, packages, root):
    notices = ['OpenCU third-party components', '',
               'Node.js: official distribution; license and bundled component notices in .dependencies/node/LICENSE.',
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
        files = win.license_files(directory)
        if not files:
            raise ValueError(f'Missing npm license: {name}')
        for file in files:
            copy(file, 'third-party/npm/' + name.removeprefix('node_modules/') + '/' + file.relative_to(directory).as_posix())
        notices.append(f'{name}: {packages[name]["version"]}')
    metadata = json.loads(subprocess.check_output([
        'cargo', 'metadata', '--locked', '--offline', '--format-version', '1', '--filter-platform', 'x86_64-unknown-linux-musl',
        '--manifest-path', str(root / 'native-linux/Cargo.toml')], text=True, cwd=root))
    used = {node['id'] for node in metadata['resolve']['nodes']}
    notices += ['', 'Rust dependencies (including build dependencies):']
    for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
        if package['name'] in ('opencu-engine', 'opencu-engine-linux') or package['id'] not in used:
            continue
        directory = Path(package['manifest_path']).parent
        files = win.license_files(directory)
        if not files:
            raise ValueError(f'Missing Rust license: {package["name"]}')
        for file in files:
            copy(file, f'third-party/rust/{package["name"]}-{package["version"]}/' + file.relative_to(directory).as_posix())
        notices.append(f'{package["name"]} {package["version"]}: {package["license"]}')
    sysroot = Path(subprocess.check_output(['rustc', '--print', 'sysroot'], text=True, cwd=root).strip())
    copy(sysroot / 'share/doc/rust/COPYRIGHT-library.html', 'third-party/rust-std/COPYRIGHT.html')
    copy(zig_lib_dir() / 'libc/musl/COPYRIGHT', 'third-party/musl/COPYRIGHT')
    notices += ['', 'Rust standard library: third-party/rust-std/COPYRIGHT.html',
                'musl libc (statically linked): third-party/musl/COPYRIGHT']
    (stage / 'THIRD-PARTY-NOTICES.txt').write_text('\n'.join(notices) + '\n')
    return licenses | {'THIRD-PARTY-NOTICES.txt'}


def write_archive(stage, output, allowed):
    actual = {p.relative_to(stage).as_posix() for p in stage.rglob('*') if p.is_file() and not p.is_symlink()}
    if any(p.is_symlink() for p in stage.rglob('*')):
        raise ValueError('Symlink in package')
    if actual != set(allowed):
        raise ValueError(f'Package allow-list mismatch: extra={sorted(actual - set(allowed))}, missing={sorted(set(allowed) - actual)}')
    def info(name):
        entry = tarfile.TarInfo(name)
        data = (stage / name).read_bytes()
        entry.size, entry.mtime, entry.uid, entry.gid, entry.uname, entry.gname = len(data), 315532800, 0, 0, '', ''
        entry.mode = 0o755 if name in EXECUTABLES else 0o644
        return entry, data
    import gzip, io
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode='w', format=tarfile.PAX_FORMAT) as bundle:
        for name in sorted(allowed):
            if '..' in Path(name).parts or name.startswith('/'):
                raise ValueError(f'Unsafe archive name: {name}')
            entry, data = info(name)
            bundle.addfile(entry, io.BytesIO(data))
    with output.open('wb') as file, gzip.GzipFile(filename='', mode='wb', fileobj=file, mtime=0, compresslevel=9) as zipped:
        zipped.write(raw.getvalue())


def render_installer(template, version, checksum):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[0-9a-f]{64}', checksum):
        raise ValueError('Invalid release version or SHA-256')
    values = {'VERSION': version, 'SHA256': checksum,
              'ASSET_URL': f'https://github.com/Daily-AC/opencu/releases/download/v{version}/{ARCHIVE}'}
    for key, value in values.items():
        if template.count(f'@@{key}@@') != 1:
            raise ValueError(f'Expected exactly one {key} placeholder')
        template = template.replace(f'@@{key}@@', value)
    if '@@' in template or not template.isascii():
        raise ValueError('Installer must be fully rendered ASCII')
    return template


def main():
    built = check_engine(ROOT)
    version = built['version']
    dist = ROOT / 'dist'
    dist.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.linux-package-', dir=dist) as temporary:
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
        subprocess.run(['npm', 'ci', '--ignore-scripts', '--omit=dev', '--no-audit', '--no-fund'], cwd=deps, check=True)
        packages = win.production_packages(json.loads((ROOT / 'package-lock.json').read_text()))
        files = win.dependency_files(deps, packages)
        for name in sorted(files):
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(deps / name, target)
        licenses = copy_licenses(stage, deps, packages, ROOT)
        allowed = set(PROJECT_FILES) | set(NODE_FILES) | files | licenses
        if check_engine(ROOT) != built:
            raise ValueError('Engine changed during packaging; build again.')
        archive = temp / ARCHIVE
        write_archive(stage, archive, allowed)
        checksum = win.sha256(archive)
        installer = render_installer((ROOT / 'scripts/install-linux.sh.template').read_text(), version, checksum)
        (temp / 'install.sh').write_bytes(installer.encode('ascii'))
        (temp / (ARCHIVE + '.sha256')).write_text(f'{checksum}  {ARCHIVE}\n')
        for name in (ARCHIVE, ARCHIVE + '.sha256', 'install.sh'):
            (temp / name).replace(dist / name)
    print(f'{ARCHIVE} {checksum}')


if __name__ == '__main__':
    main()
