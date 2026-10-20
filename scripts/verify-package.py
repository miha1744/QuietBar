#!/usr/bin/env python3
"""Verify local QuietBar packages without installing or enabling the app."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time
import zipfile


REPORT = {
    "schema": 1,
    "passed": False,
    "scope": "package integrity and read-only CLI checks",
    "guiJumpAcceptance": "not run",
    "checks": [],
    "commands": [],
    "cliTests": {},
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def json_flag(value, expected):
    # Foundation NSNumber can serialize an Objective-C BOOL as either a JSON
    # boolean or 0/1. Reject strings, floats, and other truthy values.
    return type(value) in (bool, int) and value in (0, 1) and bool(value) == expected


def run(label, args, timeout=90):
    started = time.monotonic()
    event = {"name": label}
    REPORT["commands"].append(event)
    try:
        result = subprocess.run(
            [str(arg) for arg in args], check=False, capture_output=True,
            text=True, timeout=timeout,
        )
        event["exitCode"] = result.returncode
        if result.returncode:
            detail = (result.stdout + result.stderr).strip()[-2000:]
            raise ValueError(f"{label} exited {result.returncode}: {detail}")
        return result.stdout, result.stderr
    except subprocess.TimeoutExpired as error:
        event["timedOut"] = True
        raise ValueError(f"{label} exceeded {timeout} seconds") from error
    finally:
        event["seconds"] = round(time.monotonic() - started, 3)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def app_manifest(app):
    """Compare packaged file bytes, executable bits, and symlink targets."""
    manifest = {}
    for path in sorted(app.rglob("*")):
        name = path.relative_to(app).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            manifest[name] = {"symlink": os.readlink(path)}
        elif stat.S_ISREG(mode):
            manifest[name] = {"sha256": sha256(path), "executable": bool(mode & 0o111)}
        else:
            require(stat.S_ISDIR(mode), f"Unexpected file type in app: {name}")
    return manifest


def verify_app(app, metadata, hardened, label):
    run(f"{label}: plist", ["/usr/bin/plutil", "-lint", app / "Contents/Info.plist"])
    with (app / "Contents/Info.plist").open("rb") as stream:
        require(plistlib.load(stream) == metadata, f"{label}: bundle metadata differs")
    binary = app / "Contents/MacOS" / metadata["CFBundleExecutable"]
    archs, _ = run(f"{label}: architectures", ["/usr/bin/xcrun", "lipo", "-archs", binary])
    require(set(archs.split()) == {"arm64", "x86_64"}, f"{label}: expected arm64 and x86_64")
    for arch in ("arm64", "x86_64"):
        build, _ = run(f"{label}: {arch} deployment target", [
            "/usr/bin/xcrun", "vtool", "-arch", arch, "-show-build", binary,
        ])
        require(re.search(r"\bminos\s+14\.0\b", build), f"{label}: {arch} minimum is not macOS 14.0")
        _, signature = run(f"{label}: {arch} signature flags", [
            "/usr/bin/codesign", "--display", "--verbose=4", "--arch", arch, app,
        ])
        if hardened:
            require(re.search(r"flags=.*\bruntime\b", signature), f"{label}: {arch} lacks hardened runtime")
    run(f"{label}: signature", [
        "/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "--verbose=2", app,
    ])
    REPORT["checks"].append(f"{label}: metadata, universal binary, deployment targets, signature")


def verify_zip(path, root, required):
    require(path.is_file(), f"Missing artifact: {path.name}")
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        require(len(entries) <= 10000, f"{path.name}: too many entries")
        require(sum(item.file_size for item in entries) <= 128 * 1024 * 1024,
                f"{path.name}: expanded size exceeds 128 MiB")
        names = set()
        for item in entries:
            name = PurePosixPath(item.filename)
            require(not name.is_absolute() and ".." not in name.parts and "\\" not in item.filename,
                    f"{path.name}: unsafe archive path")
            require(name.parts and name.parts[0] in (root, "__MACOSX"),
                    f"{path.name}: unexpected archive root")
            # The generated app/source ZIPs contain no symlinks. Do not extract
            # a replacement archive that could write outside our temporary tree.
            require(not stat.S_ISLNK(item.external_attr >> 16), f"{path.name}: unexpected symlink")
            require(item.filename not in names, f"{path.name}: duplicate archive entry")
            names.add(item.filename)
        require(set(required) <= names, f"{path.name}: required content missing")
    run(f"{path.name}: CRC integrity", ["/usr/bin/unzip", "-tq", path], timeout=120)
    REPORT["checks"].append(f"{path.name}: archive paths, required files, CRC integrity")


def verify_dmg(path, temporary, app_files, metadata, hardened):
    require(path.is_file(), f"Missing artifact: {path.name}")
    run("DMG checksum", ["/usr/bin/hdiutil", "verify", path], timeout=120)
    mountpoint = temporary / "mounted-dmg"
    mountpoint.mkdir()
    mounted = False
    try:
        attached, _ = run("Mount own DMG read-only", [
            "/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen",
            "-plist", "-mountpoint", mountpoint, path,
        ], timeout=120)
        mounted = True
        entities = plistlib.loads(attached.encode())["system-entities"]
        require(any(item.get("mount-point") == str(mountpoint) for item in entities),
                "DMG was not mounted at the requested private mountpoint")
        require((mountpoint / "Applications").is_symlink()
                and os.readlink(mountpoint / "Applications") == "/Applications",
                "DMG lacks the Applications shortcut")
        require((mountpoint / "README.txt").is_file(), "DMG lacks README.txt")
        app = mountpoint / "QuietBar.app"
        verify_app(app, metadata, hardened, "DMG app")
        require(app_manifest(app) == app_files, "DMG app differs from output app")
        require(sha256(mountpoint / "README.txt") == sha256(app / "Contents/Resources/README.txt"),
                "DMG README differs from the bundled instructions")
        REPORT["checks"].append("DMG app matches output; Applications shortcut and instructions present")
    finally:
        # Detach only the mountpoint created by this invocation, including when
        # a successful attach is followed by a validation or parsing failure.
        if mounted or os.path.ismount(mountpoint):
            try:
                run("Detach own DMG", ["/usr/bin/hdiutil", "detach", mountpoint], timeout=60)
            except ValueError:
                run("Detach own DMG (force)", ["/usr/bin/hdiutil", "detach", "-force", mountpoint], timeout=60)
            require(not os.path.ismount(mountpoint), "Verification DMG remained mounted")


def cli_checks(binary, metadata):
    for flag in ("--test-legacy-helpers", "--test-unsupported", "--self-test"):
        stdout, _ = run(flag, [binary, flag], timeout=30)
        value = json.loads(stdout)
        require(isinstance(value, dict), f"{flag}: expected JSON object")
        REPORT["cliTests"][flag] = value
        if flag == "--test-legacy-helpers":
            controller, backend = value.get("controller", {}), value.get("backend", {})
            require(json_flag(value.get("passed"), True) and json_flag(controller.get("passed"), True)
                    and json_flag(backend.get("passed"), True), "Legacy helper fixtures failed")
            require(len(controller.get("checks", [])) >= 20 and controller.get("failures") == [],
                    "Legacy controller fixture coverage is incomplete")
            require(controller.get("serviceMutations") == 0 and controller.get("preferenceMutations") == 0
                    and json_flag(controller.get("indicatorVerified"), False) and json_flag(backend.get("launchPerformed"), False),
                    "Legacy helper tests must report no launch or state mutations")
        elif flag == "--test-unsupported":
            require(all(json_flag(value.get(key), True) for key in ("passed", "simulatedMissingAPI", "activationBlocked")),
                    "Simulated unsupported API did not remain disabled")
        else:
            require(value.get("bundleID") == metadata["CFBundleIdentifier"]
                    and value.get("minimumMacOS") == metadata["LSMinimumSystemVersion"]
                    and json_flag(value.get("enabled"), False), "Read-only self-test returned unexpected app state")
        REPORT["checks"].append(f"{flag}: JSON result validated")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=Path("dist"))
    parser.add_argument("--build-dir", type=Path, default=Path("build/verification"))
    parser.add_argument("--require-hardened-runtime", action="store_true")
    args = parser.parse_args()
    output, build = args.output_dir.resolve(), args.build_dir.resolve()
    require(build != output and output not in build.parents,
            "Keep verification reports and temporary files outside the output directory")
    build.mkdir(parents=True, exist_ok=True)
    report = build / "verification-report.json"
    try:
        require(sys.platform == "darwin", "Package verification requires macOS and Xcode Command Line Tools")
        REPORT["timestampUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        REPORT["host"] = {"macOS": platform.mac_ver()[0], "architecture": platform.machine()}
        sip, _ = run("Read SIP status", ["/usr/bin/csrutil", "status"], timeout=10)
        REPORT["host"]["sipStatus"] = sip.strip()
        app = output / "QuietBar.app"
        with (app / "Contents/Info.plist").open("rb") as stream:
            metadata = plistlib.load(stream)
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            require(isinstance(metadata.get(key), str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", metadata[key]),
                    f"Invalid bundle metadata: {key}")
        require(metadata.get("CFBundleIdentifier") == "local.quietbar.app"
                and metadata.get("CFBundleExecutable") == "QuietBar"
                and metadata.get("CFBundlePackageType") == "APPL"
                and metadata.get("LSMinimumSystemVersion") == "14.0"
                and metadata.get("LSUIElement") is True
                and "MacOSX" in metadata.get("CFBundleSupportedPlatforms", []), "Unexpected app metadata")
        REPORT["bundle"] = {key: metadata[key] for key in (
            "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion",
        )}
        version = metadata["CFBundleShortVersionString"]
        root = f"QuietBar-{version}"
        app_zip = output / f"{root}-universal.zip"
        dmg = output / f"{root}-universal.dmg"
        source_zip = output / "QuietBar-source.zip"
        verify_app(app, metadata, args.require_hardened_runtime, "Output app")
        app_files = app_manifest(app)
        verify_zip(app_zip, root, [f"{root}/QuietBar.app/Contents/Info.plist",
                                  f"{root}/QuietBar.app/Contents/MacOS/QuietBar", f"{root}/README.txt"])
        verify_zip(source_zip, "QuietBar-source", ["QuietBar-source/build.sh", "QuietBar-source/Sources/main.m"])
        with tempfile.TemporaryDirectory(prefix="quietbar-verify-", dir=build) as directory:
            temporary = Path(directory)
            extracted = temporary / "zip"
            run("Extract own app ZIP", ["/usr/bin/ditto", "-xk", app_zip, extracted], timeout=120)
            zip_app = extracted / root / "QuietBar.app"
            verify_app(zip_app, metadata, args.require_hardened_runtime, "ZIP app")
            require(app_manifest(zip_app) == app_files, "ZIP app differs from output app")
            require(sha256(extracted / root / "README.txt") == sha256(app / "Contents/Resources/README.txt"),
                    "ZIP README differs from the bundled instructions")
            REPORT["checks"].append("ZIP app and instructions match output")
            verify_dmg(dmg, temporary, app_files, metadata, args.require_hardened_runtime)
        cli_checks(app / "Contents/MacOS/QuietBar", metadata)
        REPORT["artifacts"] = [{"file": path.name, "bytes": path.stat().st_size, "sha256": sha256(path)}
                               for path in (app_zip, dmg, source_zip)]
        REPORT["passed"] = True
    except (OSError, ValueError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        REPORT["error"] = str(error)
        print(f"Verification failed: {error}", file=sys.stderr)
    finally:
        report.write_text(json.dumps(REPORT, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        print(f"Verification report: {report}")
    if REPORT["passed"]:
        print("Package integrity and read-only CLI checks passed; GUI/Jump acceptance was not run.")
    return 0 if REPORT["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
