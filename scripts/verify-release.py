#!/usr/bin/env python3
"""Verify an extracted OpenCU release offline without GUI, input or permission requests."""

import argparse
import contextlib
import datetime
import hashlib
import json
import os
import pathlib
import platform
import pwd
import shutil
import signal
import socket
import stat
import subprocess
import tarfile
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
FORBIDDEN_PARTS = {".runtime", "@oai", "@openai", "openai", "CodexCLI.app", "cua_node", ".git", ".cache"}
FIXTURES = {"tests/fixtures/OpenCUFixture.swift", "tests/fixtures/preview-window-response.json"}
CONTROLLER = r"""import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
const settings = JSON.parse(process.argv[2]);
const transport = new StdioClientTransport({
  command: '/usr/bin/sandbox-exec', args: ['-p', settings.profile, settings.entry, 'mcp'],
  env: settings.env, cwd: settings.cwd, stderr: 'pipe',
});
transport.stderr?.on('data', () => {});
const client = new Client({ name: 'opencu-release-read-check', version: '1.0.0' }, { capabilities: {} });
let stage = 'initialize';
try {
  await client.connect(transport);
  stage = 'tools/list';
  const catalog = await client.listTools(undefined, { timeout: 15000 });
  if (!catalog.tools.some(tool => tool.name === 'list_apps')) throw new Error('Missing list_apps');
  stage = 'list_apps';
  const response = await client.callTool({ name: 'list_apps', arguments: {} }, undefined, { timeout: 15000 });
  if (response.isError) throw new Error('list_apps failed');
  const text = response.content.filter(item => item.type === 'text').map(item => item.text).join('\n');
  const apps = JSON.parse(text);
  if (!Array.isArray(apps) || apps.length === 0) throw new Error('Empty application inventory');
  // Never log or persist the returned application records, including on failure.
  console.log(JSON.stringify({ mcp_initialized: true, tool_count: catalog.tools.length,
    list_apps_called: true, app_count: apps.length, inventory_recorded: false }));
} catch {
  process.stderr.write(`OpenCU release check failed during ${stage}.\n`);
  process.exitCode = 1;
} finally {
  await client.close();
}
"""


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def sha256(path):
    checksum = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            checksum.update(block)
    return checksum.hexdigest()


