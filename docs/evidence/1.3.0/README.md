# QuietBar 1.3 selected-application measurements

[Capture run](https://github.com/miha1744/QuietBar/actions/runs/39415956457) · [Package run](https://github.com/miha1744/QuietBar/actions/runs/39415216664) · [Sanitized measurements](measurements.json)

20 October 2026. The real product `.app` selection/backend/controller path launched two own fixture applications: direct capture and a launcher creating a delayed capture helper. Both retained changing complete ScreenCaptureKit frames while the large purple sharing pill was absent. Ordinary LaunchServices launch before and after showed the pill. The retained native screenshots are the manually reviewed 24-second representatives; JSON records all observations at 8, 16 and 24 seconds.

| Host label | Fixture | B complete frames | B animated changes | Native A1 / B / A2 images |
| --- | --- | --- | --- | --- |
| macos-14 | direct | 43 → 124 | 39 → 120 | [A1](macos-14-direct-A1-24s.png) / [B](macos-14-direct-B-24s.png) / [A2](macos-14-direct-A2-24s.png) |
| macos-14 | delayed | 45 → 125 | 42 → 122 | [A1](macos-14-delayed-A1-24s.png) / [B](macos-14-delayed-B-24s.png) / [A2](macos-14-delayed-A2-24s.png) |
| macos-15 | direct | 44 → 124 | 42 → 122 | [A1](macos-15-direct-A1-24s.png) / [B](macos-15-direct-B-24s.png) / [A2](macos-15-direct-A2-24s.png) |
| macos-15 | delayed | 46 → 127 | 42 → 123 | [A1](macos-15-delayed-A1-24s.png) / [B](macos-15-delayed-B-24s.png) / [A2](macos-15-delayed-A2-24s.png) |
| macos-15-intel | direct | 48 → 127 | 42 → 121 | [A1](macos-15-intel-direct-A1-24s.png) / [B](macos-15-intel-direct-B-24s.png) / [A2](macos-15-intel-direct-A2-24s.png) |
| macos-15-intel | delayed | 46 → 126 | 42 → 122 | [A1](macos-15-intel-delayed-A1-24s.png) / [B](macos-15-intel-delayed-B-24s.png) / [A2](macos-15-intel-delayed-A2-24s.png) |
| macos-26 | direct | 47 → 129 | 40 → 120 | [A1](macos-26-direct-A1-24s.png) / [B](macos-26-direct-B-24s.png) / [A2](macos-26-direct-A2-24s.png) |
| macos-26 | delayed | 45 → 125 | 40 → 119 | [A1](macos-26-delayed-A1-24s.png) / [B](macos-26-delayed-B-24s.png) / [A2](macos-26-delayed-A2-24s.png) |

Actual hosts were macOS 14.8.9 (23J631) arm64, 15.7.9 (24G830) arm64 and x86_64, and 26.6.2 (25G83) arm64. **All VMs had SIP disabled and CI-only Screen Recording provisioning.** This is own-fixture evidence, not acceptance of arbitrary third-party apps or ordinary SIP-enabled Macs. Intel macOS 14/26 and other patch releases were not tested.

The small purple dot beside Control Center remained in the macOS 15 and 26 B images. The launcher hides the observed sharing pill, not every privacy indicator. Other menu bar items remain visible.

The product's `captureVerified` and `indicatorVerified` stay false; measurement is external. Exact selected-process identity linkage and final cleanup acknowledgement passed, with no recorded fixture processes left. The fixtures cooperatively stopped capture and exited before product stop; this does not test closing an actively capturing third-party app or unsaved-document prompts. Remote mouse/keyboard behavior and reconnects are not tested.

An earlier run passed the three macOS 14/15 lanes but failed before capture on macOS 26 because Python removed `load_module`. The single CI loader fix changed no product source. The linked run repeats all four configurations using the supported import API. Product code is from `e88e74d`; harness is `24772cb`. The automated classification remains `MEASUREMENT`, `acceptedCompatibility=false`; the observation above is scoped to these fixtures and images.
