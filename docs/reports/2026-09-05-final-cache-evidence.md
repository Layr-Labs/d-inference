# Strict cache evidence and the first Qwen3.6 paged SSD pair

> Last updated: 2026-09-05 · commit `1a4a4504b`

The evaluator now requires a real cache-off/cache-on pair, checks both batch
arms and verifies idle/shutdown ownership. Fifty Python test functions pass.
The first exact Qwen3.6 pair proves SSD restoration and output parity, but its
original harness has stale post-terminal gauges in five cold control snapshots.
The strict full retirement gate therefore remains unproven.

## Acceptance checks

Eight new regression functions reproduce 37 false-pass subcases against the
old evaluator. The new cache axis requires disabled then enabled cache with the
same store/key policy and resolved backend. Disabled probes cannot claim saved
work. Both baseline and candidate must supply complete batch evidence and
observed overlap. A requested width of four is not proof of peak admission four.

Serial/whole-batch idle observations require retired requests and zero live or
promised pages. Admission charge may equal reusable committed physical backing.
Shutdown additionally requires zero native backing/segments and zero process
owners, closing owners, C, M and unmaterialized promises. Logical address pages,
model weights, allocator cache and RSS are distinct and may remain. The evaluator
retains failures when these observations are missing; it does not infer a leak
from one stale gauge.

## Exact-model observation

The exact Qwen3.6 aggregate is
`d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed`.
Both arms used the original benchmark binary
`601bce0923cfb2e12410073fe193a08a9c73830b5afd74d7f72e2facb49be21c`,
normal inline MTP, production-derived single-slot grant and B1 on M5 Max128GiB.
Fresh pre/post weight hashes match. The corrected wrapper explicitly selected
ephemeral keys and isolated roots; this is not restart evidence.

The 5,523-token prompt executed three prefill chunks with observed maximum
2,048 tokens. The repeat restored 4,096 tokens and authenticated 165,140,972 SSD
bytes. Staging took 46.16ms. Main and tenant output IDs matched the cold arm;
cancellation restored a completed donor and recovery matched its full output.
The old comparator passed this semantic pair. Its original verdict is preserved
alongside the stricter rejection and the explicit idle-scope addendum.

| Single paired observation | Cache off | SSD enabled |
|---|---:|---:|
| First-request TTFT | 1.616s | 1.372s (miss) |
| Repeat TTFT | 1.286s | 0.452s (4,096 saved tokens) |
| First-request terminal tail | 0.00015s | 0.07729s |

The repeat difference is 0.834s in one pair, not a repeated performance result.
The cold-miss terminal tail includes checkpoint work; capture overhead has no
separate direct timer. This evidence does not establish decode improvement,
B2/B4 throughput, contiguous-versus-paged performance or HTTP behavior.

Observed SSD host read/write reservation peaks were 20MiB with at most4MiB
segments. Main-row idle and final shutdown showed zero active stage/write host
reservation and native committed backing; final process owners were zero.
These are scoped snapshots. Five cold control `metrics_after` values instead
retain active/page gauges, while process C/M is already zero and the next
observation shows retired gauges at the same step count. Native terminal delivery
can precede publication of gauges; the harness reads engine and process snapshots
at different times. A coherent bounded observation is required before final
retirement and repeated-matrix acceptance. No raw observations are replaced.

The earlier1,607-token corrected-root smoke successfully constructed SSD but
created no checkpoint because it fit in one2,048-token prefill chunk. Its mandatory
restore assertion failed. That expected-cold result is retained, not counted as
cache reuse merely because the minimum saved-token threshold is lower.

## Evidence and remaining work

Root verified the six-path evaluator delta, all17 frozen validation payloads,
raw test counts, both exact-model manifests, paired identities/token IDs and
actual native saved work. The [manifest](evidence/final-cache-evidence-2026-09-05/manifest.json)
and [archive](evidence/final-cache-evidence-2026-09-05/payloads.tar.gz) retain
68 payloads, including original negative tests, strict model refusal,
idle addendum, the short-prompt failure and the original semantic verdict.
Manifest SHA-256: `12188f318a153b969dabaea3130ff4b684d22d90deadad391fc85558095aea19`.
Archive SHA-256: `a34377ce386a429862f6e50360cb20041f98f4d90297ed36ff47b911b893b390`.

Other exact models, coherent idle observations, repeated B1/B2/B4 measurements,
contiguous controls, capacity/co-residency, HTTP and persistent restart remain
release requirements. Default promotion and0.9.1work remain pending.

Related: [benchmark procedure](../developer/test.md#prefix-cache-benchmark-validation),
[isolated key mode correction](2026-09-05-isolated-cache-key-mode.md).
