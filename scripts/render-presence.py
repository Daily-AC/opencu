#!/usr/bin/env python3
"""Build AppIcon.icns from native/Artwork, or render offscreen presence review images; never show UI."""
import argparse
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ARTWORK = ROOT / 'native/Artwork/AppIcon-1024.png'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--icon', type=Path, help='Write AppIcon.icns at this path')
    parser.add_argument('--output', type=Path, default=ROOT / '.cache/presence-review')
    args = parser.parse_args()
    cache = ROOT / '.cache'
    cache.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='presence-render-', dir=cache) as temporary:
        area = Path(temporary)
        if args.icon:
            iconset = area / 'AppIcon.iconset'
            iconset.mkdir()
            for size in [16, 32, 128, 256, 512]:
                for scale in [1, 2]:
                    name = f'icon_{size}x{size}{"@2x" if scale == 2 else ""}.png'
                    subprocess.run(['sips', '-z', str(size * scale), str(size * scale), str(ARTWORK),
                                    '--out', str(iconset / name)], check=True, stdout=subprocess.DEVNULL)
            args.icon.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['iconutil', '-c', 'icns', str(iconset), '-o', str(args.icon)], check=True)
            return
        sources = ROOT / 'native/Sources/OpenCU'
        executable = area / 'render-presence'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-target', f'{platform.machine()}-apple-macos14.0',
                        *[str(sources / name) for name in ['Types.swift', 'PresenceModel.swift', 'PresenceArtwork.swift',
                                                          'PermissionSetup.swift', 'PresenceController.swift']],
                        str(ROOT / 'scripts/render-presence.swift'), '-o', str(executable)], check=True)
        subprocess.run([str(executable), 'review', str(args.output), str(ROOT / 'native/Resources'), str(ARTWORK)], check=True)
        print(args.output)

if __name__ == '__main__':
    main()
