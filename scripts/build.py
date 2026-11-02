#!/usr/bin/env python3
"""Build a self-contained native app. Installation is an explicit option.

The ordinary build packages the working tree, including uncommitted changes.
`--release` instead exports tracked HEAD into a clean directory, verifies that
export against git, builds from it, writes a source archive, and records the
built commit and bundle identity.
"""

import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

from python_runtime import ensure_python_runtime
from release_build import (
    ReleaseBuildError,
    copy_python_runtime,
    copy_runtime_inputs,
    prepare_build_source,
    prune_python_runtime,
    scrub_python_relocation,
    verify_bundle_sources,
    verify_no_private_paths,
    verify_python_runtime,
    write_release_identity,
)


def run(arguments, root):
    subprocess.run(arguments, cwd=root, check=True)


def source_map_flags(root):
    mapping = str(root) + "=."
    return ["-file-prefix-map", mapping, "-debug-prefix-map", mapping]


def build_helpers(root, resources, product):
    helpers = resources / "Helpers"
    helpers.mkdir()
    for definition in product["native_helpers"].values():
        name = definition["name"]
        bundle = helpers / (name + ".app")
        contents = bundle / "Contents"
        macos = contents / "MacOS"
        macos.mkdir(parents=True)
        binary = macos / name
        source = root / "Runtime" / definition["source"]
        target = "arm64-apple-macosx" + product["minimum_macos"]
        arguments = ["xcrun", "swiftc", "-O", "-target", target]
        arguments.extend(source_map_flags(root))
        arguments.extend([str(source), "-o", str(binary)])
        frameworks = definition.get("frameworks", ["AppKit", "ApplicationServices", "ScreenCaptureKit"])
        for framework in frameworks:
            arguments.extend(["-framework", framework])
        run(arguments, root)
        run(["/usr/bin/strip", "-S", str(binary)], root)
        info = {
            "CFBundleName": name, "CFBundleDisplayName": name,
            "CFBundleIdentifier": definition["bundle_id"],
            "CFBundleExecutable": name, "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": definition.get("version", product["version"]), "CFBundleVersion": "1",
            "LSMinimumSystemVersion": product["minimum_macos"], "LSUIElement": True,
        }
        if "ApplicationServices" in frameworks:
            info["NSAccessibilityUsageDescription"] = "Use accessibility for requested computer-use actions."
        if "ScreenCaptureKit" in frameworks:
            info["NSScreenCaptureUsageDescription"] = "Capture requested app windows for computer-use tools."
        (contents / "Info.plist").write_bytes(plistlib.dumps(info))
        metadata = definition.get("resources", {})
        if metadata:
            helper_resources = contents / "Resources"
            helper_resources.mkdir()
            for filename, field in metadata.items():
                (helper_resources / filename).write_text(json.dumps(product[field], sort_keys=True) + "\n")
        run(["codesign", "--force", "--sign", product["signing_identity"],
             "--identifier", definition["bundle_id"], str(bundle)], root)


