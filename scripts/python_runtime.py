"""Prepare the pinned CPython runtime in the app-owned build cache.

The release pins the exact python-build-standalone archive and SHA-256 in
product.json. This module downloads that archive directly with the standard
library. It does not call uv and it does not write to a global uv store or the
user home directory.

The cache layout matches the directory the build already uses:

    <root>/.build/python/cpython-3.14.8-macos-aarch64-none

The upstream install-only archive contains a top-level ``python`` directory.
That directory becomes the cache directory, and a ``BUILD`` marker records the
pinned python-build-standalone release.
"""

from __future__ import annotations

import hashlib
import os
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile
import urllib.request

CACHE_PARENT = Path(".build") / "python"
ARCHIVE_ROOT = "python"
BUILD_MARKER = "BUILD"
PYTHON_EXECUTABLE = Path("bin") / "python3"
READ_BLOCK = 1024 * 1024
DOWNLOAD_TIMEOUT = 300


class PythonRuntimeError(RuntimeError):
    """The pinned Python runtime cannot be prepared or verified."""


def runtime_cache_path(root, product):
    """Return the runtime directory for the product's Python version."""
    version = product.get("python_version")
    if not isinstance(version, str) or not version.strip():
        raise PythonRuntimeError("product.json has no python_version")
    directory_name = "cpython-" + version + "-macos-aarch64-none"
    return Path(root).resolve() / CACHE_PARENT / directory_name


def ensure_python_runtime(root, product):
    """Return a verified runtime, downloading the pinned archive if needed."""
    version = product.get("python_version")
    if not isinstance(version, str) or not version.strip():
        raise PythonRuntimeError("product.json has no python_version")
    build, url, checksum = read_pin(product)
    runtime = runtime_cache_path(root, product)
    if runtime.exists():
        verify_existing_runtime(runtime, build, version)
        return runtime
    runtime.parent.mkdir(parents=True, exist_ok=True)
    temporary_prefix = "python-runtime-"
    with tempfile.TemporaryDirectory(prefix=temporary_prefix, dir=str(runtime.parent)) as temporary:
        temporary_path = Path(temporary)
        archive = temporary_path / "runtime.tar.gz"
        download_file(url, archive)
        actual_checksum = sha256_file(archive)
        if actual_checksum != checksum:
            raise PythonRuntimeError(
                "The Python runtime archive checksum does not match product.json: expected "
                + checksum
                + " but downloaded "
                + actual_checksum
            )
        staging = temporary_path / "staging"
        extract_archive(archive, staging)
        source = staging / ARCHIVE_ROOT
        if not source.is_dir():
            raise PythonRuntimeError("The Python runtime archive has no python directory")
        write_build_marker(source, build)
        verify_interpreter(source / PYTHON_EXECUTABLE, version)
        if runtime.exists():
            verify_existing_runtime(runtime, build, version)
            return runtime
        try:
            os.replace(str(source), str(runtime))
        except OSError:
            if runtime.exists():
                verify_existing_runtime(runtime, build, version)
                return runtime
            raise
    return runtime


def read_pin(product):
    """Read and validate the runtime URL, build, and checksum pins."""
    pin = product.get("python_runtime")
    if not isinstance(pin, dict):
        raise PythonRuntimeError("product.json has no python_runtime pin")
    build = pin.get("build")
    url = pin.get("url")
    checksum = pin.get("sha256")
    values = (
        ("build", build),
        ("url", url),
        ("sha256", checksum),
    )
    for name, value in values:
        if not isinstance(value, str) or not value.strip():
            raise PythonRuntimeError("product.json python_runtime has no " + name)
    build = build.strip()
    url = url.strip()
    checksum = checksum.strip().lower()
    if not url.startswith("https://"):
        raise PythonRuntimeError("The Python runtime URL must use https")
    if len(checksum) != 64:
        raise PythonRuntimeError("The Python runtime SHA-256 must have 64 characters")
    for character in checksum:
        if character not in "0123456789abcdef":
            raise PythonRuntimeError("The Python runtime SHA-256 is not hexadecimal")
    return build, url, checksum


