#!/usr/bin/env python3
"""Run the project checks with the right interpreter and a clean environment.

The Python suite must not inherit the app credential helper paths. A test that
mints a real provider lease is not a test. This script removes those paths,
runs the Python suite, then runs the Swift suite.
"""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent


def find_python(root):
    requested = os.environ.get("GOBLIN_CHECK_PYTHON", "")
    if requested:
        return requested
    product = json.loads((root / "product.json").read_text(encoding="utf-8"))
    version = product["python_version"]
    directory = "cpython-" + version + "-macos-aarch64-none"
    candidate = root / ".build" / "python" / directory / "bin" / "python3"
    if candidate.is_file():
        return str(candidate)
    if sys.version_info >= (3, 11):
        return sys.executable
    raise SystemExit("No Python 3.11 or later interpreter found. Set GOBLIN_CHECK_PYTHON.")


def check_environment():
    env = os.environ.copy()
    env.pop("GOBLIN_KEYCHAIN_HELPER", None)
    env.pop("GOBLIN_RESOURCES", None)
    return env


def run(command, env):
    print("+ " + " ".join(command))
    completed = subprocess.run(command, cwd=ROOT, env=env)
    return completed.returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--packaged", action="store_true",
                        help="Run the Swift fixture against dist/Goblin.app as well.")
    arguments = parser.parse_args()
    env = check_environment()
    if arguments.packaged:
        resources = ROOT / "dist" / "Goblin.app" / "Contents" / "Resources"
        if not resources.is_dir():
            raise SystemExit("No built app at " + str(resources) + ". Run scripts/build.py first.")
        env["GOBLIN_TEST_RESOURCES"] = str(resources)
    python = find_python(ROOT)
    python_ok = run([python, "-m", "unittest", "discover", "-s", "Tests/Python", "-v"], env)
    swift_ok = run(["swift", "test"], env)
    if not python_ok or not swift_ok:
        print("checks failed")
        return 1
    print("checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
