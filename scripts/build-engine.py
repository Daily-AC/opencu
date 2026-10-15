#!/usr/bin/env python3
"""Build and sign OpenCU's original macOS engine without opening its UI."""

import argparse
import datetime
import hashlib
import json
import os
import pathlib
import platform
import plistlib
import secrets
import shutil
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
NATIVE = ROOT / "native"
OUTPUT = ROOT / ".build"
BUNDLE_ID = "dev.opencu.engine"
# macOS keeps Accessibility and Screen Recording grants for code satisfying the
# designated requirement recorded at grant time. Pinning it to a private key keeps
# grants across rebuilds without letting any bundle with this identifier claim them.
SIGNING = pathlib.Path.home() / "Library/Application Support/OpenCU/signing"
KEYCHAIN = SIGNING / "opencu-signing.keychain-db"
KEYCHAIN_PASSWORD = SIGNING / "keychain-password"
CERTIFICATE = SIGNING / "certificate.pem"
OPENSSL = "/usr/bin/openssl"  # LibreSSL writes PKCS#12 that `security import` accepts.


def sha256(path):
    checksum = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def sources():
    files = [NATIVE / "Package.swift", *sorted(path for path in (NATIVE / "Resources").rglob("*") if path.is_file()),
             ROOT / "scripts/render-presence.py", ROOT / "scripts/render-presence.swift", *sorted((NATIVE / "Sources").rglob("*.swift"))]
    return {str(path.relative_to(ROOT)): sha256(path) for path in files}


def signing_identity():
    """Return this Mac's OpenCU certificate SHA-1 and keychain password, creating them once."""
    if not (KEYCHAIN.exists() and KEYCHAIN_PASSWORD.exists() and CERTIFICATE.exists()):
        if KEYCHAIN.exists():
            raise SystemExit(f"Incomplete OpenCU signing identity in {SIGNING}; remove that directory to create a new one.")
        SIGNING.mkdir(parents=True, exist_ok=True)
        SIGNING.chmod(0o700)
        password = secrets.token_hex(24)
        with tempfile.TemporaryDirectory(prefix="opencu-signing-") as temporary:
            key = pathlib.Path(temporary) / "key.pem"
            identity = pathlib.Path(temporary) / "identity.p12"
            environment = {**os.environ, "OPENCU_TRANSFER": secrets.token_hex(16)}
            subprocess.run([
                OPENSSL, "req", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "3650",
                "-subj", "/CN=OpenCU Local Code Signing", "-keyout", str(key), "-out", str(CERTIFICATE),
                "-addext", "basicConstraints=critical,CA:false", "-addext", "keyUsage=critical,digitalSignature",
                "-addext", "extendedKeyUsage=critical,codeSigning",
            ], check=True, capture_output=True)
            subprocess.run([OPENSSL, "pkcs12", "-export", "-inkey", str(key), "-in", str(CERTIFICATE),
                            "-out", str(identity), "-passout", "env:OPENCU_TRANSFER"], check=True, env=environment)
            subprocess.run(["security", "create-keychain", "-p", password, str(KEYCHAIN)], check=True)
            subprocess.run(["security", "set-keychain-settings", str(KEYCHAIN)], check=True)
            subprocess.run(["security", "import", str(identity), "-k", str(KEYCHAIN), "-P", environment["OPENCU_TRANSFER"],
                            "-T", "/usr/bin/codesign"], check=True, capture_output=True)
            subprocess.run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s",
                            "-k", password, str(KEYCHAIN)], check=True, capture_output=True)
        KEYCHAIN_PASSWORD.write_text(password)
        KEYCHAIN_PASSWORD.chmod(0o600)
    der = subprocess.run([OPENSSL, "x509", "-in", str(CERTIFICATE), "-outform", "DER"], check=True, capture_output=True).stdout
    return hashlib.sha1(der).hexdigest(), KEYCHAIN_PASSWORD.read_text().strip()


def requirement(leaf):
    return f'designated => identifier "{BUNDLE_ID}" and certificate leaf = H"{leaf}"'


