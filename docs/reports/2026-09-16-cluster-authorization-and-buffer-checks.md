# Cluster authorization and encrypted-buffer checks

> Last updated: 2026-09-16 · commit `605651bb9`

The private coordinator member/native-pair candidate passes 2,790 Go tests with
the race detector. Its provider candidate passes 78 selected Swift tests and the
Darkbloom CLI build. A separate native encrypted-buffer experiment passes all 35
fixed cases on each of the 24 GB and 48 GB M4 Pro Macs. These results qualify
component behavior; they do not establish encrypted RDMA inference or production
readiness.

The coordinator candidate requires an explicit approved native-runtime catalog,
the original verified provider connections, signed preparation and a committed
pair reservation before owner start. Review found a cancellation race: an old
pending reservation could release its connection attachments before publishing
its terminal cancellation frames. The correction requires both cancellation
publication and joined writers before reuse. Its deterministic ordering test
passes in the focused and full suites.

Focused qualification passes all 35 pair, member and native-pair methods. Full
qualification discovers 2,793 compiled test entries across registry, protocol
and API, then covers each exactly once: 2,790 pass and three retain their ordinary
explicit skips. Four API batches preserve the existing package deadline. Real
provider-version and Swift/TypeScript telemetry fixtures are included. All six
full-suite children exit successfully, are reaped and leave no owned process
groups. Source inventories remain unchanged. These are isolated candidate builds;
provider-side invocation of the native grant/key flow remains separate.

The first Swift compilation exposed two timer callbacks that needed explicit
actor hops. Adding `await` preserves their existing cancellation, nonce and wait-ID
checks. The corrected candidate passes all 78 tests in 12 suites, including both
real WebSocket acknowledgment cases and the two cross-language native-pair
protocol checks. A result-parser correction accepts Swift Testing's exact
two-case completion wording; it qualifies the retained successful output without
rerunning tests. The matching CLI build succeeds against the same unchanged
source inventory. Both actual children exit successfully and leave no owned
process groups. The candidate executable has not been deployed.

The allocation experiment exercises AES-GCM records, actual native byte staging
and compact array materialization. Both codec endpoints run in one fresh process
per case, with an in-memory ciphertext mailbox. The fixed catalog covers small
control records, BF16/F32 residual shapes through 512 × 5,120, repeated large/small
buffer reuse, tampered ciphertext/tags, cancellation and invalid sizes/shapes.
Failure cases include fresh and primed sessions. Expected errors must preserve
the exact publication/counter rules and release their buffers.

| Observation across 35 native processes per Mac | 24 GB Mac | 48 GB Mac |
|---|---:|---:|
| Largest native allocation increase | 20,987,904 bytes | 20,987,904 bytes |
| Largest conservative process physical-memory increase | 71,532,640 bytes | 71,516,232 bytes |
| Lowest sampled actual free memory | 11,657,560,064 bytes | 31,668,043,776 bytes |
| Retained raw resource observations | 130 | 130 |

The process increase uses its lifetime physical high-water mark relative to the
current baseline; native bytes are not subtracted from it. Every case preserves
AC power, zero swap, normal pressure and the six-GiB actual-free floor. All 70
native leaders are reaped, owned groups are absent, output reaches complete EOF
and the same canonical device journal is empty with an obtainable lock.

The experiment excludes RDMA/group allocation, model execution, the production
key handshake and overlapping transport directions. Its same-process peak is
not a proven per-rank serving bound. A reviewed resource allowance and actual
encrypted pair execution remain required. No
serving profile is enabled and no end-to-end latency overhead is claimed.

Evidence is retained under `/Users/developer/DarkbloomDev/cluster-research/`:

| Evidence | SHA-256 |
|---|---|
| `coordinator-native-pair-go-build-2-20260916/go-all-1/checks.json` | `ff61e24fe4753e940c2465b3d153b4ee32c769e23d091b14d73b68724cd176db` |
| `coordinator-native-pair-root-review-20260916/swift-final-review.json` | `b8ca44435d5ed0e5206e4fea8d9ce2294b1d3cc3f04f1656c5968225e9c1885a` |
| `collective-native-allocation-root-review-20260916/physical-24-review.json` | `14e970b06fc03dfff941c68d6998bc92ffac1b2478f32aea869a2fcfc3e291fe` |
| `collective-native-allocation-root-review-20260916/physical-48-review.json` | `73be77f1f7dd00295476fe7f276655ab285cb485240a8479ab1a275fa36559d0` |
| Allocation native executable | `4f4149c7330d8268ac7294ef7b225db25078d2fb853cb06af1d02e73ae66b26c` |

The [delivery plan](../design/distributed-cluster-delivery.md) tracks product
integration. [First 27B timing](2026-09-16-cluster-delivery-progress.md) and
[record encryption CPU cost](2026-09-15-cluster-record-encryption-cost.md) use
different experiments and retain their own measurement limits.