def verify_existing_runtime(runtime, build, version):
    """Verify a cache directory before the build uses it."""
    runtime = Path(runtime)
    if runtime.is_symlink():
        raise PythonRuntimeError("The Python runtime cache must not be a symlink")
    if not runtime.is_dir():
        raise PythonRuntimeError("The Python runtime cache is not a directory: " + str(runtime))
    marker = runtime / BUILD_MARKER
    if not marker.is_file():
        raise PythonRuntimeError("The Python runtime cache has no BUILD marker: " + str(runtime))
    marker_value = marker.read_text(encoding="utf-8").strip()
    if marker_value != build:
        raise PythonRuntimeError(
            "The Python runtime cache is build "
            + marker_value
            + " but product.json pins build "
            + build
            + ". Remove "
            + str(runtime)
            + " to fetch the pinned build."
        )
    verify_interpreter(runtime / PYTHON_EXECUTABLE, version)


def verify_interpreter(executable, version):
    """Run the cache interpreter and check its reported Python version."""
    executable = Path(executable)
    if not executable.is_file():
        raise PythonRuntimeError("The Python runtime has no interpreter: " + str(executable))
    command = [str(executable), "-I", "-B", "-c", "import sys; print(sys.version.split()[0])"]
    completed = subprocess.run(command, capture_output=True, text=True)
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise PythonRuntimeError("The Python runtime interpreter failed: " + detail)
    lines = completed.stdout.strip().splitlines()
    if not lines:
        raise PythonRuntimeError("The Python runtime interpreter printed no version")
    reported = lines[-1].strip()
    if reported != version:
        raise PythonRuntimeError(
            "The Python runtime reports " + reported + " but product.json pins " + version
        )


def download_file(url, destination):
    """Download a URL to a local file without using a package manager."""
    request = urllib.request.Request(url, headers={"User-Agent": "Python-runtime-build/1"})
    with urllib.request.urlopen(request, timeout=DOWNLOAD_TIMEOUT) as response:
        with Path(destination).open("wb") as stream:
            while True:
                block = response.read(READ_BLOCK)
                if not block:
                    break
                stream.write(block)


def sha256_file(path):
    """Return the SHA-256 digest of a file."""
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        while True:
            block = stream.read(READ_BLOCK)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def extract_archive(archive, destination):
    """Extract a runtime archive without allowing paths outside destination."""
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    try:
        with tarfile.open(archive, "r:gz") as bundle:
            data_filter = getattr(tarfile, "data_filter", None)
            if data_filter is not None:
                bundle.extractall(destination, filter="data")
                return
            members = []
            for member in bundle.getmembers():
                check_member(member)
                members.append(member)
            bundle.extractall(destination, members=members)
    except tarfile.TarError as error:
        raise PythonRuntimeError("The Python runtime archive could not be extracted: " + str(error))


def check_member(member):
    """Reject archive members that escape the destination directory."""
    name = PurePosixPath(member.name)
    if name.is_absolute() or ".." in name.parts:
        raise PythonRuntimeError("The Python runtime archive has an unsafe path: " + member.name)
    if member.isdev():
        raise PythonRuntimeError("The Python runtime archive has a device file: " + member.name)
    if member.issym() or member.islnk():
        target = PurePosixPath(member.linkname)
        if target.is_absolute():
            raise PythonRuntimeError("The Python runtime archive has an unsafe link: " + member.name)
        combined = name.parent / target
        if ".." in combined.parts:
            raise PythonRuntimeError("The Python runtime archive has an unsafe link: " + member.name)


def write_build_marker(runtime, build):
    """Record the pinned build tag in the extracted runtime."""
    marker = Path(runtime) / BUILD_MARKER
    marker.write_text(build, encoding="utf-8")
