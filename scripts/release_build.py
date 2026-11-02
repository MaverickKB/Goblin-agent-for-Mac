"""Release source export, bundle inputs, and CPython runtime cleanup.

The ordinary build packages the working tree so a developer can iterate with
uncommitted files. The release build exports tracked `HEAD` into a clean
directory, verifies that export against the git object ids, builds there, and
then verifies the app bundle against that same export.
"""

from __future__ import annotations

import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
from dataclasses import dataclass


RUNTIME_DOCUMENTS = ("LICENSE", "NOTICE", "AETHERMIND_LICENSE", "SOURCE.json", "THIRD_PARTY_NOTICES")
PYTHON_PROBE = r'''
import importlib.util
import json
import ssl
import sqlite3
import sys
import sysconfig

import _dbm
import bz2
import ctypes
import hashlib
import lzma
import zlib

print(json.dumps({
    "python": sys.version.split()[0],
    "prefix": sys.prefix,
    "base_prefix": sys.base_prefix,
    "sysconfig_prefix": sysconfig.get_config_var("prefix"),
    "stdlib": sysconfig.get_paths()["stdlib"],
    "openssl": ssl.OPENSSL_VERSION,
    "sqlite": sqlite3.sqlite_version,
    "tkinter": importlib.util.find_spec("tkinter") is not None,
    "pip": importlib.util.find_spec("pip") is not None,
}))
'''


class ReleaseBuildError(RuntimeError):
    """A build input or release invariant is not satisfied."""


@dataclass
class BuildSource:
    root: Path
    release: bool
    commit: str = ""
    source_tree: str = ""
    archive: Path | None = None


def git_command(root, arguments):
    completed = subprocess.run(["git", *arguments], cwd=root, capture_output=True, text=True)
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise ReleaseBuildError("git " + " ".join(arguments) + " failed: " + detail)
    return completed.stdout


def dirty_entries(root):
    output = git_command(root, ["status", "--porcelain", "--untracked-files=all"])
    entries = []
    for line in output.splitlines():
        if line.strip():
            entries.append(line)
    return entries


def require_release_tree(root):
    entries = dirty_entries(root)
    if entries:
        listing = "\n".join(entries)
        raise ReleaseBuildError(
            "Release builds require a clean tracked tree. Commit or remove these changes first:\n"
            + listing
            + "\nFor an ordinary development build from the working tree, run scripts/build.py without --release."
        )
    commit = git_command(root, ["rev-parse", "HEAD"]).strip()
    source_tree = git_command(root, ["rev-parse", "HEAD^{tree}"]).strip()
    return commit, source_tree


def git_blob_id(content):
    header = b"blob " + str(len(content)).encode("ascii") + b"\0"
    return hashlib.sha1(header + content).hexdigest()


def tree_entries(root):
    output = git_command(root, ["ls-tree", "-r", "-z", "--full-tree", "HEAD"])
    entries = []
    for record in output.split("\0"):
        if not record:
            continue
        metadata, relative = record.split("\t", 1)
        mode, kind, object_id = metadata.split(" ", 2)
        entries.append({"mode": mode, "kind": kind, "object_id": object_id, "path": relative})
    return entries


def verify_export_identity(root, export_root):
    entries = tree_entries(root)
    expected_paths = set()
    for entry in entries:
        expected_paths.add(entry["path"])
        exported = export_root / entry["path"]
        if entry["mode"] == "120000":
            if not exported.is_symlink():
                raise ReleaseBuildError("Exported path is not the symlink recorded in HEAD: " + entry["path"])
            content = os.readlink(exported).encode("utf-8")
        else:
            if not exported.is_file():
                raise ReleaseBuildError("Exported path is missing: " + entry["path"])
            content = exported.read_bytes()
        actual_id = git_blob_id(content)
        if actual_id != entry["object_id"]:
            raise ReleaseBuildError("Exported file does not match HEAD: " + entry["path"])
    actual_paths = set()
    for path in export_root.rglob("*"):
        if path.is_dir() and not path.is_symlink():
            continue
        actual_paths.add(path.relative_to(export_root).as_posix())
    extra_paths = sorted(actual_paths - expected_paths)
    if extra_paths:
        raise ReleaseBuildError("Export contains files that are not tracked in HEAD: " + ", ".join(extra_paths))
    return len(entries)


