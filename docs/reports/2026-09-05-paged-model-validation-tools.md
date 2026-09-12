# Paged model validation tools

> Last updated: 2026-09-05 · commit `8b8935fb4`

The offline engine harness now supports B1/B2/B4 runs and explicit slot KV grants in one binary. This milestone banks measurement tools and their checks; it contains no real-model concurrent or paged performance result.

Each batch records every submitted row, including refused or failed submissions, alongside token IDs, counts, finish reasons, TTFT, total batch time and aggregate output rate. Capacity and MLX active/cache memory are sampled every 100 ms. Sampling retains at most 6,000 rows and counts omitted samples while continuing peak tracking. These sampled peaks can miss shorter events.

The comparator rejects missing/failed rows, unobserved requested concurrency, backend fallback, and mismatched comparison settings. Staging release is checked after the whole batch drains because other active requests can still own staging when one row completes. The default remains one request with a 16 GiB slot grant.

The benchmark SPI constructs the real production slot and stages real encrypted SSD checkpoints before exposing raw engine events. Requested grants must fit the production post-load memory budget, including the resolved activation reserve. A physical-RAM envelope is not a KV grant. This path omits the bridge's shared request-admission policy and HTTP framing, which require separate serving tests.

Validation passed 28 Python checks and the six-file harness semantic build in 8.75 seconds. Two provider fixture cases verify a valid small grant and rejection of a physical-RAM-sized grant. Their exact source hashes also match the later fully passing 72-test [request-date run](2026-09-05-request-date-prompt-parity.md). The [evidence manifest](evidence/090-benchmark-tools-2026-09-05/manifest.json) retains logs and 13 source hashes; stored and decompressed digests were independently checked.

Use the [build procedure](../developer/build.md) and [cache benchmark procedure](../developer/test.md#prefix-cache-benchmark-validation) to archive one binary and compare exact model/MTP/backend/cache arms. B2/B4 correctness, long-context capacity, shared admission, HTTP behavior and repeated full-model measurements remain release gates.
