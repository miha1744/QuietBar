# Compatibility and evidence

This page separates the app’s build target, observed native behavior and experiments with a separate capture probe. Status recorded on 20 October 2026. A successful build, live process or missing icon alone is not acceptance of remote control.

## Product status

| Environment | Evidence available | What remains unverified |
| --- | --- | --- |
| macOS 27.0.1, Apple Silicon, native backend | Prior maintainer observation: the native indicator group was hidden. The implementation is in [`QBFilter.m`](../Sources/QBFilter.m); this repository does not include a public native acceptance run. | Other macOS 27 builds, Intel, every display arrangement and continued Jump behavior across reconnects. |
| macOS 27.0.1, SIP enabled, forced legacy backend | Local permission-guard check of 1.2.0 reported `needsScreenPermission`, with no takeover journal or Jump agent/service mutation. This is a guard check, not a supported legacy-session result. | Permission-approved launch, actual remote image, mouse, keyboard and hidden indicator. |
| macOS 14, 15 and 26, experimental Jump backend | Implementation targets the fixed, signed Jump Desktop Connect installation and current user agent. Public probe measurements are listed below. | A real Jump session and recovery on these systems with SIP enabled. |
| macOS 14.6.1 | An older QuietBar 1.1 attempt found the native API unavailable. | The 1.2.0 experimental Jump backend has not been tested on this exact release. |
| Other releases and hardware | Universal arm64/x86_64 build target; minimum macOS 14.0. Backend availability is probed at runtime. | All unlisted OS/hardware combinations. macOS 13 is outside the app’s build target. |

The local observations above are explicitly scoped maintainer reports. They should not be read as independently reproducible public test records.

## Public ScreenCaptureKit measurements

The separate [macOS native menu bar probe](https://github.com/miha1744/macos-native-menubar-probe) records experiments with its **own SCStream**, not Jump Desktop. In the [19 October A–B–A experiment](https://github.com/miha1744/macos-native-menubar-probe/blob/main/results/attribution-2026-10-19.md), A launched through LaunchServices, B through Terminal and detached `screen`, then A ran again.

| Actual macOS | Architecture | Native indicator, A1 / B / A2 | Capture in B |
| --- | --- | --- | --- |
| 14.8.9 (23J631) | arm64 | Visible / absent / visible | Changing complete frames continued |
| 15.7.9 (24G830) | arm64 | Visible / absent / visible | Changing complete frames continued |
| 15.7.9 (24G830) | x86_64 | Visible / absent / visible | Changing complete frames continued |
| 26.6.2 (25G83) | arm64 | Visible / absent / visible | Changing complete frames continued |

All four hosted VMs had **SIP disabled** and CI-specific capture-permission provisioning. Native menu bar images were manually reviewed alongside metadata. These measurements do not establish QuietBar or Jump compatibility on an ordinary SIP-enabled Mac. [Raw records and limitations](https://github.com/miha1744/macos-native-menubar-probe/blob/main/results/attribution-2026-10-19.md).

A [delayed-child experiment](https://github.com/miha1744/macos-native-menubar-probe/blob/main/results/delayed-attribution-2026-10-19.md) reproduced the pattern on the same four configurations when a Python launcher created a new probe after Terminal had exited. That supports further investigation of the launch chain. It does not validate QuietBar’s native controller, installed Jump agents, root capture helpers, reconnects or a distributed app.

The separate [visibility-preference experiment](https://github.com/miha1744/macos-native-menubar-probe/blob/main/results/preference-2026-10-19.md) failed on all four configurations: the indicator stayed visible while capture continued. Those probes also found the assessment framework/classes unavailable. QuietBar’s legacy backend therefore does not rely on that preference.

These results cover specific builds only. They exclude Intel macOS 14/26, exact macOS 14.6.1, future updates and all other unlisted combinations. There is no “works on every patch” claim.

## What an actual Jump acceptance check needs

After preparation, reconnect to the target Mac and confirm each result separately:

1. Changing screen content reaches the Jump client.
2. Mouse movement and clicks work.
3. Keyboard input reaches the Mac.
4. The native screen-sharing indicator is absent on the Mac while that session continues.
5. Restoring normal launch completes and Jump remains usable after reconnecting.

Repeat with SIP enabled, normal macOS permission approval and the exact release/hardware being reported. A `prepared` state only says that the owned agent remains alive. QuietBar does not automatically verify these five outcomes.

## Installation and UI limitations

- Local builds are ad hoc signed and unnotarized. No Developer ID identity is supplied. Hardened runtime alone does not change that; Gatekeeper can still block opening. [Apple documents the available GUI approval flow](https://support.apple.com/en-us/102445).
- Native mode uses a private API. System updates can remove it or change its behavior; it is not a Mac App Store approach.
- The native mode acts on a system group. AirDrop, Focus and Now Playing can disappear with the purple indicator. Arbitrary app windows and individual menu bar icons are outside the current controls.
- The legacy mode requires the supported Jump installation in `/Applications`, Terminal Screen Recording and Accessibility permissions, and manually enabled Jump autostart. Preparation/restoration can interrupt a connection.
- The interface is currently in Russian. Documentation is available in [English](../README.md) and [Russian](README.ru.md).
- Recovery uses a verified journal, with a known suspended-orphan window after `SIGKILL`. See [architecture](architecture.md#known-recovery-limit).

For a useful issue report, include the exact macOS build, architecture, Jump Connect version, selected backend and which of the five checks passed. The menu’s **«Скопировать диагностику»** action copies local diagnostics; inspect and remove personal paths or process details before sharing them publicly.
