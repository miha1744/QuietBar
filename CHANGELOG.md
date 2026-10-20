# Changes

## Unreleased — public repository draft

- Add English and Russian documentation, architecture notes and an evidence-based compatibility matrix.
- Add build and package verification workflows and a structured bug report form.
- Add the MIT license for QuietBar contributions and retain the original Stash MIT notice.
- Include the project license in the app bundle and documentation and CI tooling in the source archive.

These changes prepare the existing local 1.2.0 source for review. They do not add
per-icon controls or establish compatibility with additional macOS releases.
No public product release has been published from this repository draft.

## 1.2.0 — existing local build

- Universal app with a minimum deployment target of macOS 14.
- Select the native assessment backend when its private API is available.
- Add an experimental Jump launcher for systems without that API, with permission
  checks, an ownership journal, cancellation and recovery.
- Distinguish a prepared agent from verified screen capture, remote input and indicator hiding.
