# Cluster link checks

Run `bash provider-swift/Tests/ClusterLinkChecks/run.sh` from any directory.
The runner compiles the link sources under
`Sources/ProviderCore/Inference/Distributed/Diagnostics/Link`, with the cluster
file policy and user paths they keep their record with, using Swift 6 and
warnings as errors, without SwiftPM or MLX. It finishes in a few seconds.

Checks cover:

- The text readers for `rdma_ctl status`, `ibv_devinfo`, `ibv_devinfo -v -d
  <device>` and `ifconfig`: enabled, disabled and garbled status; several
  devices with one active port; a GID table with and without an IPv4-mapped
  entry; a port with its own address, a bridge member without one and a bridge
  listing its members; malformed and address-shaped names refused.
- Every readiness state from canned tool results, including the two observed
  shapes: a port with its own IPv4 address (ready) and a port that is only a
  Thunderbolt Bridge member (`portBridgedWithoutAddress`); missing tools, a
  child timeout and oversized output; which commands run and which do not.
- The state codes, one guidance sentence per non-ready state, and the operator
  summary lines.
- Encoded JSON and summary text carry device and interface names only, even
  though the fixture text contains IPv4 addresses, MAC addresses and GIDs.
- The real bounded child runner against `/bin` and `/usr/bin` binaries: null
  standard input, fixed environment, non-zero exit, missing tool, hard timeout
  and output bound, with no descriptor left open by any of them.
- The link-local address chosen for a port: deterministic, in range, different
  for different machine values and ports, and strictly parsed.
- The address keeper: its label, file path, script and the ordered root
  commands that install it, how its job definition is recognised from
  `plutil -convert json` text, with or without knowing the address, and which
  ports have one by the names in its directory.
- Each privileged request (keep the address, add it alone, remove what is
  left) and its AppleScript wrapper, built only from a validated interface
  name and a generated or recorded address; hostile interface, device and
  `--device` text can never become part of one.
- How an approval attempt is read from an `osascript` exit status and message:
  applied, cancelled, unavailable, or approved with a failing command.
- Which port `--fix` may act on, for every readiness state, several candidate
  ports and a named device.
- Every `--fix` and `--remove` outcome over a scripted Mac with an injected
  approval step, for the address alone and for the durable fix: already ready,
  fixed, declined, unavailable, command failed part-way, each unmet
  verification condition including a keeper that is not installed as written,
  the manual commands, repeated runs, a lost address put back as recorded, a
  temporary address given its keeper without being touched, a ready port on
  any other address left alone, and removal of only what the record names and
  only what is found, including a keeper that puts the address back while the
  prompt is open, a keeper whose record is gone, and a record copied from
  another Mac.
- What a fix has left on a port, read with three read-only tools; a reading
  that times out, overflows or is garbled leaves that unknown, before a
  removal and after one.
- Dry runs of a fix and of a removal: the exact commands, no prompt and no
  record change.
- Whether an address Darkbloom assigned to a port is on it and whether its
  keeper is running, as the read-only report states it, with the guidance for
  a missing address and for one nothing would put back.
- The alias record on real files under a fixture home in the checkout: mode
  0600 in a 0700 directory, strict reading, updates that change only the entry
  they name, and refusal of loose, symlinked or tampered records.
- The `--watch` transition logic: previous report and new report to events.
- The guided `darkbloom cluster` flow as a state machine, as whole transcripts:
  a ready Mac, a bridged Mac approved and declined, an unattended run that
  never asks, waiting for a cable, an interrupted wait, RDMA disabled or
  missing, two candidate ports, every way the fix can end, and the
  `--temporary`, missing-address, unkept-address and `--dry-run` wordings, and
  the one bounded wait for a running keeper to put its address back.

Fixture addresses are documentation placeholders or derived from made-up
machine values. No RDMA or network tool, `launchctl`, `plutil`, `osascript` or
approval prompt is started, no setting is read or changed, and no peer is
contacted. How a report
appears among the doctor's checks is covered by `ClusterDiagnosticsChecks`;
command parsing is covered by `DarkbloomCLITests/ClusterDiagnosticsCommandTests.swift`
in the full Provider suite.
