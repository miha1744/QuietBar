# Contributing to QuietBar

Small, reproducible contributions help most: a documented macOS result, a focused
bug fix, or an improvement to setup and recovery.

Read the [architecture](docs/architecture.md), [compatibility evidence](docs/compatibility.md)
and [development guide](docs/development.md) before changing either backend.

## Before opening a pull request

- Describe the problem, the resulting behavior, and the macOS version and architecture used.
- Preserve the ownership journal and exact process identity checks. A PID by itself
  cannot identify a process safely after an exit.
- Keep preparation, capture, remote input and indicator visibility as separate results.
  A successful build or a `prepared` agent is not a successful screen-sharing test.
- Run the relevant package verification from the development guide. Avoid changing
  actual services or permissions as part of an unattended test.
- Keep real user data, credentials and unredacted diagnostic paths out of commits and issues.

Tests that involve Jump should use your own Mac or a machine whose owner has
explicitly agreed. Arrange a second way to reconnect before testing agent restarts.
Do not commit screenshots of someone else's desktop.

## Useful areas to work on

1. Reproduce a complete Jump session on a documented macOS version with SIP enabled:
   verify changing image, mouse, keyboard, indicator state, and restoration.
2. Investigate per-app or per-system-item rules on macOS versions that provide the
   native assessment API. These controls are not implemented in QuietBar yet.
3. Improve translations and permission setup without changing security settings automatically.

Changes should not edit TCC databases, disable SIP, modify Jump's system daemon,
or terminate unrelated processes. Coordinate any new application adapter before
expanding the fixed Jump launcher into a general-purpose launcher.

Contributions are offered under the [MIT license](LICENSE). Preserve all existing
third-party notices.
