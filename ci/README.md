# Selected application attribution experiment

`application-attribution.yml` is a manual workflow on standard public
`macos-14`, `macos-15`, `macos-15-intel` and `macos-26` runners. It builds the
actual product and two selected `.app` fixtures, then runs LaunchServices A1,
the real product `--test-application-cycle` backend B, and LaunchServices A2.
The fixture paths contain spaces, and the delayed fixture also contains an
apostrophe. Its initial process starts a capture helper three seconds later
and reaps that owned child on normal exit or termination.

The capture fixture adapts `ci/CaptureProbe.swift` from
https://github.com/miha1744/macos-native-menubar-probe . It counts complete
SCStream frames and changes in its animated window at 8, 16 and 24 seconds.
Every sample retains a separate native 80-point menubar screenshot, stream
crop and window metadata. B measures the exact nonempty rectangles from A1
and scans the entire native strip for purple pixels and potential relocation.
There is no SCStream-image fallback for native indicator evidence.

`prepared.json` and `diagnostics.json` are product state only. Their
`captureVerified` and `indicatorVerified` must stay false. The driver links
`controller.applicationIdentity` to the selected fixture using PID, UID,
executable path and both start-time fields. It separately checks changing
capture, fixture exit, product `final.json` and the A-B-A image observations.

An automated `VISIBLE_ABSENT_VISIBLE_CANDIDATE` is a measurement requiring
manual native screenshot review. It never marks product compatibility
accepted. Missing frames/images, empty baseline rectangles, purple pixels
relocating elsewhere, invalid product flags/linkage or missing A2 return are
`INCONCLUSIVE`. A green workflow alone is not indicator acceptance.

Capture/TCC operations refuse to run outside the exact hosted workflow
guards. Provisioning is restricted to ScreenCapture rows for
`local.quietbar.fixture.direct`, `local.quietbar.fixture.delayed` and the
Apple-signed system Terminal. It requires a disposable hosted SIP-disabled
VM and records its actual OS, architecture, image and SIP status. Neither
TCC databases nor general logs are copied into artifacts. No broad resets,
service restarts, existing app cleanup or paid runner labels are used.
The results do not establish ordinary SIP-enabled or third-party behavior.

Local checks, which do not launch an app, Terminal, capture or TCC operations:

```sh
python3 -B ci/application_attribution.py --self-test
python3 -B ci/build-application-fixtures.py --compile-only /absolute/scratch/path
```

Compile-only fixtures have permanently disabled runtime guards. Hosted
fixtures instead validate compiled paths, an exact host/run ID, private
current-UID guard/control files, their bundle identity and executable path.
The fixed control file avoids adding CI environment variables to the
production Terminal command.

The workflow uploads only `quietbar-application-ci/evidence` for one day;
private fixture guard tokens, binaries, designated requirements and SQL are
outside that directory. Inspect `application-attribution-result.json`, each
phase's native PNGs, and B's product/protocol records independently.
