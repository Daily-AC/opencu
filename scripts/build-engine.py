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
    files = [NATIVE / "Package.swift", *sorted(path for path in (NATIVE / "Resources").rglob("*") if path.is_file()), NATIVE / "Artwork/AppIcon-1024.png",
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


def sign(app, leaf, password, keychain=KEYCHAIN):
    subprocess.run(["security", "unlock-keychain", "-p", password, str(keychain)], check=True)
    listed = subprocess.run(["security", "list-keychains", "-d", "user"], check=True, capture_output=True, text=True).stdout
    search = [line.strip().strip('"') for line in listed.splitlines() if line.strip()]
    # codesign only selects an identity from the search list. Add the dedicated
    # keychain for this signature and restore the user's list afterwards.
    if str(keychain) not in search:
        subprocess.run(["security", "list-keychains", "-d", "user", "-s", *search, str(keychain)], check=True)
    try:
        subprocess.run([
            "codesign", "--force", "--keychain", str(keychain), "--sign", leaf, "--identifier", BUNDLE_ID,
            "--requirements", f"={requirement(leaf)}", "--timestamp=none", str(app),
        ], check=True)
    finally:
        subprocess.run(["security", "list-keychains", "-d", "user", "-s", *search], check=True)


class ReleaseIdentity:
    """The published package's certificate, given as OPENCU_RELEASE_P12 and OPENCU_RELEASE_P12_PASSWORD.

    Every user's Accessibility and Screen Recording grant is pinned to this certificate's leaf, so every
    npm release must be signed with the same one. It lives only in a throwaway keychain for one signature.
    """

    def __init__(self, p12, password):
        self.p12, self.password = pathlib.Path(p12), password
        self.temporary = tempfile.TemporaryDirectory(prefix="opencu-release-signing-")
        self.keychain = pathlib.Path(self.temporary.name) / "release.keychain-db"
        self.keychain_password = secrets.token_hex(24)

    def __enter__(self):
        area = pathlib.Path(self.temporary.name)
        environment = {**os.environ, "OPENCU_IN": self.password, "OPENCU_TRANSFER": secrets.token_hex(16)}
        certificate = area / "certificate.pem"
        subprocess.run([OPENSSL, "pkcs12", "-in", str(self.p12), "-passin", "env:OPENCU_IN", "-nokeys", "-clcerts",
                        "-out", str(certificate)], check=True, env=environment, capture_output=True)
        der = subprocess.run([OPENSSL, "x509", "-in", str(certificate), "-outform", "DER"], check=True, capture_output=True).stdout
        self.leaf = hashlib.sha1(der).hexdigest()
        # Re-wrap with a one-time password so the release password never appears in an argument list.
        both = area / "identity.pem"
        transfer = area / "identity.p12"
        subprocess.run([OPENSSL, "pkcs12", "-in", str(self.p12), "-passin", "env:OPENCU_IN", "-nodes", "-out", str(both)],
                       check=True, env=environment, capture_output=True)
        subprocess.run([OPENSSL, "pkcs12", "-export", "-in", str(both), "-out", str(transfer), "-passout", "env:OPENCU_TRANSFER"],
                       check=True, env=environment, capture_output=True)
        both.unlink()
        subprocess.run(["security", "create-keychain", "-p", self.keychain_password, str(self.keychain)], check=True)
        subprocess.run(["security", "set-keychain-settings", str(self.keychain)], check=True)
        subprocess.run(["security", "import", str(transfer), "-k", str(self.keychain), "-P", environment["OPENCU_TRANSFER"],
                        "-T", "/usr/bin/codesign"], check=True, capture_output=True)
        transfer.unlink()
        subprocess.run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s",
                        "-k", self.keychain_password, str(self.keychain)], check=True, capture_output=True)
        return self

    def __exit__(self, *_):
        subprocess.run(["security", "delete-keychain", str(self.keychain)], capture_output=True)
        self.temporary.cleanup()


def release_identity():
    p12, password = os.environ.get("OPENCU_RELEASE_P12"), os.environ.get("OPENCU_RELEASE_P12_PASSWORD")
    if bool(p12) != bool(password):
        raise SystemExit("Set both OPENCU_RELEASE_P12 and OPENCU_RELEASE_P12_PASSWORD, or neither.")
    return ReleaseIdentity(p12, password) if p12 else None


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("OpenCU currently builds for macOS arm64 (macOS 14 or later).")
    source_hashes = sources()
    release = release_identity()
    leaf, password = (None, None) if release else signing_identity()
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
        if release:
            with release:
                leaf = release.leaf
                sign(app, leaf, release.keychain_password, release.keychain)
        else:
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
            "signature": ("OpenCU release identity" if release else "local OpenCU signing identity") + "; strict verification passed",
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
    print(json.dumps({"app": str(destination), "version": engine_version, "sha256": manifest["executable_sha256"],
                      "signature": ("release" if release else "local") + " identity verified", "leaf": leaf}))


if __name__ == "__main__":
    main()
