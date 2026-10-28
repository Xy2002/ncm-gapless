# PR #7 review

Review date: 2026-10-28. Target: `feat/windows-maintenance` into `main`.
The initial review compared base `736e2736e88f3d1e79ac5dc7e99cdda5fc1ebb32`
with head `aea98366efc0652ef55a99253000bab980a67bc7`.

The requested behavior is automatic loading through the original Windows client
entry points, compatibility checks, safe installation repair, and authenticated
patch updates after client upgrades. The acceptance sources are
`docs/windows-startup.md`, `docs/windows-maintenance.md`, and the approved user
requirements. No issue tracker is configured for this repository.

## Standards

The independent review initially found two blocking findings: one P1 and one P2.

- **P1, privileged directory trust:** the permissions check skipped the volume
  root, where `DELETE_CHILD` or ownership/ACL changes can undermine a protected
  descendant. The check now includes the root and rejects those rights, while
  allowing creation of unrelated root children. Five in-memory ACL regressions
  cover safe creation and four dangerous rights.
- **P2, installation ownership and mode changes:** a fresh versioned installation
  could not be re-enabled using the normal command, and conversion to standalone
  could retain the old runtime pointer. The command now verifies the selected
  immutable runtime, and conversion removes the pointer only after commit and
  restores it on rollback. Three isolated top-level command regressions cover
  re-enabling and conversion.

Documentation now distinguishes Windows structural compatibility from audio
qualification and preserves the macOS version gate. A second independent
Standards inspection of the fixes found no remaining concrete blocking findings.

## Spec

The independent review initially found three blocking findings, all P2. The
re-enable/conversion finding overlaps the Standards finding above.

- **P2, transient installation failure:** if the client started between the
  worker's first process check and the installer's check, a valid update was
  quarantined permanently. The worker now retains signed pending data, defers
  this race, and retries after the client closes. A regression proves the retry
  installs the same release.
- **P2, re-enable and mode conversion:** resolved and covered by the three
  top-level command regressions described above.
- **P2, rapid failure recovery:** several failed launches between maintenance
  polls overwrote the only receipt, so the three-instance rollback threshold
  could be missed. The attach helper now preserves a bounded list of distinct
  failures under the existing operation lock, resets it after success, and the
  worker consumes that history in one poll. Helper and maintenance regressions
  cover three rapid failures, reset after success, and cached rollback.

A second independent Spec inspection of the fixes found no remaining concrete
blocking findings.

## Validation and merge gate

Local results after the fixes:

| Check | Result |
| --- | --- |
| Windows installation ownership and rollback | 6 passed |
| Top-level re-enable and standalone conversion | 3 passed |
| Volume-root ACL trust | 5 passed |
| Attach lifecycle and accumulated health | 11 passed |
| Signed maintenance, recovery and installation race | 18 passed |
| Shared JavaScript controller, adapter and AAC regressions | 49 passed |
| Portable package checks | 3 passed |
| Chinese project site | 3 passed |
| Whitespace validation | passed |

The previously failing site check was reproduced locally: stale 0.4 version and
startup documentation contradicted the 0.5 release. Those assertions now pass.
The PR adds a secret-free Windows workflow to build the native loader and run
native, attach, re-enable, maintenance, permissions, download, JavaScript and
portable package checks. Release CI also runs the new lifecycle regressions.
The signed-package-only Python test may skip in the secret-free PR job; the
native startup package and platform packages remain checked there.

Merge is conditional on successful GitHub checks for the final pushed head and
a readback showing that the open PR still points to that head. The merge command
must use that exact head as its expected revision. Run results and the final
merge receipt are read back from GitHub before reporting completion.

The existing release and live-client evidence remains in
`docs/evidence/windows-ci-release-v0.5.json` and
`docs/evidence/windows-maintenance-v0.5.json`. It predates these review fixes.
This review does not install a new protected worker on the user's computer,
execute the actual NetEase updater, qualify a future CEF ABI, or add audio-output
acceptance. The failed-attach rollback covers helpers that can write receipts;
it cannot observe every native crash before helper startup.
