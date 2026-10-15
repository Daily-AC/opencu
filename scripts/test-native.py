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
        executable = Path(directory) / "native-logic-tests"
        compilation = subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-module-name", "OpenCULogicTests",
            "-target", f"{platform.machine()}-apple-macos14.0",
            str(sources / "Types.swift"),
            str(sources / "Keyboard.swift"),
            str(sources / "BackgroundFocus.swift"),
            str(sources / "InputController.swift"),
            str(sources / "AgentDisplayLogic.swift"),
            str(root / "tests" / "native-logic.swift"),
            "-o", str(executable),
        ], cwd=root)
        if compilation.returncode:
            return compilation.returncode if compilation.returncode > 0 else 1
        result = subprocess.run([str(executable)], cwd=root)
        return result.returncode if result.returncode >= 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
