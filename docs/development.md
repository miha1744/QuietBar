# Building and checking QuietBar

Use macOS with Xcode Command Line Tools and Python 3. The project has no package-manager dependencies. Run these commands from the repository root:

```sh
./build.sh --hardened-runtime
python3 scripts/verify-package.py --require-hardened-runtime
```

The build creates a universal `arm64` + `x86_64` app with a macOS 14.0 deployment target. `build/` holds intermediate files and `dist/` holds the app, versioned ZIP and DMG, source ZIP, and installation instructions. The version comes from `build.sh`; the verifier reads the built `Info.plist` to find the matching packages. Both tools accept `--build-dir` and `--output-dir` for isolated runs. Keep the verifier's working directory outside its input output directory.

The default build uses an ad-hoc signature. `--hardened-runtime` adds runtime protections; it does not provide Developer ID signing or notarization. Building does not install or launch QuietBar.

## What verification covers

`scripts/verify-package.py` validates bundle metadata, both executable architectures and their deployment targets, signatures, ZIP CRCs, DMG checksums, and equality of the app's files inside the packages. It extracts the app ZIP into its own temporary directory, mounts only the supplied DMG read-only without opening Finder, and detaches that mount in `finally` cleanup. External commands have timeouts. Artifacts are read-only inputs; the JSON report and temporary files go into the verifier's build directory.

It invokes exactly these CLI modes on the output app:

| Command | Evidence |
| --- | --- |
| `--test-legacy-helpers` | Controller recovery/path/identity fixtures (currently 20) and backend validation fixtures. Reports zero service/preference mutations and no agent launch. |
| `--test-unsupported` | Simulates a missing private API and checks that activation is blocked. |
| `--self-test` | Reads API availability, selected backend, and login-item status while leaving filtering disabled. API availability is an observation, not a pass requirement. |

These commands do not launch Jump, modify its LaunchAgent, enable a login item, request privacy permissions, or enable real indicator filtering. The verifier never calls `--test-filter-cycle` or `--test-login-cycle`.

The JSON report records the host macOS version, architecture, SIP status, bundle version, check results, and package SHA-256 hashes. A local run uploads nothing. Review and redact a report before sharing it; full application diagnostics can contain local paths and process details.

## CI candidates and acceptance limits

The workflow builds on the standard hosted `macos-14`, `macos-15`, `macos-15-intel`, and `macos-26` labels. It uses only `contents: read` permission, does not retain checkout credentials, and pins actions to immutable commits. No Developer ID credentials, notarization profile, installation, or privileged operation is part of CI. Successful jobs retain `quietbar-build-<OS>` candidate packages and the verification report for seven days. Failed verification retains its report when available. These artifacts are ad-hoc development candidates, not GitHub Releases or notarized downloads.

The action pins were checked against the official repository tags on 2026-10-20:

- [actions/checkout v7.0.1](https://github.com/actions/checkout/tree/3d3c42e5aac5ba805825da76410c181273ba90b1)
- [actions/upload-artifact v7.0.2](https://github.com/actions/upload-artifact/tree/cf430e030ddbb5b0abf93d22962f4752f3646cd9)

The labels are listed in the [official runner image inventory](https://github.com/actions/runner-images#available-images). `macos-14` is deprecated there, so its availability needs attention when updating CI; the macOS 14 build target alone does not replace a macOS 14 execution check. The workflow deliberately avoids paid `-large` and `-xlarge` labels. GitHub's public-repository standard runner policy applies; storage beyond the retention settings is governed by repository/account limits.

Hosted-runner checks do not establish normal desktop compatibility. Prior capture experiments ran on hosts with SIP disabled. The verifier records the current host's `csrutil status`; neither a passing CI job nor those experiments prove behavior on a normal Mac with SIP enabled. The CI matrix also has no macOS 27 lane, so it does not exercise the native macOS 27 backend.

Before claiming compatibility, manually verify the installed app on the exact macOS build and architecture, with SIP enabled. For the experimental Jump launcher, record the Jump version and confirm all of the following during a real remote connection: indicator state, continuously updating captured image, mouse control, and keyboard input. Also verify that restoring normal launch works and a later connection still works. **Prepared means the launcher is prepared; it does not mean the indicator is hidden or remote control has passed.** Record untested combinations as untested.

## Optional distribution build

`./build.sh --distribution` is a separate, explicitly requested operation. It requires an existing Developer ID Application signing identity in the local keychain and an existing `notarytool` keychain profile, selected through `SIGN_IDENTITY` and `NOTARY_PROFILE`. It signs with hardened runtime, submits the app and DMG to Apple, staples accepted tickets, and requires Gatekeeper acceptance. It publishes the complete local set into a new versioned `dist/QuietBar-<version>-distribution/` directory only after those checks pass; an existing directory is not overwritten.

This mode sends the packages to Apple. Use it only with authorization for that submission. Do not put certificate private keys, account passwords, API keys, or keychain contents in the repository, workflow, diagnostics, or issue reports. The CI workflow does not configure or invoke distribution mode. Signing/notarization checks and manual GUI/Jump acceptance are separate release requirements; there is no automatic release publication workflow.
