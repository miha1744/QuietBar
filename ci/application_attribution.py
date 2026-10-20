#!/usr/bin/env python3
"""Real product selected-.app A-B-A observations on disposable hosted macOS VMs."""
import argparse
import copy
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import socket
import subprocess
import time

from importlib.machinery import SourceFileLoader

BASE = Path(__file__).resolve().parent
BUILD = SourceFileLoader("qb_fixture_build", str(BASE / "build-application-fixtures.py")).load_module()
ALLOWED = frozenset(BUILD.IDS.values()) | {"com.apple.Terminal"}


def read(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name("." + path.name + ".new")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def command(argv, **kwargs):
    return subprocess.run(list(map(str, argv)), text=True, capture_output=True, **kwargs)


def continuous(result):
    samples = result.get("samples", [])
    return (result.get("status") == "MEASUREMENT" and len(samples) == 3
            and all(s.get("streamError") is None and s.get("nativeImageSaved") is True
                    and s.get("streamImageSaved") is True for s in samples)
            and samples[0].get("completeFrames", 0) >= 5
            and samples[0].get("animatedPixelChanges", 0) >= 3
            and all(b.get("completeFrames", 0) - a.get("completeFrames", 0) >= 5
                    and b.get("animatedPixelChanges", 0) - a.get("animatedPixelChanges", 0) >= 3
                    for a, b in zip(samples, samples[1:])))


def analyze(phases, protocol_ok=False):
    reasons = []
    for phase in ("A1", "B", "A2"):
        if not continuous(phases.get(phase, {})):
            reasons.append(phase + ": three native images and changing complete frames not established")
    if not protocol_ok:
        reasons.append("Product prepared-state flags or selected process linkage not established")
    a1 = phases.get("A1", {}).get("samples", [])
    b = phases.get("B", {}).get("samples", [])
    a2 = phases.get("A2", {}).get("samples", [])
    visible = lambda samples: len(samples) == 3 and all(
        s.get("strictVisibleTargets", 0) >= 1 and s.get("regionPurplePixels", 0) >= 15
        and len(s.get("measurementRects", [])) >= 1 for s in samples)
    if not visible(a1):
        reasons.append("A1: visible purple native target not established")
    if not visible(a2):
        reasons.append("A2: visible purple native target did not return")
    if len(a1) == len(b) == 3 and visible(a1):
        baseline = a1[0].get("measurementRects", [])
        min_region = min(s.get("regionPurplePixels", 0) for s in a1)
        min_whole = min(s.get("wholeNativePurplePixels", 0) for s in a1)
        if not all(s.get("baselineRectsInherited") is True and s.get("measurementRects") == baseline for s in b):
            reasons.append("B: exact nonempty A1 rectangles were not reused")
        if not all(s.get("strictVisibleTargets", 1) == 0
                   and s.get("regionPurplePixels", min_region) * 5 < min_region for s in b):
            reasons.append("B: target disappearance in known A1 regions not established")
        # A relocated pill must not pass merely because its former area is blank.
        # Other purple menu content may make this conservative check inconclusive.
        required_drop = max(15, int(min_region * 0.65))
        if not all(isinstance(s.get("wholeNativePurplePixels"), int)
                   and s["wholeNativePurplePixels"] <= min_whole - required_drop
                   and bool(s.get("wholeNativePurpleTiles")) for s in b):
            reasons.append("B: whole native strip does not establish purple-area reduction; inspect relocation/background")
    else:
        reasons.append("B: nonempty verified A1 regions unavailable")
    return {"status": "INCONCLUSIVE" if reasons else "MEASUREMENT",
            "observedPattern": "NOT_ESTABLISHED" if reasons else "VISIBLE_ABSENT_VISIBLE_CANDIDATE",
            "reasons": reasons, "manualScreenshotReviewRequired": True,
            "acceptedCompatibility": False, "scope": "Selected direct/delayed CI fixture own SCStream only"}


def self_test():
    rect = [{"x": 100.0, "y": 0.0, "width": 40.0, "height": 30.0}]
    def samples(hidden):
        return [{"completeFrames": 20 * n, "animatedPixelChanges": 10 * n, "streamError": None,
                 "nativeImageSaved": True, "streamImageSaved": True, "strictVisibleTargets": 0 if hidden else 1,
                 "regionPurplePixels": 0 if hidden else 100, "measurementRects": rect,
                 "baselineRectsInherited": hidden, "wholeNativePurplePixels": 0 if hidden else 110,
                 "wholeNativePurpleTiles": [{"x": 100, "purplePixels": 0 if hidden else 100}]}
                for n in (1, 2, 3)]
    valid = {p: {"status": "MEASUREMENT", "samples": samples(p == "B")} for p in ("A1", "B", "A2")}
    assert analyze(valid, True)["status"] == "MEASUREMENT"
    assert analyze(valid, False)["status"] == "INCONCLUSIVE"
    for mutate in (lambda d: d["B"]["samples"][0].update(measurementRects=[]),
                   lambda d: d["B"]["samples"][0].update(nativeImageSaved=False),
                   lambda d: d["B"]["samples"][0].update(wholeNativePurplePixels=110),
                   lambda d: d["B"]["samples"][1].update(completeFrames=20),
                   lambda d: d["A2"]["samples"][0].update(strictVisibleTargets=0)):
        damaged = copy.deepcopy(valid); mutate(damaged)
        assert analyze(damaged, True)["status"] == "INCONCLUSIVE"
    print("Classifier verified: empty regions, missing native image, relocated purple pixels, frozen frames and missing A2 return cannot pass.")


class Driver:
    def __init__(self, product):
        self.root = BUILD.hosted_root()
        self.manifest = read(self.root / "manifest.json")
        if (not self.manifest or self.manifest.get("root") != str(self.root)
                or self.manifest.get("runID") != os.environ.get("GITHUB_RUN_ID")
                or self.manifest.get("host") != socket.gethostname()
                or self.manifest.get("uid") != os.getuid()
                or not re.fullmatch(r"[0-9a-f]{64}", self.manifest.get("token", ""))
                or set(self.manifest.get("fixtures", {})) != set(BUILD.IDS)):
            raise RuntimeError("Guarded fixture manifest missing")
        self.product = product.resolve(strict=True)
        if not self.product.is_file():
            raise RuntimeError("Product executable unavailable")
        self.evidence = self.root / "evidence"
        self.evidence.mkdir(exist_ok=True)
        self.identity_tool = self.root / "process-identity"
        compiled = command(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", BASE / "process_identity.c", "-o", self.identity_tool])
        if compiled.returncode:
            raise RuntimeError("Read-only identity helper compile failed: " + compiled.stderr[-2000:])
        self.owned = {}
        self.processes = []
        self.stop_paths = []
        self.initial_terminals = set(self.terminal_pids())

    def identity(self, pid):
        if not isinstance(pid, int) or pid <= 1:
            return None
        result = command([self.identity_tool, pid])
        return json.loads(result.stdout) if result.returncode == 0 else None

    @staticmethod
    def terminal_pids():
        result = command(["pgrep", "-x", "-u", os.getuid(), "Terminal"])
        if result.returncode not in (0, 1):
            raise RuntimeError("Terminal inventory failed")
        return [int(x) for x in result.stdout.split()]

    def track(self, pid, permitted):
        item = self.identity(pid)
        if item and item["uid"] == os.getuid() and item["executablePath"] in permitted:
            self.owned[pid] = item
            return item
        return None

    def capture_identities(self, directory, fixture):
        permitted = {fixture["executable"], fixture["captureExecutable"]}
        records = []
        for name in ("launcher.json", "app-process.json"):
            item = read(directory / name, {})
            tracked = self.track(item.get("pid"), permitted)
            if tracked is None:
                previous = self.owned.get(item.get("pid"))
                if previous and previous["executablePath"] in permitted:
                    tracked = previous
            if tracked:
                records.append(tracked)
        write(directory / "driver-process-identities.json", {"processes": records})
        return records

    @staticmethod
    def wait_file(path, timeout, process=None):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if path.is_file():
                return True
            if process is not None and process.poll() is not None:
                return path.is_file()
            time.sleep(0.25)
        return path.is_file()

    def control(self, fixture, phase, directory, baseline):
        directory.mkdir(parents=True, exist_ok=True)
        write(fixture["control"], {"schema": 1, "token": self.manifest["token"], "runID": self.manifest["runID"],
              "bundleID": fixture["bundleID"], "phase": phase, "outputDirectory": str(directory), "baselineRects": baseline})
        self.stop_paths.append(directory / "fixture-stop")

    def stop_fixture(self, directory, fixture):
        (directory / "fixture-stop").touch()
        self.wait_file(directory / "capture-finished", 8)
        identities = self.capture_identities(directory, fixture)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and any(self.identity(i["pid"]) == i for i in identities):
            time.sleep(0.2)
        return all(self.identity(i["pid"]) is None for i in identities) and bool(identities)

    def gui_leg(self, fixture, phase, baseline):
        directory = self.evidence / fixture["bundleID"].split(".")[-1] / phase
        self.control(fixture, phase, directory, baseline)
        with (directory / "open.log").open("w") as log:
            child = subprocess.Popen(["/usr/bin/open", "-W", "-n", "--stdout", str(directory / "stdout.log"),
                    "--stderr", str(directory / "stderr.log"), fixture["application"]], stdout=log, stderr=log)
            self.processes.append(child)
            self.wait_file(directory / "app-process.json", 15, child)
            self.capture_identities(directory, fixture)
            self.wait_file(directory / "capture-result.json", 45, child)
            result = read(directory / "capture-result.json", {"status": "INCONCLUSIVE", "reason": "No capture result"})
            result["fixtureExitConfirmed"] = self.stop_fixture(directory, fixture)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.terminate(); child.wait(timeout=5)
        return result

    @staticmethod
    def dictionaries(value):
        if isinstance(value, dict):
            yield value
            for child in value.values():
                yield from Driver.dictionaries(child)
        elif isinstance(value, list):
            for child in value:
                yield from Driver.dictionaries(child)

    def backend_leg(self, fixture, baseline):
        phase = self.evidence / fixture["bundleID"].split(".")[-1] / "B"
        capture = phase / "capture"; backend = phase / "backend"
        backend.mkdir(parents=True, exist_ok=True)
        self.control(fixture, "B", capture, baseline)
        self.stop_paths.append(backend / "driver-stop")
        with (backend / "cli.log").open("w") as log:
            child = subprocess.Popen([str(self.product), "--test-application-cycle", fixture["application"], str(backend)],
                                     stdout=log, stderr=log)
            self.processes.append(child)
            ready = self.wait_file(backend / "prepared.json", 40, child)
            self.wait_file(capture / "app-process.json", 15, child)
            fixture_identities = self.capture_identities(capture, fixture)
            prepared = read(backend / "prepared.json", {})
            diagnostics = read(backend / "diagnostics.json", {})
            all_objects = list(self.dictionaries(prepared)) + list(self.dictionaries(diagnostics))
            flag_objects = [x for x in all_objects if "captureVerified" in x or "indicatorVerified" in x]
            flags_ok = bool(flag_objects) and all(x.get("captureVerified") is False and x.get("indicatorVerified") is False for x in flag_objects)
            product_identities = [x.get("applicationIdentity") for x in all_objects if isinstance(x.get("applicationIdentity"), dict)]
            identity_keys = ("pid", "uid", "startSeconds", "startMicroseconds", "executablePath")
            linkage = any(all(product.get(key) == fixture_process.get(key) for key in identity_keys)
                          for product in product_identities for fixture_process in fixture_identities)
            write(backend / "driver-protocol-check.json", {"preparedFileExists": ready, "flagsRemainUnverified": flags_ok,
                  "selectedProcessLinked": linkage, "fixtureIdentities": fixture_identities, "productIdentities": product_identities})
            self.wait_file(capture / "capture-result.json", 45, child)
            result = read(capture / "capture-result.json", {"status": "INCONCLUSIVE", "reason": "No B capture result"})
            exited = self.stop_fixture(capture, fixture)
            (backend / "driver-stop").touch()
            final_exists = self.wait_file(backend / "final.json", 20, child)
            final = read(backend / "final.json", {})
            try:
                return_code = child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.terminate(); return_code = child.wait(timeout=5)
            write(backend / "driver-final-check.json", {"finalFileExists": final_exists, "cliExit": return_code,
                  "fixtureExitConfirmed": exited, "final": final})
            result["fixtureExitConfirmed"] = exited
            result["backendProtocolVerified"] = (ready and flags_ok and linkage and exited and final_exists
                                                  and final.get("preparedObserved") is True
                                                  and final.get("passed") is True and return_code == 0)
        return result

    def provision(self):
        # Exact IDs only, only in a verified disposable hosted VM. No DB copy,
        # broad permission reset, tccd restart, or product permission grant.
        reports = []
        for kind, fixture in self.manifest["fixtures"].items():
            if fixture["bundleID"] != BUILD.IDS[kind]:
                raise RuntimeError("Unexpected fixture identity")
            expected = self.root / "Selected apps" / ("Direct capture.app" if kind == "direct" else "Delay's capture.app")
            if Path(fixture["application"]) != expected or expected.resolve() != expected:
                raise RuntimeError("Unexpected fixture path")
            with (expected / "Contents/Info.plist").open("rb") as source:
                if plistlib.load(source).get("CFBundleIdentifier") != BUILD.IDS[kind]:
                    raise RuntimeError("Fixture bundle identity differs from the fixed allowlist")
        subjects = [(f["bundleID"], Path(f["application"])) for f in self.manifest["fixtures"].values()]
        subjects.append(("com.apple.Terminal", Path("/System/Applications/Utilities/Terminal.app")))
        work = self.root / "private-permission-setup"; work.mkdir(exist_ok=True)
        for identifier, application in subjects:
            if identifier not in ALLOWED:
                raise RuntimeError("TCC client outside fixed allowlist")
            verification = command(["codesign", "--verify", "--strict", application])
            if identifier == "com.apple.Terminal":
                verification = command(["codesign", "--verify", "--strict", '-R=anchor apple and identifier "com.apple.Terminal"', application])
            if verification.returncode:
                raise RuntimeError("Code signature verification failed")
            requirement = command(["codesign", "-d", "-r-", application])
            lines = [line.split("designated => ", 1)[1] for line in (requirement.stdout + requirement.stderr).splitlines() if "designated => " in line]
            if len(lines) != 1:
                raise RuntimeError("No exact designated requirement")
            binary = work / (identifier + ".csreq")
            if command(["csreq", "-r", "=" + lines[0], "-b", binary]).returncode:
                raise RuntimeError("Cannot compile designated requirement")
            blob = binary.read_bytes().hex()
            assert re.fullmatch(r"[0-9a-f]+", blob)
            sql = (".timeout 5000\nBEGIN IMMEDIATE;\nINSERT INTO access (service,client,client_type,auth_value,auth_reason,auth_version,csreq,policy_id,indirect_object_identifier_type,indirect_object_identifier,indirect_object_code_identity,flags,last_modified) VALUES "
                   f"('kTCCServiceScreenCapture','{identifier}',0,2,4,1,X'{blob}',NULL,0,'UNUSED',NULL,0,{int(time.time())}) "
                   "ON CONFLICT(service,client,client_type,indirect_object_identifier) DO UPDATE SET auth_value=2,auth_reason=4,auth_version=1,csreq=excluded.csreq,last_modified=excluded.last_modified;\nCOMMIT;\n")
            for label, database, prefix in (("system", Path("/Library/Application Support/com.apple.TCC/TCC.db"), ["sudo", "-n"]),
                                            ("user", Path.home() / "Library/Application Support/com.apple.TCC/TCC.db", [])):
                if not database.is_file() or database.is_symlink():
                    reports.append({"client": identifier, "store": label, "status": "INCONCLUSIVE"}); continue
                answer = command(prefix + ["sqlite3", str(database)], input=sql)
                check = command(prefix + ["sqlite3", str(database), f"SELECT count(*) FROM access WHERE service='kTCCServiceScreenCapture' AND client='{identifier}' AND client_type=0 AND indirect_object_identifier='UNUSED' AND auth_value=2 AND hex(csreq)=upper('{blob}');"])
                reports.append({"client": identifier, "store": label, "status": "PROVISIONED" if answer.returncode == check.returncode == 0 and check.stdout.strip() == "1" else "INCONCLUSIVE"})
        write(self.evidence / "permission-setup.json", {"scope": "Ephemeral hosted CI only; selected fixtures and Apple Terminal, ScreenCapture only", "reports": reports,
              "acceptance": "Provisioned rows are not capture or indicator acceptance"})

    def cleanup(self):
        for path in self.stop_paths:
            path.touch(exist_ok=True)
        for child in self.processes:
            if child.poll() is None:
                try:
                    child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    child.terminate()
        # Exact recorded fixture identities only; no pkill/killall/app wildcard.
        cleanup = []
        for pid, expected in self.owned.items():
            actual = self.identity(pid)
            if actual == expected:
                os.kill(pid, signal.SIGTERM)
                cleanup.append({"identity": expected, "termRequested": True})
        write(self.evidence / "cleanup.json", {"exactFixtureProcesses": cleanup,
              "remainingRecordedPIDs": [pid for pid, expected in self.owned.items() if self.identity(pid) == expected],
              "preexistingTerminalPIDsUntouched": sorted(self.initial_terminals)})

    def run(self):
        metadata = {"os": command(["sw_vers"]).stdout, "architecture": command(["uname", "-m"]).stdout.strip(),
                    "sip": command(["csrutil", "status"]).stdout.strip(), "imageOS": os.environ.get("ImageOS"),
                    "imageVersion": os.environ.get("ImageVersion"), "runID": self.manifest["runID"],
                    "scope": "Hosted VM own-fixture measurement; no ordinary SIP-on or arbitrary third-party claim"}
        write(self.evidence / "environment.json", metadata)
        if "disabled" not in metadata["sip"].lower():
            write(self.evidence / "application-attribution-result.json", {"status": "INCONCLUSIVE", "reason": "This provisioning experiment requires a disposable hosted SIP-disabled VM; no TCC provisioning attempted", "environment": metadata})
            return
        if command(["stat", "-f", "%u", "/dev/console"]).stdout.strip() != str(os.getuid()) or command(["pgrep", "-x", "-u", os.getuid(), "ControlCenter"]).returncode:
            raise RuntimeError("Matching Aqua console and ControlCenter unavailable")
        write(self.root / "guard.json", {"runID": self.manifest["runID"], "token": self.manifest["token"],
              "uid": os.getuid(), "host": self.manifest["host"], "githubHosted": True, "runnerOS": "macOS"})
        self.provision()
        results = {}
        for kind, fixture in self.manifest["fixtures"].items():
            phases = {}
            phases["A1"] = self.gui_leg(fixture, "A1", [])
            baseline = (phases["A1"].get("samples") or [{}])[0].get("measurementRects", [])
            phases["B"] = self.backend_leg(fixture, baseline)
            phases["A2"] = self.gui_leg(fixture, "A2", baseline)
            result = analyze(phases, phases["B"].get("backendProtocolVerified") is True and all(phases[p].get("fixtureExitConfirmed") for p in ("A1", "A2")))
            result["phases"] = phases; results[kind] = result
        write(self.evidence / "application-attribution-result.json", {"schema": 1, "status": "MEASUREMENT" if all(x["status"] == "MEASUREMENT" for x in results.values()) else "INCONCLUSIVE",
              "environment": metadata, "fixtures": results, "manualScreenshotReviewRequired": True, "acceptedCompatibility": False})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--product", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test(); return
    if not args.product:
        parser.error("--product is required")
    os.umask(0o077)
    driver = Driver(args.product)
    try:
        driver.run()
    except Exception as error:
        write(driver.evidence / "application-attribution-result.json", {"status": "INCONCLUSIVE", "reason": str(error), "acceptedCompatibility": False})
        raise
    finally:
        driver.cleanup()


if __name__ == "__main__":
    main()
