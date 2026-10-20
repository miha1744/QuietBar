#!/usr/bin/env python3
"""Build CI-only selected app fixtures. --compile-only never enables their guard."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import subprocess
import uuid

BASE = Path(__file__).resolve().parent
IDS = {"direct": "local.quietbar.fixture.direct", "delayed": "local.quietbar.fixture.delayed"}


def hosted_root():
    env = os.environ
    if not (os.uname().sysname == "Darwin" and env.get("GITHUB_ACTIONS") == "true" and env.get("RUNNER_ENVIRONMENT") == "github-hosted"
            and env.get("RUNNER_OS") == "macOS" and env.get("QB_APPLICATION_INTEGRATION") == "1"
            and env.get("GITHUB_REPOSITORY") == "miha1744/QuietBar" and os.getuid() != 0
            and re.fullmatch(r"[0-9]+", env.get("GITHUB_RUN_ID", ""))):
        raise SystemExit("Refusing non-hosted fixture build; use --compile-only for local compilation")
    temp = Path(env["RUNNER_TEMP"]).resolve(strict=True)
    if temp.stat().st_uid != os.getuid():
        raise SystemExit("Runner temporary directory is not owned by this user")
    return temp / "quietbar-application-ci"


def run(argv):
    subprocess.run(list(map(str, argv)), check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compile-only", type=Path)
    args = parser.parse_args()
    os.umask(0o077)
    root = args.compile_only.resolve() if args.compile_only else hosted_root()
    root.mkdir(parents=True, exist_ok=bool(args.compile_only))
    run_id = "compile-only" if args.compile_only else os.environ["GITHUB_RUN_ID"]
    token = uuid.uuid4().hex + uuid.uuid4().hex
    manifest = {"schema": 1, "root": str(root), "runID": run_id, "token": token,
                "host": socket.gethostname(), "uid": os.getuid(), "fixtures": {}}
    arch = subprocess.check_output(["uname", "-m"], text=True).strip()
    for kind, identifier in IDS.items():
        app = root / "Selected apps" / ("Direct capture.app" if kind == "direct" else "Delay's capture.app")
        macos = app / "Contents/MacOS"
        helpers = app / "Contents/Helpers"
        macos.mkdir(parents=True, exist_ok=True)
        helpers.mkdir(parents=True, exist_ok=True)
        executable = macos / ("CaptureFixture" if kind == "direct" else "DelayedFixture")
        capture = executable if kind == "direct" else helpers / "CaptureFixture"
        control = root / "control" / (kind + ".json")
        control.parent.mkdir(exist_ok=True)
        constants = {"fixtureRunRoot": str(root), "fixtureRunID": run_id, "fixtureToken": token,
                     "fixtureExpectedHostname": socket.gethostname(), "fixtureBundleID": identifier,
                     "fixtureAppPath": str(app), "fixtureControlPath": str(control)}
        generated = root / (kind + "-config.swift")
        generated.write_text("\n".join("let " + k + " = " + json.dumps(v) for k, v in constants.items())
                             + "\nlet fixtureExecutablePaths = " + json.dumps([str(executable), str(capture)]) + "\n")
        flags = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-O",
                 "-target", arch + "-apple-macosx14.0", generated, BASE / "FixtureGuard.swift"]
        run(flags + ["-framework", "AppKit", "-framework", "ScreenCaptureKit", "-framework", "CoreMedia",
                     "-framework", "CoreImage", BASE / "ApplicationCaptureFixture.swift", "-o", capture])
        if kind == "delayed":
            run(flags + [BASE / "DelayedFixtureLauncher.swift", "-o", executable])
        plist = {"CFBundleIdentifier": identifier, "CFBundleName": "QuietBar " + kind + " fixture",
                 "CFBundleExecutable": executable.name, "CFBundlePackageType": "APPL",
                 "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1",
                 "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
                 "NSScreenCaptureUsageDescription": "Own capture stream in a disposable hosted CI VM only."}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(plist))
        if kind == "delayed":
            run(["codesign", "--force", "--sign", "-", capture])
        run(["codesign", "--force", "--sign", "-", app])
        run(["codesign", "--verify", "--strict", "--deep", app])
        manifest["fixtures"][kind] = {"bundleID": identifier, "application": str(app),
                                     "executable": str(executable), "captureExecutable": str(capture), "control": str(control)}
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print("Built compile-only fixtures; guards disabled." if args.compile_only else "Built guarded hosted CI fixtures.")


if __name__ == "__main__":
    main()
