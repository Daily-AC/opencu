#!/usr/bin/env python3
"""Package the independent OpenCU engine with verified public Node.js and MCP dependencies."""

import argparse
import datetime
import hashlib
import json
import pathlib
import platform
import plistlib
import runpy
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]
NODE_VERSION = "24.21.0"
NODE_ARCHIVE = f"node-v{NODE_VERSION}-darwin-arm64.tar.gz"
NODE_BASE = f"https://nodejs.org/dist/v{NODE_VERSION}"
NODE_ARCHIVE_SHA256 = "bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057"
NODE_BINARY_SHA256 = "e4b5a3af0e05c75de2eae013904145f40fe7fc2a6e6f17510128bf45cca4e79b"
NODE = ROOT / ".dependencies/node"
FORBIDDEN_PARTS = {".runtime", "@oai", "@openai", "openai", "CodexCLI.app", "cua_node", ".git", ".cache"}
SOURCE_FILES = [
    "scripts/render-presence.py", "scripts/render-presence.swift", "docs/independent-engine-contract.md",
    "AGENTS.md", "native/Package.swift", "scripts/build-engine.py", "scripts/package-opencu.py",
    "scripts/test-native.py", "scripts/verify-release.py", "scripts/verify-gui.mjs", "tests/native-logic.swift",
    "skills/opencu/SKILL.md", "docs/opencu-independent-2026-10-12.md",
    "evidence/opencu-independent-2026-10-12.json",
    "tests/fixtures/preview-window-response.json", "tests/fixtures/OpenCUFixture.swift",
]
RELEASE_RECEIPT = "evidence/opencu-release-2026-10-12.json"


def sha256(path):
    checksum = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def download(url, destination):
    with urllib.request.urlopen(url, timeout=60) as response, destination.open("wb") as handle:
        shutil.copyfileobj(response, handle)