def export_tracked_source(root, export_root, archive_path):
    if export_root.exists():
        shutil.rmtree(export_root)
    export_root.mkdir(parents=True)
    archive_path.parent.mkdir(parents=True, exist_ok=True)
    completed = subprocess.run(
        ["git", "archive", "--format=tar.gz", "--output", str(archive_path), "HEAD"],
        cwd=root,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise ReleaseBuildError("git archive failed: " + detail)
    with tarfile.open(archive_path, "r:gz") as bundle:
        if hasattr(tarfile, "data_filter"):
            bundle.extractall(export_root, filter="data")
        else:
            bundle.extractall(export_root)
    return verify_export_identity(root, export_root)


def prepare_build_source(root, release, archive_path=None):
    root = root.resolve()
    if not release:
        return BuildSource(root=root, release=False)
    if archive_path is None:
        raise ReleaseBuildError("A release build needs a source archive path")
    commit, source_tree = require_release_tree(root)
    export_root = root / ".build" / "release-source"
    export_tracked_source(root, export_root, archive_path)
    return BuildSource(
        root=export_root,
        release=True,
        commit=commit,
        source_tree=source_tree,
        archive=archive_path,
    )


def runtime_input_paths(root):
    runtime = root / "Runtime"
    paths = {runtime / "goblin_bridge.py"}
    for path in (runtime / "goblin_core").rglob("*.py"):
        if "__pycache__" in path.parts:
            continue
        paths.add(path)
    baseline = runtime / "goblin_core" / "baseline_skills"
    if not baseline.is_dir():
        raise ReleaseBuildError("Bundled skill directory is missing: " + str(baseline.relative_to(root)))
    manifest = baseline / "SOURCE.json"
    try:
        definition = json.loads(manifest.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReleaseBuildError("Bundled skill manifest is unavailable: " + str(manifest.relative_to(root))) from error
    required = definition.get("baseline_core") if isinstance(definition, dict) else None
    if not isinstance(required, list) or not required:
        raise ReleaseBuildError("Bundled skill manifest must declare baseline_core")
    for name in required:
        if not isinstance(name, str) or not name or name in (".", "..") or Path(name).name != name:
            raise ReleaseBuildError("Invalid skill name in baseline_core")
        if not (baseline / name / "SKILL.md").is_file():
            raise ReleaseBuildError("Required baseline skill is missing: " + name)
    if len(set(required)) != len(required):
        raise ReleaseBuildError("baseline_core contains duplicate skills")
    for path in baseline.rglob("*"):
        if not path.is_file():
            continue
        if "__pycache__" in path.parts or path.name == ".DS_Store" or path.suffix == ".pyc":
            continue
        paths.add(path)
    for name in RUNTIME_DOCUMENTS:
        path = runtime / name
        if not path.is_file():
            raise ReleaseBuildError("Runtime document is missing: " + str(path.relative_to(root)))
        paths.add(path)
    license_root = runtime / "THIRD_PARTY_LICENSES"
    if not license_root.is_dir():
        raise ReleaseBuildError("Runtime license directory is missing: " + str(license_root.relative_to(root)))
    for path in license_root.rglob("*"):
        if path.is_file():
            paths.add(path)
    return sorted(paths, key=lambda item: item.relative_to(root).as_posix())


def copy_runtime_inputs(root, resources):
    copied = []
    for source in runtime_input_paths(root):
        relative = source.relative_to(root)
        target = resources / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)
        copied.append(relative.as_posix())
    return copied


def copy_python_runtime(python_source, runtime):
    if runtime.exists():
        shutil.rmtree(runtime)
    ignore = shutil.ignore_patterns("__pycache__", "*.pyc")
    shutil.copytree(python_source, runtime, symlinks=True, ignore=ignore)


def remove_relative(runtime, relative):
    root = runtime.resolve()
    target = runtime / relative
    parent = target.parent.resolve()
    if os.path.commonpath([str(root), str(parent)]) != str(root):
        raise ReleaseBuildError("Refusing to remove a path outside the Python runtime: " + relative)
    if target.is_symlink():
        target.unlink()
        return True
    if target.is_dir():
        shutil.rmtree(target)
        return True
    if target.exists():
        target.unlink()
        return True
    return False


def prune_python_runtime(runtime):
    removed = []
    exact_paths = [
        "bin/idle3",
        "bin/idle3.14",
        "bin/pip",
        "bin/pip3",
        "bin/pip3.14",
        "bin/pydoc3",
        "bin/pydoc3.14",
        "bin/python3-config",
        "bin/python3.14-config",
        "include",
        "lib/itcl4.3.8",
        "lib/libtcl9.0.dylib",
        "lib/libtcl9tk9.0.dylib",
        "lib/pkgconfig",
        "lib/tcl9",
        "lib/tcl9.0",
        "lib/thread3.0.6",
        "lib/tk9.0",
        "lib/python3.14/config-3.14-darwin",
        "lib/python3.14/ensurepip",
        "lib/python3.14/idlelib",
        "lib/python3.14/site-packages/README.txt",
        "lib/python3.14/site-packages/pip",
        "lib/python3.14/test",
        "lib/python3.14/tkinter",
        "lib/python3.14/turtledemo",
        "lib/python3.14/_sysconfig_vars__darwin_darwin.json",
        "share",
    ]
    for relative in exact_paths:
        if remove_relative(runtime, relative):
            removed.append(relative)
    glob_patterns = [
        "lib/python3.14/site-packages/pip-*.dist-info",
        "lib/python3.14/lib-dynload/_tkinter*.so",
    ]
    for pattern in glob_patterns:
        for path in sorted(runtime.glob(pattern)):
            relative = path.relative_to(runtime).as_posix()
            if remove_relative(runtime, relative):
                removed.append(relative)
    verify_pruned_runtime(runtime)
    return removed


def verify_pruned_runtime(runtime):
    forbidden_tokens = (
        "site-packages/pip",
        "pip-",
        "idlelib",
        "bin/idle",
        "tkinter",
        "libtcl",
        "tcl9",
        "tk9.0",
        "itcl",
        "thread3.0",
    )
    for path in runtime.rglob("*"):
        relative = path.relative_to(runtime).as_posix().lower()
        for token in forbidden_tokens:
            if token in relative:
                raise ReleaseBuildError("Unused Python artifact remains in the bundle: " + relative)


def scrub_sysconfig_data(runtime, python_source):
    data_file = runtime / "lib" / "python3.14" / "_sysconfigdata__darwin_darwin.py"
    if not data_file.is_file():
        raise ReleaseBuildError("The copied Python runtime has no sysconfig data: " + str(data_file))
    text = data_file.read_text(encoding="utf-8")
    old_prefixes = [str(python_source), str(python_source.resolve())]
    for old_prefix in old_prefixes:
        if old_prefix:
            text = text.replace(old_prefix, "@PREFIX@")
    text = re.sub(r"/(?:private/)?tmp/[^\s\"']+", "/install", text)
    header = "# system configuration generated and used by the sysconfig module\nbuild_time_vars = {\n"
    if not text.startswith(header):
        raise ReleaseBuildError("The Python sysconfig data has an unexpected header")
    replacement = (
        "# system configuration generated and used by the sysconfig module\n"
        "import sys as _sys\n\n"
        "_INSTALL_PREFIX = _sys.base_prefix\n\n"
        "build_time_vars = {\n"
    )
    text = text.replace(header, replacement, 1)
    text = text.rstrip() + (
        "\n\n"
        "for _name in list(build_time_vars):\n"
        "    _value = build_time_vars[_name]\n"
        "    if isinstance(_value, str):\n"
        "        build_time_vars[_name] = _value.replace(\"@PREFIX@\", _INSTALL_PREFIX)\n"
    )
    data_file.write_text(text, encoding="utf-8")


def scrub_python_install_names(runtime):
    changed = []
    for library in sorted((runtime / "lib").glob("libpython*.dylib")):
        name = library.name
        completed = subprocess.run(
            ["/usr/bin/otool", "-D", str(library)],
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            raise ReleaseBuildError("otool could not read the Python dylib: " + detail_for(completed))
        current = completed.stdout
        if "@rpath/" + name in current:
            continue
        completed = subprocess.run(
            ["/usr/bin/install_name_tool", "-id", "@rpath/" + name, str(library)],
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            raise ReleaseBuildError("install_name_tool failed: " + detail_for(completed))
        verification = subprocess.run(
            ["/usr/bin/otool", "-D", str(library)],
            capture_output=True,
            text=True,
        )
        if verification.returncode != 0 or "@rpath/" + name not in verification.stdout:
            raise ReleaseBuildError("The Python dylib install name was not rewritten: " + name)
        changed.append(name)
    return changed


def detail_for(completed):
    return (completed.stderr or completed.stdout).strip()


def scrub_python_relocation(runtime, python_source):
    scrub_sysconfig_data(runtime, python_source)
    changed = scrub_python_install_names(runtime)
    return changed


def scan_tree_paths(root, needles):
    hits = []
    scanned = 0
    for path in root.rglob("*"):
        if not path.is_file() or path.is_symlink():
            continue
        content = path.read_bytes()
        scanned += 1
        for needle in needles:
            if needle.encode("utf-8") in content:
                hits.append((path.relative_to(root).as_posix(), needle))
    return scanned, hits


def verify_no_private_paths(runtime, source_root, python_source):
    user_prefix = os.path.join("/", "Users", "")
    temporary_prefix = os.path.join("/", "private", "tmp", "")
    needles = [user_prefix, temporary_prefix, str(source_root), str(python_source)]
    unique = []
    for needle in needles:
        if needle and needle not in unique:
            unique.append(needle)
    scanned, hits = scan_tree_paths(runtime, unique)
    if hits:
        lines = []
        for relative, needle in hits:
            lines.append(relative + " contains " + needle)
        raise ReleaseBuildError(
            "The built artifact still contains a source-machine path:\n" + "\n".join(lines)
        )
    return scanned


def verify_python_runtime(runtime, notices_text):
    executable = runtime / "bin" / "python3"
    completed = subprocess.run(
        [str(executable), "-I", "-B", "-c", PYTHON_PROBE],
        cwd=runtime,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise ReleaseBuildError("Bundled Python check failed: " + detail_for(completed))
    lines = completed.stdout.strip().splitlines()
    if not lines:
        raise ReleaseBuildError("Bundled Python check returned no result")
    probe = json.loads(lines[-1])
    expected_prefix = runtime.resolve()
    for key in ("prefix", "base_prefix", "sysconfig_prefix"):
        value = probe.get(key)
        if not isinstance(value, str):
            raise ReleaseBuildError("Bundled Python " + key + " is missing")
        actual = Path(value).resolve()
        if actual != expected_prefix:
            raise ReleaseBuildError("Bundled Python " + key + " points outside the bundle: " + str(actual))
    stdlib_value = probe.get("stdlib")
    if not isinstance(stdlib_value, str):
        raise ReleaseBuildError("Bundled Python stdlib path is missing")
    stdlib = Path(stdlib_value).resolve()
    if expected_prefix not in stdlib.parents:
        raise ReleaseBuildError("Bundled Python stdlib points outside the bundle: " + str(stdlib))
    if probe["tkinter"]:
        raise ReleaseBuildError("The tkinter package is still bundled")
    if probe["pip"]:
        raise ReleaseBuildError("The pip package is still bundled")
    verify_notice_versions(notices_text, probe)
    return probe


def verify_notice_versions(notices_text, probe):
    python_match = re.search(r"CPython\s+([0-9][0-9A-Za-z.\-]*)", notices_text)
    openssl_match = re.search(r"OpenSSL\s+([0-9][0-9A-Za-z.\-]*)", notices_text)
    sqlite_match = re.search(r"SQLite\s+([0-9][0-9A-Za-z.\-]*)", notices_text)
    if python_match is None:
        raise ReleaseBuildError("THIRD_PARTY_NOTICES has no CPython version")
    if openssl_match is None:
        raise ReleaseBuildError("THIRD_PARTY_NOTICES has no OpenSSL version")
    if sqlite_match is None:
        raise ReleaseBuildError("THIRD_PARTY_NOTICES has no SQLite version")
    python_version = python_match.group(1)
    openssl_version = openssl_match.group(1)
    sqlite_version = sqlite_match.group(1)
    if probe["python"] != python_version:
        raise ReleaseBuildError(
            "THIRD_PARTY_NOTICES says CPython " + python_version + " but the runtime reports " + probe["python"]
        )
    if not probe["openssl"].startswith("OpenSSL " + openssl_version):
        raise ReleaseBuildError(
            "THIRD_PARTY_NOTICES says OpenSSL " + openssl_version + " but the runtime reports " + probe["openssl"]
        )
    if probe["sqlite"] != sqlite_version:
        raise ReleaseBuildError(
            "THIRD_PARTY_NOTICES says SQLite " + sqlite_version + " but the runtime reports " + probe["sqlite"]
        )


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            block = stream.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def verify_bundle_sources(source_root, app):
    resources = app / "Contents" / "Resources"
    count = 0
    for source in runtime_input_paths(source_root):
        relative = source.relative_to(source_root)
        target = resources / relative
        compare_files(source, target, relative.as_posix())
        count += 1
    resources_root = source_root / "Resources"
    for source in resources_root.rglob("*"):
        if source.is_dir():
            continue
        relative = source.relative_to(resources_root)
        target = resources / relative
        compare_files(source, target, "Resources/" + relative.as_posix())
        count += 1
    compare_files(source_root / "product.json", resources / "product.json", "product.json")
    count += 1
    swift_sources = resources / "Runtime" / "goblin_core" / "native" / "mac"
    if swift_sources.exists():
        raise ReleaseBuildError("Helper Swift sources must not be copied into the app bundle")
    return count


def compare_files(source, target, label):
    if not target.is_file():
        raise ReleaseBuildError("The app bundle is missing a source file: " + label)
    if sha256_file(source) != sha256_file(target):
        raise ReleaseBuildError("The app bundle does not match the build source: " + label)


def write_release_identity(output_root, app, product, source):
    identity = {
        "mode": "release",
        "commit": source.commit,
        "source_tree": source.source_tree,
        "source_archive": source.archive.name,
        "source_archive_sha256": sha256_file(source.archive),
        "product": product["name"],
        "version": product["version"],
        "app": app.name,
        "app_executable_sha256": sha256_file(app / "Contents" / "MacOS" / product["name"]),
        "python_version": product["python_version"],
        "runtime_source_file_count": len(runtime_input_paths(source.root)),
        "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    }
    path = output_root / (product["name"] + "-" + product["version"] + "-release.json")
    path.write_text(json.dumps(identity, indent=2) + "\n", encoding="utf-8")
    return path