def sign(app, leaf, password):
    subprocess.run(["security", "unlock-keychain", "-p", password, str(KEYCHAIN)], check=True)
    listed = subprocess.run(["security", "list-keychains", "-d", "user"], check=True, capture_output=True, text=True).stdout
    search = [line.strip().strip('"') for line in listed.splitlines() if line.strip()]
    # codesign only selects an identity from the search list. Add the dedicated
    # keychain for this signature and restore the user's list afterwards.
    if str(KEYCHAIN) not in search:
        subprocess.run(["security", "list-keychains", "-d", "user", "-s", *search, str(KEYCHAIN)], check=True)
    try:
        subprocess.run([
            "codesign", "--force", "--keychain", str(KEYCHAIN), "--sign", leaf, "--identifier", BUNDLE_ID,
            "--requirements", f"={requirement(leaf)}", "--timestamp=none", str(app),
        ], check=True)
    finally:
        subprocess.run(["security", "list-keychains", "-d", "user", "-s", *search], check=True)


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("OpenCU currently builds for macOS arm64 (macOS 14 or later).")
    source_hashes = sources()
    leaf, password = signing_identity()
    build = ["swift", "build", "--package-path", str(NATIVE), "-c", "release"]
    subprocess.run([*build, "--product", "opencu-engine"], check=True)
    binaries = pathlib.Path(subprocess.check_output([*build, "--show-bin-path"], text=True).strip())
    if sources() != source_hashes:
        raise SystemExit("Native sources changed during compilation; run the build again.")
    version = json.loads((ROOT / "package.json").read_text())["version"]
    OUTPUT.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".opencu-build-", dir=OUTPUT) as temporary:
        app = pathlib.Path(temporary) / "OpenCU.app"
        executable = app / "Contents/MacOS/opencu-engine"
        executable.parent.mkdir(parents=True)
        shutil.copy2(binaries / "opencu-engine", executable)
        with (NATIVE / "Resources/Info.plist").open("rb") as handle:
            info = plistlib.load(handle)
        info["CFBundleShortVersionString"] = version
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        resources = app / "Contents/Resources"
        shutil.copytree(NATIVE / "Resources", resources, ignore=shutil.ignore_patterns("Info.plist"))
        subprocess.run(["python3", str(ROOT / "scripts/render-presence.py"), "--icon", str(resources / "AppIcon.icns")], check=True)
        if sources() != source_hashes:
            raise SystemExit("Native resources changed during icon generation; run the build again.")
        sign(app, leaf, password)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        engine_version = subprocess.check_output([str(executable), "--version"], text=True, timeout=15).strip()
        if not engine_version:
            raise SystemExit("Built engine did not return its version.")
        manifest = {
            "schema_version": 1,
            "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "engine": "OpenCU", "version": version, "engine_version_output": engine_version,
            "platform": "darwin", "arch": "arm64", "minimum_macos": "14.0",
            "bundle_identifier": BUNDLE_ID,
            "app": ".build/OpenCU.app", "executable": ".build/OpenCU.app/Contents/MacOS/opencu-engine",
            "executable_sha256": sha256(executable), "executable_bytes": executable.stat().st_size,
            "signature": "local OpenCU signing identity; strict verification passed",
            "designated_requirement": requirement(leaf),
            "source": "Original Swift implementation using macOS frameworks and runtime-checked OS-exported SPI for targeted input, exact window identity and background operation",
            "macos_api_compatibility": "OS-exported SPI availability and behavior can vary across macOS releases",
            "source_files": source_hashes,
            "gui_opened": False, "permission_requests": False,
        }
        destination = OUTPUT / "OpenCU.app"
        if destination.is_symlink():
            raise SystemExit(f"Refusing to replace a symlink: {destination}")
        if destination.exists():
            shutil.rmtree(destination)
        app.rename(destination)
        (OUTPUT / "engine-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps({"app": str(destination), "version": engine_version,
                      "sha256": manifest["executable_sha256"], "signature": "local identity verified"}))


if __name__ == "__main__":
    main()
