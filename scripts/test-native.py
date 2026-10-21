#!/usr/bin/env python3
"""Run pure Swift logic checks with Command Line Tools; no Xcode/XCTest required."""

import platform
from pathlib import Path
import subprocess
import sys
import tempfile


def main() -> int:
    if sys.platform != "darwin":
        print("Native logic checks require macOS and its public system frameworks.", file=sys.stderr)
        return 1

    root = Path(__file__).resolve().parent.parent
    sources = root / "native" / "Sources" / "OpenCU"
    # Compile the real production logic, excluding the CLI entry point and GUI
    # observer. The test runner never posts events or accesses the clipboard.
    with tempfile.TemporaryDirectory(prefix="opencu-native-tests-") as directory:
        transport = Path(directory) / "worker-transport-tests"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library",
            str(sources / "WorkerTransport.swift"),
            str(root / "tests/worker-transport.swift"), "-o", str(transport),
        ], cwd=root, check=True)
        subprocess.run([str(transport)], cwd=root, check=True, timeout=30)
        capture = Path(directory) / "capture-policy-tests"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library",
            str(sources / "AgentDesktopCapturePolicy.swift"),
            str(root / "tests/agent-desktop-capture.swift"), "-o", str(capture),
        ], cwd=root, check=True)
        subprocess.run([str(capture)], cwd=root, check=True, timeout=30)
        localization = Path(directory) / "presence-localization-tests"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library",
            str(sources / "PresenceStrings.swift"), str(sources / "BadgeModel.swift"),
            str(root / "tests/presence-localization.swift"), "-o", str(localization),
        ], cwd=root, check=True)
        subprocess.run([str(localization), str(root / "native/Resources")], cwd=root, check=True, timeout=30)
        executable = Path(directory) / "native-logic-tests"
        compilation = subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-module-name", "OpenCULogicTests",
            "-target", f"{platform.machine()}-apple-macos14.0",
            str(sources / "Types.swift"),
            str(sources / "PresenceModel.swift"),
            str(sources / "BadgeModel.swift"),
            str(sources / "Keyboard.swift"),
            str(sources / "BackgroundFocus.swift"),
            str(sources / "InputController.swift"),
            str(sources / "AgentDisplayLogic.swift"),
            str(sources / "AgentDesktopLogic.swift"),
            str(sources / "AppNames.swift"),
            str(sources / "CaptureSafety.swift"),
            str(sources / "OnlineDisplays.swift"),
            str(root / "tests" / "native-logic.swift"),
            "-o", str(executable),
        ], cwd=root)
        if compilation.returncode:
            return compilation.returncode if compilation.returncode > 0 else 1
        result = subprocess.run([str(executable), str(root / "native/Resources")], cwd=root)
        return result.returncode if result.returncode >= 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
