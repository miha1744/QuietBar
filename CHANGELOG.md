# Changes

## 1.3.0 Preview 1 — 2026-10-20

- Add a generic `.app` chooser as the default fallback when the native filter API is absent.
- Launch a closed application's main executable through Terminal, screen and the early native controller; preserve the separate opt-in Jump adapter.
- Validate target identity, keep a durable ownership journal and request graceful app termination; never force-quit an already running app.
- Keep launch readiness separate from verified capture and indicator hiding. Arbitrary app compatibility remains experimental.
- Add pure controller/backend checks and a separate hosted integration harness.

App metadata is 1.3.0 (4), minimum macOS 14.0, arm64 and x86_64. Preview builds are ad hoc signed and unnotarized.

## Earlier unreleased documentation

- Define the broader app-independent menu bar visibility direction in both READMEs.
- Separate platform backends, planned item rules and application-specific adapters.
- Add a roadmap; the current preview's behavior and compatibility are unchanged.

## 1.2.0 Preview 1 — 2026-10-20

- Add English and Russian documentation, architecture notes and an evidence-based compatibility matrix.
- Add build and package verification workflows and a structured bug report form.
- Add the MIT license for QuietBar contributions and retain the original Stash MIT notice.
- Include the project license in the app bundle and documentation and CI tooling in the source archive.

The first public preview is tagged `v1.2.0-preview.1`; app metadata remains
1.2.0 (3). The source and packages are experimental. Public CI passed package
integrity and read-only CLI checks on macOS 14, 15 (arm64 and Intel) and 26.
It did not verify real Jump capture, input or indicator hiding. These changes
do not add per-icon controls.

## 1.2.0 — existing local build

- Universal app with a minimum deployment target of macOS 14.
- Select the native assessment backend when its private API is available.
- Add an experimental Jump launcher for systems without that API, with permission
  checks, an ownership journal, cancellation and recovery.
- Distinguish a prepared agent from verified screen capture, remote input and indicator hiding.