def prepare_node():
    if NODE.exists():
        try:
            provenance = json.loads((NODE / "provenance.json").read_text())
            valid = (provenance["version"] == f"v{NODE_VERSION}"
                     and provenance["archive_url"] == f"{NODE_BASE}/{NODE_ARCHIVE}"
                     and provenance["archive_sha256"] == NODE_ARCHIVE_SHA256
                     and sha256(NODE / "bin/node") == NODE_BINARY_SHA256
                     and all(sha256(NODE / name) == value for name, value in provenance["files"].items())
                     and {"bin/node", "LICENSE", "SHASUMS256.txt"} <= provenance["files"].keys())
        except (OSError, ValueError, KeyError):
            valid = False
        if not valid:
            raise SystemExit("Node cache failed integrity checks; remove .dependencies/node and rerun --prepare-node.")
    else:
        NODE.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".node-download-", dir=NODE.parent) as temporary:
            staging = pathlib.Path(temporary)
            checksums = staging / "SHASUMS256.txt"
            download(f"{NODE_BASE}/SHASUMS256.txt", checksums)
            release_sums = {line.split()[1]: line.split()[0] for line in checksums.read_text().splitlines() if line.strip()}
            if release_sums.get(NODE_ARCHIVE) != NODE_ARCHIVE_SHA256:
                raise SystemExit("Official SHASUMS256.txt does not match the pinned Node.js archive hash.")
            archive = staging / NODE_ARCHIVE
            download(f"{NODE_BASE}/{NODE_ARCHIVE}", archive)
            if sha256(archive) != NODE_ARCHIVE_SHA256:
                raise SystemExit("Downloaded Node.js archive failed SHA-256 verification.")
            extracted = staging / "node"
            (extracted / "bin").mkdir(parents=True)
            prefix = NODE_ARCHIVE.removesuffix(".tar.gz")
            with tarfile.open(archive, "r:gz") as bundle:
                for name in ["bin/node", "LICENSE"]:
                    member = bundle.getmember(f"{prefix}/{name}")
                    if not member.isfile():
                        raise SystemExit(f"Unexpected Node.js archive entry: {name}")
                    with bundle.extractfile(member) as source, (extracted / name).open("wb") as target:
                        shutil.copyfileobj(source, target)
                    (extracted / name).chmod(0o755 if name == "bin/node" else 0o644)
            shutil.copy2(checksums, extracted / "SHASUMS256.txt")
            if sha256(extracted / "bin/node") != NODE_BINARY_SHA256:
                raise SystemExit("Extracted Node.js executable differs from the pinned official binary.")
            provenance = {
                "name": "Node.js", "version": f"v{NODE_VERSION}", "lts": "Krypton",
                "source": "Official unmodified nodejs.org release; no application-specific runtime",
                "archive_url": f"{NODE_BASE}/{NODE_ARCHIVE}", "archive_sha256": NODE_ARCHIVE_SHA256,
                "checksums_url": f"{NODE_BASE}/SHASUMS256.txt", "license": "LICENSE",
                "files": {name: sha256(extracted / name) for name in ["bin/node", "LICENSE", "SHASUMS256.txt"]},
            }
            (extracted / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
            version = subprocess.check_output([str(extracted / "bin/node"), "--version"], text=True, timeout=15).strip()
            if version != f"v{NODE_VERSION}":
                raise SystemExit("Extracted Node.js version does not match the verified release.")
            extracted.rename(NODE)
    version = subprocess.check_output([str(NODE / "bin/node"), "--version"], text=True, timeout=15).strip()
    if version != f"v{NODE_VERSION}":
        raise SystemExit("Cached Node.js binary returned an unexpected version.")
    return provenance


def copy_dependencies(destination):
    lock = json.loads((ROOT / "package-lock.json").read_text())
    packages = []
    for name, metadata in lock["packages"].items():
        if not name or metadata.get("dev", False):
            continue
        relative = pathlib.PurePosixPath(name)
        if (relative.parts[0] != "node_modules" or ".." in relative.parts
                or not metadata.get("resolved", "").startswith("https://registry.npmjs.org/")):
            raise SystemExit(f"Dependency is not a locked public npm package: {name}")
        source = ROOT / name
        if not source.exists() and metadata.get("optional", False):
            continue
        if not (source / "package.json").is_file():
            raise SystemExit(f"Dependency is missing; run npm ci before packaging: {name}")
        installed = json.loads((source / "package.json").read_text())
        if installed.get("version") != metadata["version"]:
            raise SystemExit(f"Dependency version differs from package-lock.json: {name}")
        packages.append(relative)
    copied = []
    for relative in sorted(packages, key=lambda path: (len(path.parts), str(path))):
        if any(relative.is_relative_to(parent) for parent in copied):
            continue
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(ROOT / relative, target, symlinks=True)
        copied.append(relative)
    return len(packages)


def inspect_contents(root):
    for path in root.rglob("*"):
        relative = path.relative_to(root)
        if FORBIDDEN_PARTS.intersection(relative.parts) or "-private." in path.name:
            raise SystemExit(f"Unexpected legacy or private package entry: {relative}")
        if path.is_symlink() and not path.resolve(strict=True).is_relative_to(root.resolve()):
            raise SystemExit(f"Package contains an external symlink: {relative}")


def archive_member(info):
    info.uid = info.gid = 0
    info.uname = info.gname = ""
    return info


def prepare_runtime_receipt(package_root):
    """Embed component-bound evidence; the containing archive's hash stays external."""
    verifier = runpy.run_path(str(ROOT / "scripts/verify-release.py"))
    fingerprints = verifier["runtime_fingerprints"](package_root)
    dependencies = verifier["dependency_fingerprint"](package_root)
    receipt = {
        "test": "independent-runtime-isolated-read-only",
        "binding": "Runtime component and dependency hashes only; this is not a receipt for the containing archive",
        "runtime_component_sha256": fingerprints,
        "node_modules_integrity": dependencies,
        "status": "pending", "ok": False,
        "reason": "No successful isolation receipt matches these runtime files and dependencies",
    }
    try:
        verified = json.loads((ROOT / RELEASE_RECEIPT).read_text())
    except (OSError, ValueError):
        verified = {}
    if (verified.get("ok") is True
            and verified.get("runtime_component_sha256") == fingerprints
            and verified.get("node_modules_integrity") == dependencies):
        receipt.update(status="verified", ok=True)
        receipt.pop("reason")
        # The observed candidate archive is provenance, never a claim about this
        # archive. Repacking documents cannot change the runtime-bound checks.
        receipt["source_verification"] = verified.get("source_verification") or {
            key: verified[key] for key in ["timestamp", "archive_sha256", "verifier_sha256", "host_macos_version", "arch"]
            if key in verified
        }
        for key in ["engine_sha256", "node_binary_sha256", "engine_version", "native_doctor",
                    "extracted_binary_hashes_match_manifest", "extracted_signatures_verified",
                    "home_started_empty", "source_repository_reads_denied", "network_connections_denied",
                    "additional_read_denials", "permission_status_not_used_as_standalone_authorization_evidence",
                    "mcp_initialized", "tool_count", "list_apps_called", "app_count",
                    "inventory_recorded", "gui_calls", "input_calls", "permission_requests"]:
            if key in verified:
                receipt[key] = verified[key]
    destination = package_root / RELEASE_RECEIPT
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare-node", action="store_true", help="Only download and verify the pinned public Node.js runtime")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("This release package is for macOS arm64 (macOS 14 or later).")
    node = prepare_node()
    if args.prepare_node:
        print(json.dumps({"node": str(NODE), **node}, indent=2))
        return
    app = ROOT / ".build/OpenCU.app"
    executable = app / "Contents/MacOS/opencu-engine"
    if not executable.is_file() or not (ROOT / ".build/engine-manifest.json").is_file():
        raise SystemExit("Build the original engine first: python3 scripts/build-engine.py")
    engine = json.loads((ROOT / ".build/engine-manifest.json").read_text())
    if sha256(executable) != engine["executable_sha256"]:
        raise SystemExit("Built engine hash differs from its build manifest; rebuild before packaging.")
    native_sources = [ROOT / "native/Package.swift", *sorted(path for path in (ROOT / "native/Resources").rglob("*") if path.is_file()),
                      ROOT / "scripts/render-presence.py", ROOT / "scripts/render-presence.swift",
                      *sorted((ROOT / "native/Sources").rglob("*.swift"))]
    source_hashes = {str(path.relative_to(ROOT)): sha256(path) for path in native_sources}
    if source_hashes != engine["source_files"]:
        raise SystemExit("Native sources changed since the build; rebuild before packaging.")
    package = json.loads((ROOT / "package.json").read_text())
    if package["name"] != "opencu" or package["version"] != engine["version"]:
        raise SystemExit("Package metadata must identify OpenCU and match the compiled engine version.")
    if not (ROOT / "README.md").read_text().lstrip().startswith("# OpenCU"):
        raise SystemExit("README must describe the independent OpenCU engine before creating a release archive.")
    tests = [str(path.relative_to(ROOT)) for path in sorted((ROOT / "tests").glob("*.test.mjs"))]
    source_files = [*SOURCE_FILES, *tests, ".build/engine-manifest.json"]
    for name in source_files:
        if not (ROOT / name).is_file():
            raise SystemExit(f"Required independent source or documentation is missing: {name}")
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info["CFBundleIdentifier"] != "dev.opencu.engine" or info["LSMinimumSystemVersion"] != "14.0":
        raise SystemExit("Unexpected engine bundle identity or minimum macOS version.")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    designated = subprocess.run(["codesign", "-d", "-r-", str(app)], check=True, capture_output=True, text=True)
    if 'certificate leaf = H"' not in designated.stdout + designated.stderr:
        raise SystemExit("The engine's designated requirement must pin its signing certificate; rebuild with scripts/build-engine.py.")
    output = ROOT / "dist/opencu-macos-arm64.tar.gz"
    output.parent.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".opencu-package-", dir=output.parent) as temporary:
        staging = pathlib.Path(temporary)
        package_root = staging / "opencu"
        package_root.mkdir()
        for name in ["bin/opencu", "package.json", "package-lock.json", "README.md", "LICENSE", *source_files]:
            target = package_root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        for name in ["native/Resources", "native/Sources"]:
            shutil.copytree(ROOT / name, package_root / name)
        (package_root / "src").mkdir()
        for source in sorted((ROOT / "src").glob("*.mjs")):
            if "@oai/" in source.read_text():
                raise SystemExit(f"Active sources still contain a legacy runtime dependency: {source.name}")
            shutil.copy2(source, package_root / "src" / source.name)
        shutil.copytree(app, package_root / ".build/OpenCU.app")
        for name in ["bin/node", "LICENSE", "SHASUMS256.txt", "provenance.json"]:
            target = package_root / ".dependencies/node" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(NODE / name, target)
        dependency_count = copy_dependencies(package_root)
        inspect_contents(package_root)
        for source in sorted((package_root / "src").glob("*.mjs")):
            subprocess.run([str(package_root / ".dependencies/node/bin/node"), "--check", str(source)], check=True)
        receipt = prepare_runtime_receipt(package_root)
        manifest = {
            "schema_version": 1, "name": "opencu", "version": package["version"],
            "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "platform": "darwin", "arch": "arm64", "minimum_macos": "14.0",
            "entrypoint": "bin/opencu", "compiler_required": False,
            "native_source_included": True, "build_script": "scripts/build-engine.py",
            "tests_included": tests,
            "engine": engine, "node": node, "public_npm_package_count": dependency_count,
            "package_lock_sha256": sha256(ROOT / "package-lock.json"),
            "source": "Independent OpenCU engine using macOS frameworks and runtime-checked OS-exported SPI; public npm MCP dependencies and the official Node.js release",
            "macos_api_compatibility": "OS-exported SPI availability and behavior can vary across macOS releases",
            "runtime_verification": {"path": RELEASE_RECEIPT, "status": receipt["status"], "binding": "runtime and dependency hashes"},
            "archive_verification": {"filename": output.name + ".verification.json",
                                     "delivery": "Alongside the archive; generated after packaging by scripts/verify-release.py",
                                     "binding": "archive_sha256; never embedded in the archive it verifies"},
            "account_data_included": False, "proprietary_runtime_included": False,
        }
        (package_root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        candidate = staging / output.name
        with tarfile.open(candidate, "w:gz", compresslevel=6) as archive:
            archive.add(package_root, arcname="opencu", filter=archive_member)
        with tarfile.open(candidate, "r:gz") as archive:
            names = set(archive.getnames())
            required = ["bin/opencu", "src/server.mjs", ".build/OpenCU.app/Contents/MacOS/opencu-engine",
                        ".dependencies/node/bin/node", ".dependencies/node/LICENSE", "manifest.json",
                        "native/Resources/Info.plist", "native/Sources/OpenCU/Main.swift", RELEASE_RECEIPT, *source_files]
            if not all(f"opencu/{name}" in names for name in required):
                raise SystemExit("Release archive is missing a required runtime component.")
            if any(FORBIDDEN_PARTS.intersection(pathlib.PurePosixPath(name).parts) for name in names):
                raise SystemExit("Release archive contains a forbidden legacy or private component.")
        candidate.replace(output)
    # A previous archive's sidecar must not look like verification of a new pack.
    sidecar = output.with_name(output.name + ".verification.json")
    if sidecar.exists():
        sidecar.unlink()
    summary = {"archive": output.name, "bytes": output.stat().st_size, "sha256": sha256(output),
               "version": package["version"], "minimum_macos": "14.0", "arch": "arm64",
               "compiler_required": False, "engine_sha256": engine["executable_sha256"],
               "node_archive_sha256": node["archive_sha256"], "proprietary_runtime_included": False,
               "runtime_verification": receipt["status"], "archive_verification": "pending",
               "verification_sidecar": sidecar.name}
    (output.parent / "opencu-manifest.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
