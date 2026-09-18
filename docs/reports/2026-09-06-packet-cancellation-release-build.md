# Optimized binaries for packet capture and cancellation settlement

> Last updated: 2026-09-06 · commit `6d9fa6cfe`

Both the provider CLI and native benchmark build from the committed union of
attention packet capture and canceled-prefix settlement. All 21 argument and
CLI smoke checks pass. These binaries are ready for the separate real-model
HTTP and packet experiments; this build does not establish their results.

## Artifact identity

Both products use parent `98103b39741a48f9d47026be7393362318a2ab0a` and
native `dcf39f6b43effaa2b483211c97d7d3a3e7c0269b`.

| Product | Bytes | SHA-256 |
|---|---:|---|
| `darkbloom` | 86,431,464 | `e27c1e51c8d4fc71e031748ebcb6b3372a6dee9d4c3eca38b17e063972db7b0c` |
| `radix-engine` | 80,619,696 | `5839807f14649132591f7381ad0993a56afcd6e0cf864432db77efd10ce2eeeb` |

Both executables have mode 0755. Six runtime resources match the earlier
reviewed build byte for byte, including their permissions. The pinned
`mlx.metallib` is reused unchanged. The native Metal source is unchanged.

The source snapshots come from the committed trees. Only recorded local
SwiftPM dependency-path overlays and pinned resolutions differ in the build
workspace. The provider snapshot includes all eight cancellation source/test
files. The packet snapshot matches the separately validated native and harness
source. Persistent-test key namespaces and changes to default activation are
not included.

## Build and checks

The optimized probe builds in 252.41 seconds; the CLI builds in 261.31 seconds.
The shared scratch directory is accepted only after each actual product build,
its source graph and final executable identity have been recorded.

Six valid benchmark option combinations reach the expected empty-input guard
before loading any model: default, packet-only and all diagnostics together on
both backends. Thirteen invalid combinations reach their expected argument
rejection. CLI version and help commands pass. These are 21 parse/guard checks;
they do not run inference.

Root verification rehashes all 98 frozen build payloads, both executables and all
six resources. The actual declared SwiftPM graphs match 1,023 probe and 1,266
CLI source references. These are graph-reference checks, not a claim that every
listed source links into each product. Remote MLX checkout sources and mutable
worktree sources do not enter these owned graph references.

The preceding packet validation covers 77 native test functions / 162 expanded
cases, 18 benchmark functions and 14 Python wrapper tests. The preceding
cancellation validation covers 73 distinct provider functions / 76 executions.
Those are separate source validations, with their exact revisions retained in
[the packet report](2026-09-06-attention-packet-capture.md) and
[the cancellation report](2026-09-06-canceled-prefix-settlement.md). This report
adds the optimized build and parse checks of their committed union.

## Retained evidence and next gate

The [manifest](evidence/packet-cancellation-release-build-2026-09-06/manifest.json)
and [archive](evidence/packet-cancellation-release-build-2026-09-06/payloads.tar.gz)
retain 93 independently rehashed payloads: source manifests, build commands and
logs, both actual graph snapshots, runtime inventories, smoke results and root
reviews. Executables and runtime resources are identified by hash and excluded
from the archive.

Manifest SHA-256: `54766dacbfb96530578845823defbc4ef71abdbe8ea93b132c704f5bd7b748a6`.
Archive SHA-256: `44e672a1244b58805c19e1dc413ae020b454564af1654f82b2b4307ce1143b0d`
(1,961,358 bytes).

The connected HTTP rerun must establish native canceled-request settlement
through the coordinator/provider path. Qwen3.6 packet experiments must preserve
their own control trajectories and bind actual raw tensors to the selected
forward. Numerical parity, real-model performance, signed persistent restart
and release readiness remain open.
