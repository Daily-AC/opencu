#!/usr/bin/env python3
"""Generate OpenCU's original icon or offscreen presence review images; never show UI."""
import argparse
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--icon', type=Path, help='Write AppIcon.icns at this path')
    parser.add_argument('--output', type=Path, default=ROOT / '.cache/presence-review')
    args = parser.parse_args()
    cache = ROOT / '.cache'
    cache.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='presence-render-', dir=cache) as temporary:
        area = Path(temporary)
        sources = ROOT / 'native/Sources/OpenCU'
        executable = area / 'render-presence'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-target', f'{platform.machine()}-apple-macos14.0',
                        *[str(sources / name) for name in ['Types.swift', 'PresenceModel.swift', 'PresenceArtwork.swift',
                                                          'PermissionSetup.swift', 'PresenceController.swift']],
                        str(ROOT / 'scripts/render-presence.swift'), '-o', str(executable)], check=True)
        if args.icon:
            iconset = area / 'AppIcon.iconset'
            subprocess.run([str(executable), 'icon', str(iconset)], check=True)
            args.icon.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(args.icon)], check=True)
        else:
            subprocess.run([str(executable), 'review', str(args.output), str(ROOT / 'native/Resources')], check=True)
            print(args.output)

if __name__ == '__main__':
    main()
