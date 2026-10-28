#!/usr/bin/env python3
"""Stage and pack the macOS npm package from a release-signed build; never publishes.

Build first with the release identity (OPENCU_RELEASE_P12 and OPENCU_RELEASE_P12_PASSWORD set), then:
  python3 scripts/package-npm.py            -> dist/npm/opencu-<version>.tgz
npm installs carry no quarantine attribute, so the self-signed app runs; grants survive upgrades only
while every release is signed with the same certificate (RELEASE_LEAF).
"""
import json
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
# SHA-1 of the release certificate (FILES_OPENCU_RELEASE_SIGNING in the vault, created 2026-10-28).
RELEASE_LEAF = "39ea47165e18879da6b5eb3dfe5a8440705c7f99"
STAGE = ROOT / ".build/npm-stage"
OUT = ROOT / "dist/npm"


def main():
    app = ROOT / ".build/OpenCU.app"
    requirement = subprocess.run(["codesign", "-d", "-r-", str(app)], check=True, capture_output=True, text=True).stdout
    if f'certificate leaf = H"{RELEASE_LEAF}"' not in requirement:
        raise SystemExit("The engine is not signed with the OpenCU release certificate. Build with OPENCU_RELEASE_P12 set.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    root = json.loads((ROOT / "package.json").read_text())
    manifest = json.loads((ROOT / ".build/engine-manifest.json").read_text())
    if manifest["version"] != root["version"]:
        raise SystemExit(f"Engine {manifest['version']} does not match package.json {root['version']}; rebuild.")

    if STAGE.exists():
        shutil.rmtree(STAGE)
    (STAGE / ".build").mkdir(parents=True)
    shutil.copytree(ROOT / "bin", STAGE / "bin", ignore=shutil.ignore_patterns("*.cmd"))
    shutil.copytree(ROOT / "src", STAGE / "src")
    shutil.copytree(app, STAGE / ".build/OpenCU.app", symlinks=True)
    shutil.copy2(ROOT / ".build/engine-manifest.json", STAGE / ".build/engine-manifest.json")
    for name in ["LICENSE", "README.md"]:
        shutil.copy2(ROOT / name, STAGE / name)
    package = {
        "name": root["name"], "version": root["version"], "description": root["description"],
        "type": "module", "license": root["license"],
        "bin": {"opencu": "bin/opencu"},
        "dependencies": root["dependencies"], "engines": root["engines"],
        "os": ["darwin"], "cpu": ["arm64"],
        "files": ["bin/opencu", "src/", ".build/OpenCU.app/", ".build/engine-manifest.json"],
        "mcpName": "io.github.Daily-AC/opencu",
        "repository": {"type": "git", "url": "git+https://github.com/Daily-AC/opencu.git"},
        "homepage": "https://github.com/Daily-AC/opencu#readme",
        "bugs": {"url": "https://github.com/Daily-AC/opencu/issues"},
        "keywords": ["mcp", "mcp-server", "computer-use", "macos", "accessibility", "ai-agents", "desktop-automation"],
    }
    (STAGE / "package.json").write_text(json.dumps(package, indent=2) + "\n")
    OUT.mkdir(parents=True, exist_ok=True)
    packed = subprocess.run(["npm", "pack", "--json", "--pack-destination", str(OUT)], cwd=STAGE, check=True,
                            capture_output=True, text=True).stdout
    info = json.loads(packed)[0]
    print(json.dumps({"tarball": str(OUT / info["filename"]), "size": info["size"], "files": info["entryCount"],
                      "integrity": info["integrity"], "leaf": RELEASE_LEAF}))


if __name__ == "__main__":
    main()