def run(command, *, cwd, env=None, input=None, timeout=30):
    process = subprocess.Popen(command, cwd=cwd, env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    try:
        stdout, stderr = process.communicate(input, timeout=timeout)
    except subprocess.TimeoutExpired:
        # Terminate only this verifier's process group, including its MCP child.
        with contextlib.suppress(ProcessLookupError):
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        raise RuntimeError("Release verification subprocess timed out") from None
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def extract_release(archive, destination):
    """The release format contains ordinary files/directories, never links or devices."""
    with tarfile.open(archive, "r:gz") as bundle:
        members = bundle.getmembers()
        seen = set()
        fixtures = set()
        for member in members:
            path = pathlib.PurePosixPath(member.name)
            require(not path.is_absolute() and path.parts and path.parts[0] == "opencu"
                    and ".." not in path.parts and member.name not in seen,
                    "Release contains an unsafe or duplicate archive path")
            require(member.isfile() or member.isdir(), "Release contains a link or special file")
            require(not FORBIDDEN_PARTS.intersection(path.parts), "Release contains a legacy or private component")
            seen.add(member.name)
            if member.isfile() and member.name.startswith("opencu/tests/fixtures/"):
                fixtures.add(str(path.relative_to("opencu")))
        require(fixtures == FIXTURES, "Release fixtures differ from the independent allowlist")
        for member in members:
            target = destination / member.name
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(member) as source, target.open("wb") as handle:
                    shutil.copyfileobj(source, handle)
            target.chmod(member.mode & 0o777)
    return len(members), sorted(fixtures)


def runtime_fingerprints(package):
    paths = [package / name for name in ["bin/opencu", "package.json", "package-lock.json",
                                         ".dependencies/node/bin/node"]]
    paths.extend(path for path in (package / ".build/OpenCU.app").rglob("*") if path.is_file())
    paths.extend((package / "src").glob("*.mjs"))
    return {str(path.relative_to(package)): sha256(path) for path in sorted(paths)}


def dependency_fingerprint(package):
    inventory = [{"path": str(path.relative_to(package)), "sha256": sha256(path),
                  "bytes": path.stat().st_size, "mode": stat.S_IMODE(path.stat().st_mode)}
                 for path in sorted((package / "node_modules").rglob("*")) if path.is_file()]
    encoded = json.dumps(inventory, sort_keys=True, separators=(",", ":")).encode()
    return {"files": len(inventory), "tree_sha256": hashlib.sha256(encoded).hexdigest(),
            "format": "SHA-256 of compact sorted-key UTF-8 JSON; sorted file paths, SHA-256, size and mode"}


def verify(archive, evidence):
    with tempfile.TemporaryDirectory(prefix="opencu-release-check-") as temporary:
        area = pathlib.Path(temporary).resolve()
        package = area / "opencu"
        isolated_home, isolated_tmp = area / "empty-home", area / "tmp"
        isolated_home.mkdir()
        isolated_tmp.mkdir()
        entries, fixtures = extract_release(archive, area)
        evidence.update(archive_entries=entries, allowed_fixtures=fixtures)
        manifest = json.loads((package / "manifest.json").read_text())
        require(manifest["name"] == "opencu" and manifest["proprietary_runtime_included"] is False,
                "Release manifest does not describe the independent engine")
        evidence["native_sources_included"] = manifest["native_source_included"]
        fingerprints = runtime_fingerprints(package)
        evidence["runtime_component_sha256"] = fingerprints
        evidence["node_modules_integrity"] = dependency_fingerprint(package)
        receipt_info = manifest.get("runtime_verification")
        if receipt_info:
            embedded = json.loads((package / receipt_info["path"]).read_text())
            require(embedded["runtime_component_sha256"] == fingerprints
                    and embedded["node_modules_integrity"] == evidence["node_modules_integrity"],
                    "Embedded runtime receipt does not match the extracted runtime")
            evidence["embedded_runtime_receipt_status"] = embedded["status"]
        resources = package / ".build/OpenCU.app/Contents/Resources"
        for resource in ["AppIcon.icns", "en.lproj/Presence.strings", "zh-Hans.lproj/Presence.strings"]:
            require((resources / resource).is_file() and (resources / resource).stat().st_size > 0,
                    "Release is missing presence artwork or localizations")
        evidence["presence_resources_verified"] = True
        engine = package / ".build/OpenCU.app/Contents/MacOS/opencu-engine"
        node = package / ".dependencies/node/bin/node"
        evidence["engine_sha256"] = sha256(engine)
        evidence["node_binary_sha256"] = sha256(node)
        require(evidence["engine_sha256"] == manifest["engine"]["executable_sha256"]
                and evidence["node_binary_sha256"] == manifest["node"]["files"]["bin/node"],
                "Extracted binaries differ from the release manifest")
        evidence["extracted_binary_hashes_match_manifest"] = True
        for signed in [package / ".build/OpenCU.app", node]:
            checked = run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(signed)], cwd=area)
            require(checked.returncode == 0, "Extracted native signature verification failed")
        evidence["extracted_signatures_verified"] = True
        real_user_home = pathlib.Path(pwd.getpwuid(os.getuid()).pw_dir)
        denied = [ROOT, real_user_home / ".codex", real_user_home / ".agents",
                  pathlib.Path("/Applications/ChatGPT.app"), pathlib.Path("/Applications/Codex.app")]
        profile = "(version 1)\n(allow default)\n(deny network*)\n" + "\n".join(
            "(deny file-read* (subpath " + json.dumps(str(path)) + "))" for path in denied)
        sandbox = ["/usr/bin/sandbox-exec", "-p", profile]
        # Only the release child gets a disposable home directory. The controller
        # retains its original HOME; no user configuration is copied or changed.
        environment = {"HOME": str(isolated_home), "TMPDIR": str(isolated_tmp) + "/",
                       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"}
        evidence["home_started_empty"] = not any(isolated_home.iterdir())

        def isolated(arguments, **kwargs):
            return run([*sandbox, *map(str, arguments)], cwd=isolated_home, env=environment, **kwargs)

        read_probe = ('import fs from "node:fs";try{fs.readFileSync(process.argv[1]);process.exit(1)}'
                      'catch(e){process.exit(["EPERM","EACCES"].includes(e.code)?0:2)}')
        checked = isolated([node, "--input-type=module", "-e", read_probe, pathlib.Path(__file__).resolve()])
        require(checked.returncode == 0, "Sandbox did not reject reads from the controller's source directory")
        evidence["source_repository_reads_denied"] = True
        network_probe = ('import net from "node:net";const s=net.connect({host:"127.0.0.1",port:Number(process.argv[1])});'
                         's.on("connect",()=>{s.destroy();process.exit(1)});'
                         's.on("error",e=>process.exit(["EPERM","EACCES"].includes(e.code)?0:2));'
                         'setTimeout(()=>process.exit(3),3000).unref();')
        # A controller-owned loopback listener distinguishes a sandbox rejection
        # from an unused port. No network connection is made by the release.
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(1)
            checked = isolated([node, "--input-type=module", "-e", network_probe, listener.getsockname()[1]])
        require(checked.returncode == 0, "Sandbox did not reject a network connection")
        evidence["network_connections_denied"] = True
        evidence["additional_read_denials"] = ["real ~/.codex", "real ~/.agents", "ChatGPT.app", "Codex.app",
                                                 "controller source directory including old .runtime"]
        version = isolated([engine, "--version"])
        require(version.returncode == 0, "Isolated engine version check failed")
        evidence["engine_version"] = version.stdout.strip()
        doctor = isolated([engine, "serve"], input=json.dumps({"id": 1, "method": "doctor", "params": {}}) + "\n")
        require(doctor.returncode == 0, "Native doctor process failed")
        reply = json.loads(doctor.stdout.strip())
        result = reply["result"]
        require(reply["id"] == 1 and result["engine"] == "opencu" and result["requiresAccount"] is False
                and result["requiresOfficialRuntime"] is False, "Native doctor returned an unexpected result")
        evidence["native_doctor"] = {key: result[key] for key in ["engine", "version", "transport", "requiresAccount", "requiresOfficialRuntime"]}
        evidence["permission_status_not_used_as_standalone_authorization_evidence"] = True
        controller = package / ".release-check.mjs"
        controller.write_text(CONTROLLER)
        settings = {"profile": profile, "entry": str(package / "bin/opencu"), "env": environment, "cwd": str(isolated_home)}
        checked = run([str(node), str(controller), json.dumps(settings)], cwd=area, timeout=45)
        require(checked.returncode == 0, "Isolated MCP initialization, tools/list or list_apps failed")
        evidence.update(json.loads(checked.stdout.strip()))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=pathlib.Path, default=ROOT / "dist/opencu-macos-arm64.tar.gz")
    parser.add_argument("--output", type=pathlib.Path,
                        help="Also save the receipt here; the exact archive receipt is always written beside the archive")
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise SystemExit("This verifier requires macOS arm64 and the built-in sandbox-exec tool.")
    archive = args.archive.expanduser().resolve(strict=True)
    sidecar = archive.with_name(archive.name + ".verification.json")
    outputs = {sidecar}
    if args.output:
        outputs.add(args.output.expanduser().resolve())
    if archive in outputs:
        raise SystemExit("Receipt output must not replace the archive being verified.")
    evidence = {
        "test": "independent-release-isolated-read-only",
        "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "host_macos_version": platform.mac_ver()[0], "arch": platform.machine(),
        "archive": archive.name, "archive_bytes": archive.stat().st_size, "archive_sha256": sha256(archive),
        "receipt_binding": "Exact archive_sha256 and included runtime/dependency hashes; deliver alongside the archive",
        "verifier_sha256": sha256(pathlib.Path(__file__)),
        "gui_calls": 0, "input_calls": 0, "permission_requests": 0, "inventory_recorded": False,
    }
    try:
        verify(archive, evidence)
        require(sha256(archive) == evidence["archive_sha256"], "Archive changed during verification")
        evidence["ok"] = True
    except (OSError, ValueError, KeyError, RuntimeError, tarfile.TarError) as error:
        evidence["ok"] = False
        # Subprocess output and application records are deliberately omitted.
        evidence["error"] = str(error)
    for output in outputs:
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence, indent=2))
    return 0 if evidence["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
