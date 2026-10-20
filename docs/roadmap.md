# Roadmap

QuietBar's goal is to let people control the visibility of application and system
menu bar icons on their own Mac. A remote access tool, a Zoom call or an OBS
recording are possible use cases, not claims of current app compatibility.

## Current foundation

The native backend is application-agnostic: it probes for the platform API and
supplies system-item IDs and running application bundle IDs. Today's control
toggles a special system indicator group; it does not offer individual icon
selection. Prior hiding was observed on macOS 27.0.1, with the evidence and limits
recorded in [compatibility](compatibility.md).

The experimental legacy backend is a separate, fixed Jump Desktop Connect
adapter. It validates one signed installation and its user LaunchAgent, then
manages a recorded launch and restoration. It is not a generic application
launcher. Actual Jump capture, input and reconnect acceptance remains unverified.

## Planned layers

| Layer | Scope | Status |
| --- | --- | --- |
| Native platform backend | Detect supported APIs, manage visibility assertions and restore normal visibility. | Current group-level control; platform-dependent. |
| Visibility rules and inventory | Identify controllable application/system items and expose explicit user choices. | Planned; individual controls need API feasibility checks. |
| Application-specific adapters | Handle a particular app only when a platform path is insufficient and its lifecycle can be verified. | Jump is experimental; other adapters are not implemented. |

Rules should clearly show which items can be controlled on the current Mac and
which items share a group. A requested individual rule must not silently become
a wider group change. Turning a rule off should restore its previous behavior.

Legacy adapters will keep fixed, documented targets, signature/path validation,
owned-process tracking and restoration. They must not accept arbitrary launch
commands or stop unrelated processes through broad name-based matching.

## Next steps

1. Map which individual application and system items the available native API
   can actually control, including unavoidable group effects.
2. Build an inventory and per-item controls for combinations proven feasible
   through that API first. Keep unsupported choices explicit.
3. Record behavior by exact macOS build, architecture, app version and backend:
   visibility, ongoing app operation, reconnect and restoration are separate
   results. Extend the [compatibility matrix](compatibility.md) with that evidence.
4. Complete real Jump acceptance before promoting its experimental adapter.
   Consider further adapters only for specific, tested app/version combinations.

## Acceptance for an application adapter

A new adapter needs a reproducible run on its stated OS/app combination with SIP
enabled, the expected signed application, default macOS security settings and
normal user-approved permissions. Check each outcome separately:

- The intended native menu bar icon or indicator is hidden during actual use.
- Capture continues with changing content, and mouse/keyboard input continues
  where the application provides those functions.
- Reconnecting preserves the expected app behavior and visibility result.
- Disabling QuietBar restores normal launch and visibility; the app remains
  usable after reconnecting. Document any recovery limits.

A build, passing read-only CLI checks, a live process or a missing icon alone is
insufficient. Existing hosted VM checks with SIP disabled do not meet this bar.

This roadmap does not promise control of every icon or support on every macOS
release. Visibility controls do not conceal processes, remove activity traces,
grant capture/access permissions or bypass system security protections.
