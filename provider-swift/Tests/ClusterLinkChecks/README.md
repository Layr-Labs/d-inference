# Cluster link checks

Run `bash provider-swift/Tests/ClusterLinkChecks/run.sh` from any directory.
The runner compiles the Foundation-only link-readiness sources under
`Sources/ProviderCore/Inference/Distributed/Diagnostics/Link` with Swift 6
warnings as errors, without SwiftPM or MLX, and finishes in a few seconds.

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

Fixture addresses are documentation placeholders. No RDMA or network tool is
started, no setting is read or changed, and no peer is contacted. How a report
appears among the doctor's checks is covered by `ClusterDiagnosticsChecks`;
command parsing is covered by `DarkbloomCLITests/ClusterDiagnosticsCommandTests.swift`
in the full Provider suite.
