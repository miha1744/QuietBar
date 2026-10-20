# Contributing to QuietBar

Small, reproducible contributions help most: a documented macOS result, a focused
bug fix, or an improvement to setup and recovery.

Read the [architecture](docs/architecture.md), [compatibility evidence](docs/compatibility.md)
and [development guide](docs/development.md) before changing a backend.

## Before opening a pull request

- Describe the problem, the resulting behavior, and the macOS version and architecture used.
- Preserve the ownership journal and exact process identity checks. A PID by itself
  cannot identify a process safely after an exit.
- Keep preparation, capture, remote input and indicator visibility as separate results.
  A successful build or a `prepared` agent is not a successful screen-sharing test.
- Run the relevant package verification from the development guide. Avoid changing
  actual services or permissions on an ordinary user Mac as part of an unattended test.
- Keep real user data, credentials and unredacted diagnostic paths out of commits and issues.

Tests that involve Jump should use your own Mac or a machine whose owner has
explicitly agreed. Arrange a second way to reconnect before testing agent restarts.
Do not commit screenshots of someone else's desktop.

## Useful areas to work on

1. Investigate per-app or per-system-item rules on macOS versions that provide the
   native assessment API. An item inventory and selection controls are not implemented yet.
2. Validate the selected-application launcher and adapters on a documented macOS version with SIP enabled.
   For the existing Jump adapter, verify changing image, mouse, keyboard, reconnect,
   indicator state and restoration. Record each selected app and version; independent capture helpers may need a separate adapter.
3. Improve translations and permission setup without changing security settings automatically.

Changes should not edit TCC databases, disable SIP, modify Jump's system daemon,
or terminate unrelated processes. Keep generic launch validation and graceful
termination separate from the fixed Jump adapter's service-specific lifecycle.

See the [roadmap](docs/roadmap.md) for the broader product scope and adapter criteria.

Contributions are offered under the [MIT license](LICENSE). Preserve all existing
third-party notices.