def build(root, install=False, release_source=None, output_root=None):
    source_root = release_source.root if release_source is not None else root
    product = json.loads((source_root / "product.json").read_text())
    distribution = Path(output_root).expanduser().resolve() if output_root is not None else root / "dist"
    distribution.mkdir(parents=True, exist_ok=True)
    python_source = ensure_python_runtime(root, product)
    if not (source_root / "Runtime" / "goblin_bridge.py").is_file():
        raise RuntimeError("The local engine source is missing")
    build_arguments = ["swift", "build", "-c", "release"]
    for flag in source_map_flags(source_root):
        build_arguments.extend(["-Xswiftc", flag])
    run(build_arguments, source_root)
    app = distribution / (product["name"] + ".app")
    if app.exists():
        shutil.rmtree(app)
    contents = app / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    macos.mkdir(parents=True)
    resources.mkdir()
    binary_path = subprocess.check_output(build_arguments + ["--show-bin-path"],
                                          cwd=source_root, text=True)
    binary_root = Path(binary_path.strip())
    executable = macos / product["name"]
    shutil.copy2(binary_root / "Goblin", executable)
    run(["/usr/bin/strip", "-S", str(executable)], root)
    shutil.copy2(source_root / "product.json", resources / "product.json")
    for source in (source_root / "Resources").iterdir():
        target = resources / source.name
        if source.is_dir():
            shutil.copytree(source, target)
        else:
            shutil.copy2(source, target)
    copy_runtime_inputs(source_root, resources)
    build_helpers(source_root, resources, product)
    runtime = resources / "Runtime" / "Python"
    copy_python_runtime(python_source, runtime)
    pruned = prune_python_runtime(runtime)
    changed_install_names = scrub_python_relocation(runtime, python_source)
    verify_no_private_paths(runtime, source_root, python_source)
    notices_text = (source_root / "Runtime" / "THIRD_PARTY_NOTICES").read_text(encoding="utf-8")
    plist = {
        "CFBundleName": product["name"], "CFBundleDisplayName": product["name"],
        "CFBundleIdentifier": product["bundle_id"], "CFBundleExecutable": product["name"],
        "CFBundleShortVersionString": product["version"], "CFBundleVersion": "1",
        "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": product["minimum_macos"],
        "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
        "NSMicrophoneUsageDescription": "Use the microphone for your Goblin voice conversation.",
        "NSAppleEventsUsageDescription": "Run the computer-use tools you request.",
    }
    iconset = root / ".build" / "AppIcon.iconset"
    iconset.mkdir(exist_ok=True)
    icon = source_root / "Resources" / "Avatars" / (product["default_avatar"] + ".png")
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            suffix = "@2x" if scale == 2 else ""
            path = iconset / ("icon_" + str(size) + "x" + str(size) + suffix + ".png")
            run(["sips", "-z", str(size * scale), str(size * scale), str(icon), "--out", str(path)], root)
    run(["iconutil", "-c", "icns", str(iconset), "-o", str(resources / "AppIcon.icns")], root)
    plist["CFBundleIconFile"] = "AppIcon"
    (contents / "Info.plist").write_bytes(plistlib.dumps(plist))
    (contents / "PkgInfo").write_bytes(b"APPL????")
    entitlements = root / ".build" / "entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.device.audio-input": True,
                                           "com.apple.security.automation.apple-events": True}))
    identity = product["signing_identity"]
    for path in runtime.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        if path.suffix in (".so", ".dylib") or path.name.startswith("python3.") and path.parent.name == "bin":
            run(["codesign", "--force", "--sign", identity, str(path)], root)
    run(["codesign", "--force", "--sign", identity, "--identifier", product["bundle_id"],
         "--entitlements", str(entitlements), str(app)], root)
    run(["codesign", "--verify", "--deep", "--strict", str(app)], root)
    verify_no_private_paths(app, source_root, python_source)
    probe = verify_python_runtime(runtime, notices_text)
    source_files = verify_bundle_sources(source_root, app)
    if release_source is not None and release_source.release:
        identity_path = write_release_identity(distribution, app, product, release_source)
        print("Release identity:", identity_path)
    if install:
        destination = Path("/Applications") / app.name
        executable = destination / "Contents" / "MacOS" / product["name"]
        running = subprocess.run(["pgrep", "-f", "^" + re.escape(str(executable)) + "$"], capture_output=True)
        if running.returncode == 0:
            raise RuntimeError("Quit the installed app before replacing it")
        if destination.exists():
            backup = root / ".build" / (app.name + ".previous")
            if backup.exists():
                shutil.rmtree(backup)
            shutil.copytree(destination, backup, symlinks=True)
            shutil.rmtree(destination)
        shutil.copytree(app, destination, symlinks=True)
        run(["codesign", "--verify", "--deep", "--strict", str(destination)], root)
        print("Installed:", destination)
    print("Bundled Python:", probe["openssl"] + ", SQLite " + probe["sqlite"])
    print("Pruned Python paths:", len(pruned), "Install names changed:", len(changed_install_names))
    print("Verified source files:", source_files)
    print("Built:", app)
    return app


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true", help="Copy the built app to /Applications after quitting any running instance.")
    parser.add_argument("--release", action="store_true",
                        help="Build from a fresh export of tracked HEAD. Requires a clean tracked tree, writes a source archive, and records release identity.")
    parser.add_argument("--output", type=Path, default=None,
                        help="Directory that receives the app (and release archive). Default: the repository dist directory.")
    parser.add_argument("--source-archive", type=Path, default=None,
                        help="Path for the release source archive. Only valid with --release.")
    arguments = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    product = json.loads((root / "product.json").read_text())
    output_root = arguments.output.expanduser().resolve() if arguments.output is not None else root / "dist"
    if arguments.source_archive is not None and not arguments.release:
        parser.error("--source-archive requires --release")
    archive_path = None
    if arguments.release:
        archive_path = arguments.source_archive
        if archive_path is None:
            archive_path = output_root / (product["name"] + "-" + product["version"] + "-source.tar.gz")
        archive_path = archive_path.expanduser().resolve()
    try:
        release_source = prepare_build_source(root, arguments.release, archive_path)
        build(root, arguments.install, release_source, output_root)
    except (OSError, ValueError, RuntimeError, ReleaseBuildError, subprocess.CalledProcessError) as error:
        print("Build failed:", error, file=sys.stderr)
        raise SystemExit(1)
