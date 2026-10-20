# Security and privacy

QuietBar changes the visibility of a system indicator while screen capture may
continue. Use it on your own Mac or with the owner's informed permission. It is
not a way to stop recording or revoke remote access.

The native backend uses a private macOS API and does not request Screen Recording
or Accessibility access. The experimental Jump backend asks for those permissions
for Apple Terminal because of the launch chain it uses. Those grants apply to
Terminal and can affect other commands you run there; they are not limited to QuietBar.
QuietBar does not grant these permissions, edit TCC, or disable SIP.

The launcher checks Jump's signing identity and only changes the current user's
known Jump LaunchAgent registration. Recovery uses a private local journal and
exact process identities. The system Jump daemon is outside this operation.
See [architecture](docs/architecture.md) for the remaining forced-termination limit.

Diagnostics are copied to the clipboard only when requested. They can contain
your local paths and process identifiers. Review and redact them before sharing.
Do not post credentials, private desktop screenshots or full device logs in public issues.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting if it is enabled on the published
repository. If it is unavailable, open an issue asking for a private contact route
without including exploitation details or sensitive data. There is currently no
guaranteed response time or bug bounty.

Please report issues against the latest development source. An ad-hoc local build is not
notarized by Apple; verify the source and build instructions before granting access.
